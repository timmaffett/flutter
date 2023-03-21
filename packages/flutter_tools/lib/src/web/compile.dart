// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/project_migrator.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../build_system/targets/web.dart';
import '../cache.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../platform_plugins.dart';
import '../plugins.dart';
import '../project.dart';
import 'migrations/scrub_generated_plugin_registrant.dart';

export '../build_system/targets/web.dart' show kDart2jsDefaultOptimizationLevel;

Future<void> buildWeb(
  FlutterProject flutterProject,
  String target,
  BuildInfo buildInfo,
  bool csp,
  String serviceWorkerStrategy,
  bool sourceMaps,
  bool nativeNullAssertions,
  bool isWasm, {
  String dart2jsOptimization = kDart2jsDefaultOptimizationLevel,
  String? baseHref,
  bool dumpInfo = false,
  bool noFrequencyBasedMinification = false,
  String? outputDirectoryPath,
}) async {
  final bool hasWebPlugins = (await findPlugins(flutterProject))
    .any((Plugin p) => p.platforms.containsKey(WebPlugin.kConfigKey));
  final Directory outputDirectory = outputDirectoryPath == null
      ? globals.fs.directory(getWebBuildDirectory(isWasm))
      : globals.fs.directory(outputDirectoryPath);
  outputDirectory.createSync(recursive: true);

  // The migrators to apply to a Web project.
  final List<ProjectMigrator> migrators = <ProjectMigrator>[
    ScrubGeneratedPluginRegistrant(flutterProject.web, globals.logger),
  ];

  final ProjectMigration migration = ProjectMigration(migrators);
  migration.run();

  final Status status = globals.logger.startProgress('Compiling $target for the Web...');
  final Stopwatch sw = Stopwatch()..start();
  try {
    final BuildResult result = await globals.buildSystem.build(
      WebServiceWorker(globals.fs, buildInfo.webRenderer, isWasm: isWasm),
      Environment(
        projectDir: globals.fs.currentDirectory,
        outputDir: outputDirectory,
        buildDir: flutterProject.directory
          .childDirectory('.dart_tool')
          .childDirectory('flutter_build'),
        defines: <String, String>{
          kTargetFile: target,
          kHasWebPlugins: hasWebPlugins.toString(),
          kCspMode: csp.toString(),
          if (baseHref != null)
            kBaseHref : baseHref,
          kSourceMapsEnabled: sourceMaps.toString(),
          kNativeNullAssertions: nativeNullAssertions.toString(),
          kServiceWorkerStrategy: serviceWorkerStrategy,
          kDart2jsOptimization: dart2jsOptimization,
          kDart2jsDumpInfo: dumpInfo.toString(),
          kDart2jsNoFrequencyBasedMinification: noFrequencyBasedMinification.toString(),
          ...buildInfo.toBuildSystemEnvironment(),
        },
        artifacts: globals.artifacts!,
        fileSystem: globals.fs,
        logger: globals.logger,
        processManager: globals.processManager,
        platform: globals.platform,
        usage: globals.flutterUsage,
        cacheDir: globals.cache.getRoot(),
        engineVersion: globals.artifacts!.isLocalEngine
          ? null
          : globals.flutterVersion.engineRevision,
        flutterRootDir: globals.fs.directory(Cache.flutterRoot),
        // Web uses a different Dart plugin registry.
        // https://github.com/flutter/flutter/issues/80406
        generateDartPluginRegistry: false,
    ));
    if (!result.success) {
      for (final ExceptionMeasurement measurement in result.exceptions.values) {
        globals.printError('Target ${measurement.target} failed: ${measurement.exception}',
          stackTrace: measurement.fatal
            ? measurement.stackTrace
            : null,
        );
      }
      throwToolExit('Failed to compile application for the Web.');
    }
  } on Exception catch (err) {
    throwToolExit(err.toString());
  } finally {
    status.stop();
  }
  globals.flutterUsage.sendTiming('build', 'dart2js', Duration(milliseconds: sw.elapsedMilliseconds));
}

/// Web rendering backend mode.
enum WebRendererMode {
  /// Auto detects which rendering backend to use.
  autoDetect,
  /// Always uses canvaskit.
  canvaskit,
  /// Always uses html.
  html,
}

/// The correct precompiled artifact to use for each build and render mode.
const Map<WebRendererMode, HostArtifact> kDartSdkJsArtifactMap = <WebRendererMode, HostArtifact>{
  WebRendererMode.autoDetect: HostArtifact.webPrecompiledCanvaskitAndHtmlSoundSdk,
  WebRendererMode.canvaskit: HostArtifact.webPrecompiledCanvaskitSoundSdk,
  WebRendererMode.html: HostArtifact.webPrecompiledSoundSdk,
};

/// The correct source map artifact to use for each build and render mode.
const Map<WebRendererMode, HostArtifact> kDartSdkJsMapArtifactMap = <WebRendererMode, HostArtifact>{
  WebRendererMode.autoDetect: HostArtifact.webPrecompiledCanvaskitAndHtmlSoundSdkSourcemaps,
  WebRendererMode.canvaskit: HostArtifact.webPrecompiledCanvaskitSoundSdkSourcemaps,
  WebRendererMode.html: HostArtifact.webPrecompiledSoundSdkSourcemaps,
};
