import 'dart:math' as math;

import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../game/content_source.dart';
import 'doom_runtime_game.dart';
import 'doom_scene.dart';
import 'doom_camera.dart';
import 'frame_histogram.dart';
import 'render_diagnostics.dart';
import 'renderer_smoke_trajectory.dart';

/// Initializes the pinned GPU backend before a FlameGame3D is constructed.
Future<void> initializeDoomRenderer() => GpuBackend.initialize();

enum RendererSmokeMap { fixture, scaleFixture, developerIwad }

/// A bounded, reproducible renderer measurement.
final class RendererSmokeConfig {
  const RendererSmokeConfig({
    this.map = RendererSmokeMap.fixture,
    this.mapName = 'E1M1',
    this.warmup = const Duration(seconds: 15),
    this.measurement = const Duration(seconds: 15),
  });

  final RendererSmokeMap map;
  final String mapName;
  final Duration warmup;
  final Duration measurement;
}

/// Selects smoke content without scanning for or embedding developer assets.
///
/// Tests inject a [DoomContentSource] backed by the generated fixture. The live
/// developer mode uses the same source as the app and reads only the explicit
/// `DOOM_WAD_PATH` value.
Future<DoomContent> resolveRendererSmokeContent(
  RendererSmokeConfig config, {
  DoomContentSource? contentSource,
}) async {
  final source = contentSource ?? DoomContentSource();
  switch (config.map) {
    case RendererSmokeMap.fixture:
      return source.loadFixture();
    case RendererSmokeMap.scaleFixture:
      return DoomContent(
        wads: wad.DoomScaleFixture.wadSet(),
        mapName: wad.DoomScaleFixture.mapName,
        origin: DoomContentOrigin.syntheticFixture,
      );
    case RendererSmokeMap.developerIwad:
      final result = await source.loadDeveloperIwad(mapName: config.mapName);
      return switch (result) {
        DoomContentLoaded(:final content) => content,
        DoomContentPathMissing(:final setupMessage) => throw StateError(
          setupMessage,
        ),
        DoomContentLoadFailure(:final message) => throw StateError(message),
      };
  }
}

typedef RendererSmokeComplete = void Function(Map<String, Object?> result);

/// WAD performance harness kept inside the renderer boundary.
///
/// Fixture and developer-IWAD modes traverse the production WAD -> resources
/// -> geometry -> packed surfaces -> palette material -> Flame 3D path. Direct
/// plane mutations deliberately call the same [DoomScene] dynamic APIs used by
/// the production runtime, but do not prove gameplay special activation.
final class RendererSmokeGame extends FlameGame3D {
  RendererSmokeGame({
    this.config = const RendererSmokeConfig(),
    this.content,
    this.onComplete,
  }) : super(
         camera: DoomCameraComponent(
           position: Vector3(384, 96, -384),
           target: Vector3(384, 48, -256),
         ),
       );

  final RendererSmokeConfig config;
  final DoomContent? content;
  final RendererSmokeComplete? onComplete;
  final RenderDiagnostics diagnostics = RenderDiagnostics();
  final FrameHistogram histogram = FrameHistogram();

  DoomScene? _scene;
  geometry.CompiledLevel? _level;
  wad.MapData? _map;
  late List<double> _floors;
  late List<double> _ceilings;
  late List<double> _baseFloors;
  late List<double> _baseCeilings;
  geometry.SectorPlaneRef? _liftPlane;
  geometry.SectorPlaneRef? _doorPlane;
  late RendererSmokeTrajectory _cameraTrajectory;
  double _elapsed = 0;
  double _measurementStartedAt = 0;
  int _reported = 0;
  int _warmupDiscardedFrames = 0;
  int _lastDynamicUploads = 0;
  int _lastDynamicUploadBytes = 0;
  int _measurementDynamicUploads = 0;
  int _measurementDynamicUploadBytes = 0;
  int _maxDynamicUploadsPerFrame = 0;
  int _maxDynamicUploadBytesPerFrame = 0;
  int _drawSamples = 0;
  int _drawSum = 0;
  int _maxDraws = 0;
  int _lastDraws = 0;
  int _wallQuadsUpdated = 0;
  int _animationVerticesUpdated = 0;
  int _renderedActorSprites = 0;
  bool _measuring = false;
  bool _completed = false;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    final selectedContent =
        content ?? await resolveRendererSmokeContent(config);
    final set = selectedContent.wads;
    final mapName = selectedContent.mapName;
    final resources = wad.WadResources.load(set);
    final map = wad.MapData.load(set, mapName);
    final level = geometry.DoomGeometryCompiler.compile(map, resources);
    final core.GameState? gameState =
        config.map == RendererSmokeMap.developerIwad
        ? core.GameState.start(map, const core.GameConfig())
        : null;
    final Set<String> availablePrefixes = <String>{
      for (final name in resources.spriteNames)
        if (name.length >= 4) name.substring(0, 4).toUpperCase(),
    };
    final Set<String> actorPrefixes = <String>{
      for (final actor in gameState?.mobjs ?? const <core.MobjView>[])
        if (actor.sprite != 'PLAY') actor.sprite.toUpperCase(),
    }.intersection(availablePrefixes);
    final scene = DoomScene.fromCompiledLevel(
      level,
      resources,
      diagnostics: diagnostics,
      spritePrefixes: <String>{
        ...actorPrefixes,
        if (config.map == RendererSmokeMap.fixture) 'TEST',
        if (config.map == RendererSmokeMap.developerIwad &&
            availablePrefixes.contains('PISG'))
          'PISG',
      },
    );
    if (config.map == RendererSmokeMap.fixture) {
      if (level.skyTextureEntry == null) {
        throw StateError('DoomFixtures must publish its generated SKY1 probe');
      }
      scene
        ..addActorSprite(
          const ActorSpriteInstance(
            spritePrefix: 'TEST',
            x: 512,
            y: 0,
            z: -320,
          ),
        )
        ..addWeaponSprite(
          const WeaponSpriteInstance(
            lumpName: 'TESTB0',
            viewAnchorX: 0.2,
            viewAnchorY: -0.45,
          ),
        );
    }
    if (gameState != null) {
      _renderedActorSprites = _addDeveloperActors(
        scene,
        gameState.mobjs,
        actorPrefixes,
      );
      if (resources.spriteNames.contains('PISGA0')) {
        scene.addWeaponSprite(
          const WeaponSpriteInstance(
            lumpName: 'PISGA0',
            viewAnchorX: 0,
            viewAnchorY: -0.48,
          ),
        );
      }
    }

    _map = map;
    _level = level;
    _scene = scene;
    _floors = <double>[
      for (final sector in map.sectors) sector.floorHeight.toDouble(),
    ];
    _ceilings = <double>[
      for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
    ];
    _baseFloors = List<double>.of(_floors);
    _baseCeilings = List<double>.of(_ceilings);
    _selectDynamicPlanes(level);
    _cameraTrajectory = RendererSmokeTrajectory.fromLevel(
      map,
      level,
      excludedSectors: <int>{
        if (_liftPlane != null) _liftPlane!.sector,
        if (_doorPlane != null) _doorPlane!.sector,
      },
    );
    world.add(scene.root);
    _applyCameraTrajectory(0);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _lastDynamicUploads = diagnostics.dynamicUploads;
    _lastDynamicUploadBytes = diagnostics.dynamicUploadBytes;
    debugPrint(
      'doompeller-smoke: map=$mapName surfaces=${scene.surfaceCount} '
      'buffers=pending vertices=${_vertexCount(level)} '
      'triangles=${diagnostics.triangles} meshes=${level.meshes.length} '
      'atlasPages=${level.atlas.pageCount} '
      'actors=$_renderedActorSprites '
      'dynamic=map_animations_plus_synthetic_harness_planes',
    );
  }

  void _onTimings(List<FrameTiming> timings) => histogram.addTimings(timings);

  @override
  void update(double dt) {
    super.update(dt);
    final scene = _scene;
    final level = _level;
    if (scene == null || level == null || _completed) {
      return;
    }
    _samplePreviousFrame();
    _elapsed += dt;
    _applyCameraTrajectory(
      _measuring ? _elapsed - _measurementStartedAt : _elapsed,
    );
    _animationVerticesUpdated += scene.updateTextureAnimations(
      (_elapsed * core.kTicRate).floor(),
    );
    _applyDynamicWorkload(scene, _elapsed);

    if (!_measuring && _elapsed >= config.warmup.inMicroseconds / 1000000) {
      _beginMeasurement();
    }
    if (_measuring &&
        _elapsed - _measurementStartedAt >=
            config.measurement.inMicroseconds / 1000000) {
      _finishMeasurement(scene, level);
      return;
    }

    final second = _elapsed.floor();
    if (second > _reported && second.isEven) {
      _reported = second;
      debugPrint(
        'doompeller-smoke: t=${second}s phase='
        '${_measuring ? 'measure' : 'warmup'} ${histogram.summarize()} '
        'surfaces=${scene.surfaceCount} draws=$_lastDraws '
        'buffersCreated=${diagnostics.gpuBuffersCreated} '
        'dynamicUploads=${diagnostics.dynamicUploads} '
        'dynamicUploadBytes=${diagnostics.dynamicUploadBytes}',
      );
    }
  }

  void _beginMeasurement() {
    _warmupDiscardedFrames = histogram.length + histogram.droppedByOverflow;
    histogram.clear();
    _measuring = true;
    _measurementStartedAt = _elapsed;
    _measurementDynamicUploads = diagnostics.dynamicUploads;
    _measurementDynamicUploadBytes = diagnostics.dynamicUploadBytes;
    _maxDynamicUploadsPerFrame = 0;
    _maxDynamicUploadBytesPerFrame = 0;
    _animationVerticesUpdated = 0;
    _drawSamples = 0;
    _drawSum = 0;
    _maxDraws = 0;
    debugPrint(
      'doompeller-smoke: warmed frame window started at '
      't=${_elapsed.toStringAsFixed(2)}s; discardedFrameTimings='
      '$_warmupDiscardedFrames',
    );
  }

  void _samplePreviousFrame() {
    final int draws = world.context.drawCount;
    _lastDraws = draws;
    final int uploads = diagnostics.dynamicUploads;
    final int uploadBytes = diagnostics.dynamicUploadBytes;
    final int uploadsThisFrame = uploads - _lastDynamicUploads;
    final int bytesThisFrame = uploadBytes - _lastDynamicUploadBytes;
    _lastDynamicUploads = uploads;
    _lastDynamicUploadBytes = uploadBytes;
    if (!_measuring) return;

    _drawSamples++;
    _drawSum += draws;
    if (draws > _maxDraws) {
      _maxDraws = draws;
    }
    _maxDynamicUploadsPerFrame = math.max(
      _maxDynamicUploadsPerFrame,
      uploadsThisFrame,
    );
    _maxDynamicUploadBytesPerFrame = math.max(
      _maxDynamicUploadBytesPerFrame,
      bytesThisFrame,
    );
  }

  void _finishMeasurement(DoomScene scene, geometry.CompiledLevel level) {
    _completed = true;
    _measuring = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    final summary = histogram.summarize();
    final render = diagnostics.snapshot();
    final map = _map!;
    final int dynamicUploads =
        render.dynamicUploads - _measurementDynamicUploads;
    final int dynamicUploadBytes =
        render.dynamicUploadBytes - _measurementDynamicUploadBytes;
    final double deadlineMillis = summary.deadlineMicros / 1000;
    final double marginMillis = deadlineMillis - summary.p95Millis;
    final String dominantPhase =
        summary.p95RasterMicros >= summary.p95BuildMicros
        ? 'raster_duration'
        : 'build_duration';
    final result = <String, Object?>{
      'schema_version': 2,
      'tool': 'renderer_smoke',
      'scene': <String, Object?>{
        'source': switch (config.map) {
          RendererSmokeMap.fixture => 'synthetic_fixture',
          RendererSmokeMap.scaleFixture => 'synthetic_e1m1_scale_fixture',
          RendererSmokeMap.developerIwad => 'developer_iwad',
        },
        'map': map.name,
        'vertices': map.vertices.length,
        'linedefs': map.linedefs.length,
        'sectors': map.sectors.length,
        'subsectors': map.subsectors.length,
        'nodes': map.nodes.length,
        'things': map.things.length,
        'rendered_actor_sprites': _renderedActorSprites,
        'compiled_vertices': _vertexCount(level),
        'triangles': render.triangles,
        'compiled_meshes': level.meshes.length,
        'atlas_pages': level.atlas.pageCount,
      },
      'run': <String, Object?>{
        'build_mode': kReleaseMode ? 'release' : 'non_release',
        'warmup_seconds': config.warmup.inMicroseconds / 1000000,
        'warmup_discarded_frame_timings': _warmupDiscardedFrames,
        'measurement_seconds': config.measurement.inMicroseconds / 1000000,
        'trajectory': 'playable_floor_triangles_v2',
        'trajectory_segments': const <String>[
          'distributed_real_sector_floors',
          'continuous_in_triangle_room_traversal',
          'instant_transition_between_disconnected_rooms',
        ],
        'trajectory_floor_sectors': _cameraTrajectory.legs.length,
        'frontmost_window_required': true,
      },
      'timings': summary.toJson(),
      'frame_budget': <String, Object?>{
        'target_fps': 60,
        'deadline_ms': deadlineMillis,
        'p95_total_span_ms': summary.p95Millis,
        'p95_margin_ms': marginMillis,
        'p95_within_budget': marginMillis >= 0,
        'dominant_flutter_phase_by_p95': dominantPhase,
      },
      'renderer': <String, Object?>{
        ...render.toJson(),
        'active_surfaces': scene.surfaceCount,
        'draws': <String, Object?>{
          'metric': 'flame3d_render_context_submitted_draws',
          'samples': _drawSamples,
          'mean_per_frame': _drawSamples == 0 ? 0 : _drawSum / _drawSamples,
          'max_per_frame': _maxDraws,
        },
      },
      'dynamic_workload': <String, Object?>{
        'source': config.map == RendererSmokeMap.developerIwad
            ? 'developer_map_animations_plus_synthetic_harness_planes'
            : 'synthetic_harness_driven',
        'map_texture_animation_and_scroll_enabled': true,
        'animation_vertices_updated_during_measurement':
            _animationVerticesUpdated,
        'gameplay_special_activation_proven': false,
        'reason':
            'the renderer harness drives plane mutations directly and does '
            'not issue gameplay commands that activate specials',
        'production_apis': const <String>[
          'DoomScene.updateSectorPlane',
          'DoomScene.updateWallsForSector',
        ],
        'lift_like_floor_sector': _liftPlane?.sector,
        'door_like_ceiling_sector': _doorPlane?.sector,
        'wall_quads_updated': _wallQuadsUpdated,
        'uploads_during_measurement': dynamicUploads,
        'bytes_during_measurement': dynamicUploadBytes,
        'mean_uploads_per_sampled_frame': _drawSamples == 0
            ? 0
            : dynamicUploads / _drawSamples,
        'max_uploads_per_sampled_frame': _maxDynamicUploadsPerFrame,
        'max_bytes_per_sampled_frame': _maxDynamicUploadBytesPerFrame,
      },
      'claims': <String, Object?>{
        'measures': const <String>[
          'Flutter FrameTiming.totalSpan',
          'Flutter FrameTiming.buildDuration',
          'Flutter FrameTiming.rasterDuration',
          'Flame3D submitted draws',
          'Doompeller CPU-side GPU buffer requests and uploads',
        ],
        'does_not_measure': <String>[
          'presented frame rate',
          'Metal GPU execution time',
          'driver-side duration',
          if (config.map != RendererSmokeMap.developerIwad)
            'developer IWAD content',
          'gameplay activation of door or lift specials',
        ],
      },
    };
    debugPrint(
      'doompeller-smoke: complete map=${map.name} $summary '
      'p95Build=${(summary.p95BuildMicros / 1000).toStringAsFixed(2)}ms '
      'p95Raster=${(summary.p95RasterMicros / 1000).toStringAsFixed(2)}ms '
      'margin=${marginMillis.toStringAsFixed(2)}ms maxDraws=$_maxDraws '
      'dynamicUploads=$dynamicUploads',
    );
    onComplete?.call(result);
  }

  void _applyCameraTrajectory(double seconds) {
    final pose = _cameraTrajectory.sample(seconds, _floors);
    camera.position.setValues(pose.x, pose.y, pose.z);
    camera.target.setValues(pose.targetX, pose.targetY, pose.targetZ);
  }

  void _applyDynamicWorkload(DoomScene scene, double seconds) {
    final lift = _liftPlane;
    if (lift != null) {
      final int sector = lift.sector;
      final double available = math.max(
        0,
        _baseCeilings[sector] - _baseFloors[sector] - 32,
      );
      final double amplitude = math.min(24, available);
      final double wave = (math.sin(seconds * math.pi) + 1) * 0.5;
      final double height = _baseFloors[sector] + amplitude * wave;
      if (scene.updateSectorPlane(
        sectorIndex: sector,
        height: height,
        isCeiling: false,
      )) {
        _floors[sector] = height;
        _wallQuadsUpdated += scene.updateWallsForSector(
          sectorIndex: sector,
          floorHeight: height,
          ceilingHeight: _ceilings[sector],
          sectorFloors: _floors,
          sectorCeilings: _ceilings,
        );
      }
    }
    final door = _doorPlane;
    if (door != null) {
      final int sector = door.sector;
      final double available = math.max(
        0,
        _baseCeilings[sector] - _floors[sector] - 32,
      );
      final double amplitude = math.min(32, available);
      final double wave = (math.sin(seconds * math.pi * 0.8 + 1.7) + 1) * 0.5;
      final double height = _baseCeilings[sector] - amplitude * wave;
      if (scene.updateSectorPlane(
        sectorIndex: sector,
        height: height,
        isCeiling: true,
      )) {
        _ceilings[sector] = height;
        _wallQuadsUpdated += scene.updateWallsForSector(
          sectorIndex: sector,
          floorHeight: _floors[sector],
          ceilingHeight: height,
          sectorFloors: _floors,
          sectorCeilings: _ceilings,
        );
      }
    }
  }

  void _selectDynamicPlanes(geometry.CompiledLevel level) {
    final wallSectors = <int>{
      for (final band in level.wallBands) band.frontSector,
      for (final band in level.wallBands)
        if (band.backSector >= 0) band.backSector,
    };
    _liftPlane = _firstPlane(
      level.floorPlanes,
      (plane) => wallSectors.contains(plane.sector),
    );
    _doorPlane = _firstPlane(
      level.ceilingPlanes,
      (plane) =>
          wallSectors.contains(plane.sector) &&
          plane.sector != _liftPlane?.sector,
    );
    _doorPlane ??= _firstPlane(
      level.ceilingPlanes,
      (plane) => wallSectors.contains(plane.sector),
    );
    _liftPlane ??= level.floorPlanes.firstOrNull;
    _doorPlane ??= level.ceilingPlanes.firstOrNull;
  }

  static geometry.SectorPlaneRef? _firstPlane(
    List<geometry.SectorPlaneRef> planes,
    bool Function(geometry.SectorPlaneRef plane) test,
  ) {
    for (final plane in planes) {
      if (test(plane)) return plane;
    }
    return null;
  }

  static int _vertexCount(geometry.CompiledLevel level) =>
      level.meshes.fold(0, (sum, mesh) => sum + mesh.vertexCount);

  static int _addDeveloperActors(
    DoomScene scene,
    Iterable<core.MobjView> actors,
    Set<String> packedPrefixes,
  ) {
    var rendered = 0;
    for (final actor in actors) {
      final String prefix = actor.sprite.toUpperCase();
      if (prefix == 'PLAY' || !packedPrefixes.contains(prefix)) continue;
      final component = scene.acquireActorSprite(
        ActorSpriteInstance(
          spritePrefix: prefix,
          x: core.fixedToDouble(actor.x),
          y: core.fixedToDouble(actor.z),
          z: -core.fixedToDouble(actor.y),
          frame: actor.frame,
          actorAngle: DoomRuntimeGame.worldActorYawForBam(actor.angle),
          light: actor.lightLevel / 255.0,
          fullBright: actor.fullBright,
          fuzz: (actor.flags & core.MobjFlags.shadow) != 0,
        ),
      );
      if (component != null) rendered++;
    }
    return rendered;
  }
}
