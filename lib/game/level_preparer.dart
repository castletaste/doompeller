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
    required this.game,
  });

  final DoomContent content;
  final WadResources resources;
  final MapData map;
  final CompiledLevel geometry;
  final GameState game;

  /// Actor sprite prefixes that exist at level start. Projectiles and weapon
  /// overlays are added by the renderer's explicit supplemental sprite list.
  Set<String> get initialSpritePrefixes => <String>{
    for (final MobjView actor in game.mobjs) actor.sprite,
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
    final GameState game = GameState.start(map, gameConfig, seed: seed);
    token.throwIfCancelled();
    return PreparedDoomLevel(
      content: content,
      resources: resources,
      map: map,
      geometry: geometry,
      game: game,
    );
  }
}
