// Developer-only live E1M1 replay through DoomRuntimeGame's ordinary Flame
// fixed-tick update and retained renderer.
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_hud.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/ui/doom_app.dart' show DoomStatusBar;
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'e1m1_playthrough.dart';

const bool _replayEnabled = bool.fromEnvironment('DOOM_E1M1_REPLAY');
const int _productionSeed = 0;
const int _productionCommandCount = 2160;
// Independent monster spread and portal sight intentionally change the route.
const int _productionHash = 0x9c565b42;
const int _frameWarmupSamples = 120;

Future<void> main() async {
  exitCode = 1;
  if (!_replayEnabled) {
    stderr.writeln(
      'doompeller-e1m1-replay: status=disabled '
      'required_define=DOOM_E1M1_REPLAY=true',
    );
    exitCode = 64;
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  try {
    final PreparedDoomLevel level = await _loadProductionE1m1();
    final E1m1PlaythroughResult route = E1m1PlaythroughRunner(
      level.map,
      gameConfig: const GameConfig(),
      seed: _productionSeed,
      includeArmor: true,
    ).run();
    _validateRoute(route);

    await initializeDoomRenderer();
    final ValueNotifier<DoomReplayResult?> terminal = ValueNotifier(null);
    final _LiveFrameWindow frameWindow = _LiveFrameWindow(
      warmupSamples: _frameWarmupSamples,
    );
    late final DoomRuntimeGame runtime;
    runtime = DoomRuntimeGame(
      level,
      replayInput: DoomReplayInput(
        commands: route.commands,
        expectedFinalHash: _productionHash,
        onFinished: (DoomReplayResult result) {
          terminal.value = result;
          final _LiveReplayEvidence evidence = _collectTerminalEvidence(
            result,
            runtime,
            frameWindow,
          );
          stdout.writeln(evidence.terminalLine);
          if (evidence.passed) exitCode = 0;
        },
      ),
    );
    stdout.writeln(
      'doompeller-e1m1-replay: status=ready '
      'input_mode=replay_exclusive '
      'command_total=${route.commands.length} '
      'runner_tics=${route.tics} '
      'expected_hash=${_hexHash(_productionHash)} '
      'runner_hash=${_hexHash(route.hash)} '
      'game_config=default skill=${route.skill.name} '
      'monsters=${route.monsters} seed=${route.seed}',
    );
    runApp(
      _E1m1ReplayApp(
        runtime: runtime,
        terminal: terminal,
        frameWindow: frameWindow,
      ),
    );
  } on Object catch (error, stackTrace) {
    stderr.writeln(
      'doompeller-e1m1-replay: status=setup_failed '
      'error_type=${error.runtimeType} error=$error',
    );
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

Future<PreparedDoomLevel> _loadProductionE1m1() async {
  final ByteData asset = await rootBundle.load(kDocumentedLocalWadPath);
  final Uint8List bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  final WadSet wads = WadSet(<WadFile>[WadFile.parse(bytes)]);
  final WadResources resources = WadResources.load(wads);
  final MapData map = MapData.load(wads, 'E1M1');
  return PreparedDoomLevel(
    content: DoomContent(
      wads: wads,
      mapName: 'E1M1',
      origin: DoomContentOrigin.developerIwad,
      sourcePath: kDocumentedLocalWadPath,
    ),
    resources: resources,
    map: map,
    geometry: DoomGeometryCompiler.compile(map, resources),
    gameConfig: const GameConfig(),
    seed: _productionSeed,
  );
}

void _validateRoute(E1m1PlaythroughResult route) {
  if (!route.completed) {
    throw StateError('runner did not complete E1M1');
  }
  if (route.tics != route.commands.length) {
    throw StateError(
      'runner command/tic mismatch: commands=${route.commands.length} '
      'tics=${route.tics}',
    );
  }
  if (route.commands.length != _productionCommandCount) {
    throw StateError(
      'runner command pin mismatch: expected=$_productionCommandCount '
      'actual=${route.commands.length}',
    );
  }
  if (route.hash != _productionHash) {
    throw StateError(
      'runner hash pin mismatch: expected=${_hexHash(_productionHash)} '
      'actual=${_hexHash(route.hash)}',
    );
  }
  if (route.seed != _productionSeed ||
      !route.monsters ||
      route.skill != Skill.medium) {
    throw StateError(
      'runner config mismatch: skill=${route.skill.name} '
      'monsters=${route.monsters} seed=${route.seed}',
    );
  }
}

_LiveReplayEvidence _collectTerminalEvidence(
  DoomReplayResult result,
  DoomRuntimeGame runtime,
  _LiveFrameWindow frameWindow,
) {
  final PlayerView player = runtime.gameState.player;
  final RenderDiagnosticsSnapshot renderer = runtime.scene.diagnostics
      .snapshot();
  final FrameSummary frames = frameWindow.histogram.summarize();
  final bool passed =
      result.passed &&
      runtime.tickDriver.droppedTics == 0 &&
      frames.count > 0 &&
      frames.p95Micros <= frames.deadlineMicros &&
      runtime.scene.surfaceCount > 0 &&
      renderer.gpuBuffersCreated > 0 &&
      renderer.texturesCreated > 0 &&
      renderer.initialUploadBytes > 0 &&
      renderer.dynamicUploads > 0;
  final String terminalLine =
      'doompeller-e1m1-replay: status=${result.status.label} '
      'live_evidence=${passed ? 'pass' : 'fail'} '
      'command_count=${result.commandCount} '
      'command_total=${result.commandTotal} '
      'game_tic=${result.gameTic} '
      'level_complete=${result.levelComplete} '
      'expected_hash=${_hexHash(result.expectedHash)} '
      'actual_hash=${_hexHash(result.actualHash)} '
      'dropped_tics=${runtime.tickDriver.droppedTics} '
      'final_health=${player.health} '
      'final_armor=${player.armor} '
      'kills=${runtime.gameState.killCount} '
      'total_kills=${runtime.gameState.totalKills} '
      'surface_count=${runtime.scene.surfaceCount} '
      'gpu_buffers_created=${renderer.gpuBuffersCreated} '
      'textures_created=${renderer.texturesCreated} '
      'initial_upload_bytes=${renderer.initialUploadBytes} '
      'dynamic_updates=${renderer.dynamicUpdates} '
      'dynamic_uploads=${renderer.dynamicUploads} '
      'dynamic_upload_bytes=${renderer.dynamicUploadBytes} '
      'frame_metric=flutter_frame_timing_total_span '
      'frame_warmup_discarded=${frameWindow.warmupDiscarded} '
      'frame_warmup_worst_frame_number='
      '${frameWindow.warmupWorstFrameNumber} '
      'frame_warmup_worst_total_span_us='
      '${frameWindow.warmupWorstTotalMicros} '
      'frame_warmup_worst_vsync_overhead_us='
      '${frameWindow.warmupWorstVsyncOverheadMicros} '
      'frame_warmup_worst_build_us=${frameWindow.warmupWorstBuildMicros} '
      'frame_warmup_worst_raster_queue_us='
      '${frameWindow.warmupWorstRasterQueueMicros} '
      'frame_warmup_worst_raster_us=${frameWindow.warmupWorstRasterMicros} '
      'frame_sample_count=${frames.count} '
      'frame_deadline_us=${frames.deadlineMicros} '
      'frame_total_span_p95_us=${frames.p95Micros} '
      'frame_total_span_p99_us=${frames.p99Micros} '
      'frame_total_span_max_us=${frames.maxMicros} '
      'frame_build_max_us=${frames.maxBuildMicros} '
      'frame_raster_max_us=${frames.maxRasterMicros} '
      'frame_deadline_misses=${frames.deadlineMisses} '
      'frame_hitches=${frames.hitches}';
  return _LiveReplayEvidence(passed: passed, terminalLine: terminalLine);
}

final class _LiveReplayEvidence {
  const _LiveReplayEvidence({required this.passed, required this.terminalLine});

  final bool passed;
  final String terminalLine;
}

final class _LiveFrameWindow {
  _LiveFrameWindow({required int warmupSamples})
    : assert(warmupSamples >= 0),
      _warmupRemaining = warmupSamples;

  final FrameHistogram histogram = FrameHistogram();
  int _warmupRemaining;
  int warmupDiscarded = 0;
  bool _hasWarmupWorst = false;
  int warmupWorstFrameNumber = -1;
  int warmupWorstTotalMicros = 0;
  int warmupWorstVsyncOverheadMicros = 0;
  int warmupWorstBuildMicros = 0;
  int warmupWorstRasterQueueMicros = 0;
  int warmupWorstRasterMicros = 0;

  void addTimings(List<FrameTiming> timings) {
    for (final FrameTiming timing in timings) {
      if (_warmupRemaining > 0) {
        _warmupRemaining--;
        warmupDiscarded++;
        _captureWorstWarmupFrame(timing);
      } else {
        histogram.addSample(
          totalMicros: timing.totalSpan.inMicroseconds,
          buildMicros: timing.buildDuration.inMicroseconds,
          rasterMicros: timing.rasterDuration.inMicroseconds,
        );
      }
    }
  }

  void _captureWorstWarmupFrame(FrameTiming timing) {
    final int vsyncStart = timing.timestampInMicroseconds(
      FramePhase.vsyncStart,
    );
    final int buildStart = timing.timestampInMicroseconds(
      FramePhase.buildStart,
    );
    final int buildFinish = timing.timestampInMicroseconds(
      FramePhase.buildFinish,
    );
    final int rasterStart = timing.timestampInMicroseconds(
      FramePhase.rasterStart,
    );
    final int rasterFinish = timing.timestampInMicroseconds(
      FramePhase.rasterFinish,
    );
    final int totalMicros = rasterFinish - vsyncStart;
    if (_hasWarmupWorst && totalMicros <= warmupWorstTotalMicros) return;

    _hasWarmupWorst = true;
    warmupWorstFrameNumber = timing.frameNumber;
    warmupWorstTotalMicros = totalMicros;
    warmupWorstVsyncOverheadMicros = buildStart - vsyncStart;
    warmupWorstBuildMicros = buildFinish - buildStart;
    warmupWorstRasterQueueMicros = rasterStart - buildFinish;
    warmupWorstRasterMicros = rasterFinish - rasterStart;
  }
}

String _hexHash(int hash) =>
    '0x${hash.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';

final class _E1m1ReplayApp extends StatefulWidget {
  const _E1m1ReplayApp({
    required this.runtime,
    required this.terminal,
    required this.frameWindow,
  });

  final DoomRuntimeGame runtime;
  final ValueNotifier<DoomReplayResult?> terminal;
  final _LiveFrameWindow frameWindow;

  @override
  State<_E1m1ReplayApp> createState() => _E1m1ReplayAppState();
}

final class _E1m1ReplayAppState extends State<_E1m1ReplayApp> {
  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_recordFrameTimings);
    widget.terminal.dispose();
    super.dispose();
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    widget.frameWindow.addTimings(timings);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Doompeller E1M1 replay',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          GameWidget<DoomRuntimeGame>(
            game: widget.runtime,
            autofocus: true,
            backgroundBuilder: (_) => const ColoredBox(color: Colors.black),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: ValueListenableBuilder<DoomReplayResult?>(
              valueListenable: widget.terminal,
              builder: (BuildContext context, DoomReplayResult? result, _) {
                return ValueListenableBuilder<DoomHudSnapshot>(
                  valueListenable: widget.runtime.hud,
                  builder: (BuildContext context, DoomHudSnapshot hud, _) {
                    final String label = result == null
                        ? 'E1M1 REPLAY RUNNING'
                        : result.passed
                        ? 'E1M1 REPLAY COMPLETE'
                        : 'E1M1 REPLAY ${result.status.label.toUpperCase()}';
                    return DecoratedBox(
                      decoration: const BoxDecoration(color: Color(0xB0000000)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          '$label\n'
                          'COMMAND ${widget.runtime.replayCommandCount}/'
                          '$_productionCommandCount  '
                          'GAME TIC ${widget.runtime.gameState.tic}  '
                          'DROPPED ${hud.diagnostics.droppedTics}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<DoomHudSnapshot>(
              valueListenable: widget.runtime.hud,
              builder: (BuildContext context, DoomHudSnapshot hud, _) =>
                  DoomStatusBar(hud: hud, synthetic: false),
            ),
          ),
        ],
      ),
    ),
  );
}
