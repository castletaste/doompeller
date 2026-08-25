// Renderer smoke harness for the Doompeller adapter.
//
// This exists to prove, in a real macOS window, that the pinned stack actually
// works: Impeller Metal is active, the custom palette shader bundle loads and
// links, and a PackedFlameSurface draws with a moving plane uploading in place.
//
// It is a harness, not the game. lib/game owns the real app.
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:doompeller/adapter/adapter.dart';
import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

void main() {
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
      _scheduleCapture(target);
    }
  }

  /// Writes one rendered frame under the app's own temp directory, then exits.
  ///
  /// The macOS app runs sandboxed, so it can only write inside its container.
  /// [name] is a file name, never an absolute path; the resolved location is
  /// printed so a caller can copy the artifact out.
  Future<void> _scheduleCapture(String name) async {
    // Let the scene build, upload and animate before sampling a frame.
    await Future<void>.delayed(const Duration(seconds: 6));
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

/// Builds one atlas page, one merged surface and one moving plane.
class RendererSmokeGame extends FlameGame3D {
  RendererSmokeGame()
    : super(
        camera: CameraComponent3D(
          position: Vector3(0, 96, 200),
          target: Vector3(0, 32, 0),
        ),
      );

  final RenderDiagnostics diagnostics = RenderDiagnostics();
  final FrameHistogram histogram = FrameHistogram();

  DoomScene? _scene;
  double _elapsed = 0;
  int _reported = 0;

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    final scene = DoomScene.build(
      _buildLevel(),
      diagnostics: diagnostics,
    );
    _scene = scene;
    world.add(scene.root);

    SchedulerBinding.instance.addTimingsCallback(histogram.addTimings);
    debugPrint(
      'doompeller-smoke: scene built, surfaces=${scene.surfaceCount} '
      'triangles=${diagnostics.triangles}',
    );
  }

  @override
  void update(double dt) {
    super.update(dt);
    final scene = _scene;
    if (scene == null) {
      return;
    }

    _elapsed += dt;

    // A lift oscillating between 0 and 64 units, rewriting heights in place.
    final phase = (_elapsed % 4) / 4;
    final height = (phase < 0.5 ? phase : 1 - phase) * 128;
    scene.updateSectorPlane(
      sectorIndex: 1,
      height: height.roundToDouble(),
      isCeiling: false,
    );

    // Report once a second so a short run leaves evidence in the log.
    final second = _elapsed.floor();
    if (second > _reported && second % 2 == 0) {
      _reported = second;
      debugPrint(
        'doompeller-smoke: t=${second}s ${histogram.summarize()} '
        'buffers=${diagnostics.gpuBuffersCreated} '
        'dynamicUploads=${diagnostics.dynamicUploads}',
      );
    }
  }
}

/// A generated level: no WAD data, no commercial assets.
CompiledLevelInput _buildLevel() {
  const atlasSize = 64;
  final indices = Uint8List(atlasSize * atlasSize);
  for (var y = 0; y < atlasSize; y++) {
    for (var x = 0; x < atlasSize; x++) {
      // A checker of two palette ramps, so a wrong COLORMAP row or palette row
      // is visible at a glance.
      final checker = ((x ~/ 8) + (y ~/ 8)).isEven;
      indices[y * atlasSize + x] = checker ? 96 + (x % 32) : 176 + (y % 32);
    }
  }

  // A synthetic COLORMAP: row r darkens each index toward black.
  final colorMaps = Uint8List(34 * 256);
  for (var row = 0; row < 34; row++) {
    for (var index = 0; index < 256; index++) {
      final darkened = index - row * 2;
      colorMaps[row * 256 + index] = darkened < 0 ? 0 : darkened;
    }
  }

  // A synthetic 14-row PLAYPAL.
  final palettes = Uint8List(DoomPaletteVariant.count * 256 * 3);
  for (var row = 0; row < DoomPaletteVariant.count; row++) {
    for (var index = 0; index < 256; index++) {
      final offset = (row * 256 + index) * 3;
      palettes[offset] = index;
      palettes[offset + 1] = row == 0 ? (index * 3 ~/ 4) : index ~/ 3;
      palettes[offset + 2] = row == 0 ? index ~/ 2 : index ~/ 4;
    }
  }

  final textures = PaletteTextures(
    PaletteTextureData.encode(
      atlasWidth: atlasSize,
      atlasHeight: atlasSize,
      atlasIndices: indices,
      colorMaps: colorMaps,
      palettes: palettes,
    ),
  );

  return CompiledLevelInput(
    meshes: [
      _floorQuad(y: 0, halfExtent: 128, light: 0.9),
      _floorQuad(y: 0, halfExtent: 40, light: 0.6, offsetX: 200),
    ],
    atlasPages: {'world': textures},
    floorPlanes: const [
      SectorPlaneRef(
        sectorIndex: 1,
        atlasPage: 'world',
        vertexIndices: [4, 5, 6, 7],
        bounds: SceneBounds(
          minX: 160,
          minY: 0,
          minZ: -40,
          maxX: 240,
          maxY: 128,
          maxZ: 40,
        ),
      ),
    ],
  );
}

SceneMeshInput _floorQuad({
  required double y,
  required double halfExtent,
  required double light,
  double offsetX = 0,
}) {
  final vertices = DoomVertexAbi.allocate(4);
  final tiles = halfExtent / 32;

  void write(int index, double x, double z, double u, double v) {
    DoomVertexAbi.writeVertex(
      vertices,
      index,
      x: x,
      y: y,
      z: z,
      u: u,
      v: v,
      ny: 1,
      light: light,
      uvMode: DoomVertexAbi.uvModeRepeat,
    );
  }

  write(0, offsetX - halfExtent, -halfExtent, 0, 0);
  write(1, offsetX + halfExtent, -halfExtent, tiles, 0);
  write(2, offsetX + halfExtent, halfExtent, tiles, tiles);
  write(3, offsetX - halfExtent, halfExtent, 0, tiles);

  return SceneMeshInput(
    vertices: vertices,
    indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
    atlasPage: 'world',
    kind: DoomSurfaceKind.opaque,
    bounds: SceneBounds(
      minX: offsetX - halfExtent,
      minY: y,
      minZ: -halfExtent,
      maxX: offsetX + halfExtent,
      maxY: y,
      maxZ: halfExtent,
    ),
  );
}
