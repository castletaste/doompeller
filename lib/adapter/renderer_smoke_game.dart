import 'dart:math' as math;

import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'doom_scene.dart';
import 'frame_histogram.dart';
import 'render_diagnostics.dart';

/// Initializes the pinned GPU backend before a FlameGame3D is constructed.
Future<void> initializeDoomRenderer() => GpuBackend.initialize();

/// Real synthetic-WAD smoke harness kept inside the renderer boundary.
///
/// The tool entrypoint only owns Flutter's app shell. This class owns every
/// flame_3d type and compiles DoomFixtures through WadResources, MapData and
/// DoomGeometryCompiler before publishing a [DoomScene].
final class RendererSmokeGame extends FlameGame3D {
  RendererSmokeGame()
    : super(
        camera: CameraComponent3D(
          position: Vector3(384, 96, -384),
          target: Vector3(384, 48, -256),
        ),
      );

  final RenderDiagnostics diagnostics = RenderDiagnostics();
  final FrameHistogram histogram = FrameHistogram();

  DoomScene? _scene;
  geometry.CompiledLevel? _level;
  late List<double> _floors;
  late List<double> _ceilings;
  double _elapsed = 0;
  int _reported = 0;
  bool _warmWindowStarted = false;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    final set = wad.DoomFixtures.wadSet();
    final resources = wad.WadResources.load(set);
    final map = wad.MapData.load(set, wad.DoomFixtures.mapName);
    final level = geometry.DoomGeometryCompiler.compile(map, resources);
    if (level.skyTextureEntry == null) {
      throw StateError('DoomFixtures must publish its generated SKY1 probe');
    }
    final scene = DoomScene.fromCompiledLevel(
      level,
      resources,
      diagnostics: diagnostics,
      spritePrefixes: const <String>{'TEST'},
    );
    scene
      ..addActorSprite(
        const ActorSpriteInstance(spritePrefix: 'TEST', x: 512, y: 0, z: -320),
      )
      ..addWeaponSprite(
        const WeaponSpriteInstance(
          lumpName: 'TESTB0',
          viewAnchorX: 0.2,
          viewAnchorY: -0.45,
        ),
      );
    _level = level;
    _scene = scene;
    _floors = <double>[
      for (final sector in map.sectors) sector.floorHeight.toDouble(),
    ];
    _ceilings = <double>[
      for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
    ];
    world.add(scene.root);
    SchedulerBinding.instance.addTimingsCallback(histogram.addTimings);
    debugPrint(
      'doompeller-smoke: fixture=${map.name} surfaces=${scene.surfaceCount} '
      'buffers=pending triangles=${diagnostics.triangles} '
      'atlasPages=${level.atlas.pageCount} '
      'sky=${level.skyTextureName} syntheticSkyProbe=false',
    );
  }

  @override
  void update(double dt) {
    super.update(dt);
    final scene = _scene;
    final level = _level;
    if (scene == null || level == null || level.floorPlanes.isEmpty) {
      return;
    }
    _elapsed += dt;
    if (!_warmWindowStarted && _elapsed >= 5) {
      _warmWindowStarted = true;
      histogram.clear();
      debugPrint('doompeller-smoke: warmed frame window started at t=5s');
    }
    final plane = level.floorPlanes.first;
    final phase = (_elapsed % 4) / 4;
    final offset = (phase < 0.5 ? phase : 1 - phase) * 64;
    final height = plane.baseHeight + offset.roundToDouble();
    _floors[plane.sector] = height;
    scene.updateSectorPlane(
      sectorIndex: plane.sector,
      height: height,
      isCeiling: false,
    );
    scene.updateWallsForSector(
      sectorIndex: plane.sector,
      floorHeight: height,
      ceilingHeight: _ceilings[plane.sector],
      sectorFloors: _floors,
      sectorCeilings: _ceilings,
    );

    final yaw = _elapsed * 0.25;
    camera.target.setValues(
      camera.position.x + math.sin(yaw) * 128,
      camera.position.y - 32,
      camera.position.z - math.cos(yaw) * 128,
    );

    final second = _elapsed.floor();
    if (second > _reported && second.isEven) {
      _reported = second;
      debugPrint(
        'doompeller-smoke: t=${second}s ${histogram.summarize()} '
        'surfaces=${scene.surfaceCount} '
        'buffersCreated=${diagnostics.gpuBuffersCreated} '
        'dynamicUploads=${diagnostics.dynamicUploads} '
        'dynamicUploadBytes=${diagnostics.dynamicUploadBytes} '
        'triangles=${diagnostics.triangles}',
      );
    }
  }
}
