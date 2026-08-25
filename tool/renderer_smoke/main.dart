// Renderer smoke harness for the Doompeller adapter.
//
// This exists to prove, in a real macOS window, that the pinned stack actually
// works: Impeller Metal is active, the custom palette shader bundle loads and
// links, and a PackedFlameSurface draws with a moving plane uploading in place.
//
// It is a harness, not the game. lib/game owns the real app.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:doompeller/adapter/adapter.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDoomRenderer();
  runApp(const RendererSmokeApp());
}

/// Identifies the boundary used for in-app frame capture.
///
/// Evidence is captured from the app's own layer tree rather than from the
/// screen, so a capture can never include unrelated windows.
final GlobalKey captureKey = GlobalKey();

class RendererSmokeApp extends StatefulWidget {
  const RendererSmokeApp({super.key});

  @override
  State<RendererSmokeApp> createState() => _RendererSmokeAppState();
}

class _RendererSmokeAppState extends State<RendererSmokeApp> {
  @override
  void initState() {
    super.initState();
    final target = Platform.environment['DOOMPELLER_CAPTURE'];
    if (target != null && target.isNotEmpty) {
      final delayMillis = int.tryParse(
        Platform.environment['DOOMPELLER_CAPTURE_DELAY_MS'] ?? '',
      );
      _scheduleCapture(target, delayMillis: delayMillis ?? 6000);
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
        child: GameWidget(game: RendererSmokeGame()),
      ),
    ),
  );
}
