import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';

import 'content_source.dart';
import 'level_load_coordinator.dart';

/// Complete CPU-side level bundle. GPU objects are assembled synchronously only
/// after the load-generation fence accepts this value.
final class PreparedDoomLevel {
  const PreparedDoomLevel({
    required this.content,
    required this.resources,
    required this.map,
    required this.geometry,
    required this.gameConfig,
    required this.seed,
  });

  final DoomContent content;
  final WadResources resources;
  final MapData map;
  final CompiledLevel geometry;
  final GameConfig gameConfig;
  final int seed;

  /// Recreates only the deterministic simulation over this prepared level.
  /// Parsed WAD resources and compiled GPU-ready geometry stay shared.
  GameState createGame() => GameState.start(map, gameConfig, seed: seed);

  /// Actor sprite prefixes declared by the immutable source THINGS. This must
  /// never depend on a live [GameState], because pickups and deaths remove or
  /// change actors before another runtime is assembled from this level.
  /// Projectiles and weapon overlays are added by the renderer's explicit
  /// supplemental sprite list.
  Set<String> get initialSpritePrefixes => <String>{
    for (final thing in map.things)
      if (DoomCoreCatalog.infoForEdNum(thing.type) case final MobjInfo info)
        info.spriteName,
  };
}

/// WAD -> resources/map -> BSP geometry -> deterministic runtime.
///
/// Every stage is pure CPU work. [LevelLoadCoordinator] calls this
/// asynchronously and checks [LevelLoadToken] between stages, so stale results
/// can never be assembled into Flame GPU objects.
final class DoomLevelPreparer {
  DoomLevelPreparer({
    this.limits = DoomLimits.defaults,
    GeometryOptions? geometryOptions,
    this.gameConfig = const GameConfig(),
    this.seed = 0,
  }) : geometryOptions = (geometryOptions ?? GeometryOptions.defaults).copyWith(
         limits: limits,
       );

  final DoomLimits limits;
  final GeometryOptions geometryOptions;
  final GameConfig gameConfig;
  final int seed;

  Future<PreparedDoomLevel> prepare(
    DoomContent content,
    LevelLoadToken token,
  ) async {
    token.throwIfCancelled();
    final WadResources resources = WadResources.load(
      content.wads,
      limits: limits,
    );
    token.throwIfCancelled();
    final MapData map = MapData.load(
      content.wads,
      content.mapName,
      limits: limits,
    );
    token.throwIfCancelled();
    final CompiledLevel geometry = DoomGeometryCompiler.compile(
      map,
      resources,
      options: geometryOptions,
    );
    token.throwIfCancelled();
    return PreparedDoomLevel(
      content: content,
      resources: resources,
      map: map,
      geometry: geometry,
      gameConfig: gameConfig,
      seed: seed,
    );
  }
}
