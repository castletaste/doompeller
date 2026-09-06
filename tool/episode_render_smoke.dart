// Developer-only real-IWAD scene/load smoke. This is not a playthrough.
import 'dart:io';

import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flame/game.dart';

Future<void> main() async {
  if (!const bool.fromEnvironment('DOOM_EPISODE_RENDER_SMOKE')) {
    stderr.writeln('Enable DOOM_EPISODE_RENDER_SMOKE for this developer tool.');
    exitCode = 64;
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDoomRenderer();
  final data = await rootBundle.load(kDocumentedLocalWadPath);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final controller = DoomAppController();
  DoomRuntimeGame? runtime;
  final histogram = FrameHistogram();
  var recording = false;
  void timings(List<FrameTiming> frames) {
    if (recording) histogram.addTimings(frames);
  }

  SchedulerBinding.instance.addTimingsCallback(timings);
  runApp(
    DoomApp(
      controller: controller,
      autoStart: false,
      runtimeFactory: (level) => runtime = DoomRuntimeGame(level),
      gameSurfaceBuilder: (_, game) =>
          GameWidget<DoomRuntimeGame>(game: game as DoomRuntimeGame),
    ),
  );
  var failures = 0;
  try {
    for (var number = 1; number <= 9; number++) {
      recording = false;
      final mapName = 'E1M$number';
      await controller.useSelectedIwad(bytes, mapName: mapName);
      await SchedulerBinding.instance.endOfFrame;
      if (controller.state.level?.map.name != mapName || runtime == null) {
        failures++;
        stdout.writeln('episode-render-smoke map=$mapName load=FAIL');
        continue;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      histogram.clear();
      recording = true;
      await Future<void>.delayed(const Duration(seconds: 6));
      recording = false;
      final frames = histogram.summarize();
      final counters = runtime!.scene.diagnostics.snapshot();
      final bool rendered =
          frames.count >= 30 &&
          runtime!.scene.surfaceCount > 0 &&
          counters.gpuBuffersCreated > 0;
      final bool withinBudget =
          rendered && frames.p95Micros <= frames.deadlineMicros;
      if (!withinBudget) failures++;
      stdout.writeln(
        'episode-render-smoke map=$mapName rendered=$rendered '
        'frame_metric=flutter_frame_timing_total_span '
        'frames=${frames.count} p95_us=${frames.p95Micros} '
        'p99_us=${frames.p99Micros} within_budget=$withinBudget '
        'surfaces=${runtime!.scene.surfaceCount} '
        'buffers=${counters.gpuBuffersCreated} '
        'textures=${counters.texturesCreated} '
        'uploads=${counters.dynamicUploads} '
        'rss_bytes=${ProcessInfo.currentRss}',
      );
    }
    exitCode = failures == 0 ? 0 : 1;
    stdout.writeln(
      'episode-render-smoke COMPLETE scenes=9 failures=$failures playthrough=false',
    );
  } finally {
    recording = false;
    SchedulerBinding.instance.removeTimingsCallback(timings);
  }
}
