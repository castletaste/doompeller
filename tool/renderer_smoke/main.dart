// Renderer smoke harness for the Doompeller adapter.
//
// This exists to prove, in a real macOS window, that the pinned stack actually
// works: Impeller Metal is active, the custom palette shader bundle loads and
// links, and a PackedFlameSurface draws with a moving plane uploading in place.
//
// It is a harness, not the game. lib/game owns the real app.
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:doompeller/adapter/adapter.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDoomRenderer();
  runApp(RendererSmokeApp(config: _configFromEnvironment()));
}

RendererSmokeConfig _configFromEnvironment() {
  final String mapValue =
      Platform.environment['DOOMPELLER_SMOKE_MAP']?.trim().toLowerCase() ??
      'fixture';
  final RendererSmokeMap map = switch (mapValue) {
    'fixture' => RendererSmokeMap.fixture,
    'scale' || 'scale-fixture' => RendererSmokeMap.scaleFixture,
    _ => throw ArgumentError.value(
      mapValue,
      'DOOMPELLER_SMOKE_MAP',
      'expected fixture or scale',
    ),
  };
  return RendererSmokeConfig(
    map: map,
    warmup: Duration(
      seconds: _positiveSeconds('DOOMPELLER_SMOKE_WARMUP_SECONDS', 5),
    ),
    measurement: Duration(
      seconds: _positiveSeconds('DOOMPELLER_SMOKE_MEASURE_SECONDS', 15),
    ),
  );
}

int _positiveSeconds(String name, int fallback) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) return fallback;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError.value(value, name, 'must be a positive integer');
  }
  return parsed;
}

/// Identifies the boundary used for in-app frame capture.
///
/// Evidence is captured from the app's own layer tree rather than from the
/// screen, so a capture can never include unrelated windows.
final GlobalKey captureKey = GlobalKey();

class RendererSmokeApp extends StatefulWidget {
  const RendererSmokeApp({required this.config, super.key});

  final RendererSmokeConfig config;

  @override
  State<RendererSmokeApp> createState() => _RendererSmokeAppState();
}

class _RendererSmokeAppState extends State<RendererSmokeApp> {
  late final RendererSmokeGame _game;
  bool _resultWritten = false;

  @override
  void initState() {
    super.initState();
    _game = RendererSmokeGame(
      config: widget.config,
      onComplete: _writeResultAndExit,
    );
    final target = Platform.environment['DOOMPELLER_CAPTURE'];
    if (target != null && target.isNotEmpty) {
      final delayMillis = int.tryParse(
        Platform.environment['DOOMPELLER_CAPTURE_DELAY_MS'] ?? '',
      );
      _scheduleCapture(target, delayMillis: delayMillis ?? 6000);
    }
  }

  Future<void> _writeResultAndExit(Map<String, Object?> result) async {
    if (_resultWritten) return;
    _resultWritten = true;
    final defaultName = widget.config.map == RendererSmokeMap.scaleFixture
        ? 'renderer_smoke_scale.json'
        : 'renderer_smoke_fixture.json';
    final requested =
        Platform.environment['DOOMPELLER_SMOKE_ARTIFACT'] ?? defaultName;
    final name = requested.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final enriched = <String, Object?>{
      ...result,
      'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
      'host': <String, Object?>{
        'operating_system': Platform.operatingSystem,
        'operating_system_version': Platform.operatingSystemVersion,
        'local_cpu_count': Platform.numberOfProcessors,
      },
    };
    try {
      final file = File('${Directory.systemTemp.path}/$name');
      const encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString('${encoder.convert(enriched)}\n', flush: true);
      debugPrint('doompeller-smoke: artifact=${file.path}');
      debugPrint('doompeller-smoke: copy this file into artifacts/$name');
      exit(0);
    } on FileSystemException catch (error) {
      debugPrint('doompeller-smoke: artifact write failed: $error');
      exit(4);
    }
  }

  /// Writes one rendered frame under the app's own temp directory, then exits.
  ///
  /// The macOS app runs sandboxed, so it can only write inside its container.
  /// [name] is a file name, never an absolute path; the resolved location is
  /// printed so a caller can copy the artifact out.
  Future<void> _scheduleCapture(String name, {required int delayMillis}) async {
    // Let the scene build, upload and animate before sampling a frame.
    await Future<void>.delayed(Duration(milliseconds: delayMillis));
    final boundary =
        captureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      debugPrint('doompeller-smoke: capture failed, no boundary');
      exit(2);
    }
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      debugPrint('doompeller-smoke: capture failed, no bytes');
      exit(3);
    }
    final file = File('${Directory.systemTemp.path}/$name')
      ..writeAsBytesSync(bytes.buffer.asUint8List());
    debugPrint(
      'doompeller-smoke: captured ${file.path} (${bytes.lengthInBytes} bytes)',
    );
    exit(0);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Doompeller renderer smoke',
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: Colors.black,
      body: RepaintBoundary(
        key: captureKey,
        child: GameWidget(game: _game),
      ),
    ),
  );
}
