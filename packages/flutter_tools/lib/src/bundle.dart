// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:pool/pool.dart';

import 'asset.dart';
import 'base/common.dart';
import 'base/config.dart';
import 'base/file_system.dart';
import 'base/logger.dart';
import 'build_info.dart';
import 'build_system/build_system.dart';
import 'build_system/depfile.dart';
import 'build_system/targets/common.dart';
import 'build_system/targets/icon_tree_shaker.dart';
import 'cache.dart';
import 'convert.dart';
import 'devfs.dart';
import 'globals.dart' as globals;
import 'project.dart';

String get defaultMainPath => globals.fs.path.join('lib', 'main.dart');
const String defaultAssetBasePath = '.';
const String defaultManifestPath = 'pubspec.yaml';
String get defaultDepfilePath => globals.fs.path.join(getBuildDirectory(), 'snapshot_blob.bin.d');

String getDefaultApplicationKernelPath({
  @required bool trackWidgetCreation,
}) {
  return getKernelPathForTransformerOptions(
    globals.fs.path.join(getBuildDirectory(), 'app.dill'),
    trackWidgetCreation: trackWidgetCreation,
  );
}

String getDefaultCachedKernelPath({
  @required bool trackWidgetCreation,
  @required List<String> dartDefines,
  @required List<String> extraFrontEndOptions,
  FileSystem fileSystem,
  Config config,
}) {
  final StringBuffer buffer = StringBuffer();
  buffer.writeAll(dartDefines);
  buffer.writeAll(extraFrontEndOptions ?? <String>[]);
  String buildPrefix = '';
  if (buffer.isNotEmpty) {
    final String output = buffer.toString();
    final Digest digest = md5.convert(utf8.encode(output));
    buildPrefix = '${hex.encode(digest.bytes)}.';
  }
  return getKernelPathForTransformerOptions(
    (fileSystem ?? globals.fs).path.join(getBuildDirectory(
      config ?? globals.config,
     fileSystem ?? globals.fs
    ), '${buildPrefix}cache.dill'),
    trackWidgetCreation: trackWidgetCreation,
  );
}

String getKernelPathForTransformerOptions(
  String path, {
  @required bool trackWidgetCreation,
}) {
  if (trackWidgetCreation) {
    path += '.track.dill';
  }
  return path;
}

const String defaultPrivateKeyPath = 'privatekey.der';

/// Provides a `build` method that builds the bundle.
class BundleBuilder {
  /// Builds the bundle for the given target platform.
  ///
  /// The default `mainPath` is `lib/main.dart`.
  /// The default  `manifestPath` is `pubspec.yaml`
  Future<void> build({
    @required TargetPlatform platform,
    @required BuildInfo buildInfo,
    FlutterProject project,
    String mainPath,
    String manifestPath = defaultManifestPath,
    String applicationKernelFilePath,
    String depfilePath,
    String assetDirPath,
    @visibleForTesting BuildSystem buildSystem
  }) async {
    project ??= FlutterProject.current();
    mainPath ??= defaultMainPath;
    depfilePath ??= defaultDepfilePath;
    assetDirPath ??= getAssetBuildDirectory();
    buildSystem ??= globals.buildSystem;

    // If the precompiled flag was not passed, force us into debug mode.
    final Environment environment = Environment(
      projectDir: project.directory,
      outputDir: globals.fs.directory(assetDirPath),
      buildDir: project.dartTool.childDirectory('flutter_build'),
      cacheDir: globals.cache.getRoot(),
      flutterRootDir: globals.fs.directory(Cache.flutterRoot),
      engineVersion: globals.artifacts.isLocalEngine
          ? null
          : globals.flutterVersion.engineRevision,
      defines: <String, String>{
        // used by by the CopyFlutterBundle target
        kBuildMode: getNameForBuildMode(buildInfo.mode),

        // used by the KernelSnapshot target
        kTargetPlatform: getNameForTargetPlatform(platform),
        kTargetFile: mainPath,
        kTrackWidgetCreation: buildInfo.trackWidgetCreation.toString(),
        if (buildInfo.extraFrontEndOptions.isNotEmpty)
          kExtraFrontEndOptions: buildInfo.extraFrontEndOptions.join(','),
        if (buildInfo.extraGenSnapshotOptions.isNotEmpty)
          kExtraGenSnapshotOptions: buildInfo.extraGenSnapshotOptions.join(','),
        if (buildInfo.fileSystemRoots != null && buildInfo.fileSystemRoots.isNotEmpty)
          kFileSystemRoots: buildInfo.fileSystemRoots?.join(','),
        kFileSystemScheme: buildInfo.fileSystemScheme,
        if (buildInfo.dartDefines.isNotEmpty)
          kDartDefines: encodeDartDefines(buildInfo.dartDefines),

        // used by the CopyFlutterBundle target too, inside the copyAssets
        // call after the snapshot was built
        kIconTreeShakerFlag: buildInfo.treeShakeIcons.toString(),
        kDeferredComponents: 'false'
      },
      artifacts: globals.artifacts,
      fileSystem: globals.fs,
      logger: globals.logger,
      processManager: globals.processManager,
      platform: globals.platform,
    );
    final Target target = buildInfo.mode == BuildMode.debug
        ? const CopyFlutterBundle()
        : const ReleaseCopyFlutterBundle();
    final BuildResult result = await buildSystem.build(target, environment);

    if (!result.success) {
      for (final ExceptionMeasurement measurement in result.exceptions.values) {
        globals.printError('Target ${measurement.target} failed: ${measurement.exception}',
          stackTrace: measurement.fatal
              ? measurement.stackTrace
              : null,
        );
      }
      throwToolExit('Failed to build bundle.');
    }
    if (depfilePath != null) {
      final Depfile depfile = Depfile(result.inputFiles, result.outputFiles);
      final File outputDepfile = globals.fs.file(depfilePath);
      if (!outputDepfile.parent.existsSync()) {
        outputDepfile.parent.createSync(recursive: true);
      }
      final DepfileService depfileService = DepfileService(
        fileSystem: globals.fs,
        logger: globals.logger,
      );
      depfileService.writeToFile(depfile, outputDepfile);
    }

    // Work around for flutter_tester placing kernel artifacts in odd places.
    if (applicationKernelFilePath != null) {
      final File outputDill = globals.fs.directory(assetDirPath).childFile('kernel_blob.bin');
      if (outputDill.existsSync()) {
        outputDill.copySync(applicationKernelFilePath);
      }
    }
    return;
  }
}

Future<AssetBundle> buildAssets({
  String manifestPath,
  String assetDirPath,
  @required String packagesPath,
}) async {
  assetDirPath ??= getAssetBuildDirectory();
  packagesPath ??= globals.fs.path.absolute(packagesPath);

  // Build the asset bundle.
  final AssetBundle assetBundle = AssetBundleFactory.instance.createBundle();
  final int result = await assetBundle.build(
    manifestPath: manifestPath,
    assetDirPath: assetDirPath,
    packagesPath: packagesPath,
  );
  if (result != 0) {
    return null;
  }

  return assetBundle;
}

Future<void> writeBundle(
  Directory bundleDir,
  Map<String, DevFSContent> assetEntries,
  { Logger loggerOverride }
) async {
  loggerOverride ??= globals.logger;
  if (bundleDir.existsSync()) {
    try {
      bundleDir.deleteSync(recursive: true);
    } on FileSystemException catch (err) {
      loggerOverride.printError(
        'Failed to clean up asset directory ${bundleDir.path}: $err\n'
        'To clean build artifacts, use the command "flutter clean".'
      );
    }
  }
  bundleDir.createSync(recursive: true);

  // Limit number of open files to avoid running out of file descriptors.
  final Pool pool = Pool(64);
  await Future.wait<void>(
    assetEntries.entries.map<Future<void>>((MapEntry<String, DevFSContent> entry) async {
      final PoolResource resource = await pool.request();
      try {
        // This will result in strange looking files, for example files with `/`
        // on Windows or files that end up getting URI encoded such as `#.ext`
        // to `%23.ext`.  However, we have to keep it this way since the
        // platform channels in the framework will URI encode these values,
        // and the native APIs will look for files this way.
        final File file = globals.fs.file(globals.fs.path.join(bundleDir.path, entry.key));
        file.parent.createSync(recursive: true);
        await file.writeAsBytes(await entry.value.contentsAsBytes());
      } finally {
        resource.release();
      }
    }));
}
