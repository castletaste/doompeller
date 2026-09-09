import 'dart:async';

import 'package:flutter/foundation.dart';
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
    this.entryLoadout,
  });

  final DoomContent content;
  final WadResources resources;
  final MapData map;
  final CompiledLevel geometry;
  final GameConfig gameConfig;
  final int seed;
  final PlayerLoadout? entryLoadout;

  /// Recreates only the deterministic simulation over this prepared level.
  /// Parsed resources stay shared; each renderer copies the geometry template.
  GameState createGame() =>
      GameState.start(map, gameConfig, seed: seed, loadout: entryLoadout);

  PreparedDoomLevel withEntryLoadout(PlayerLoadout loadout) =>
      PreparedDoomLevel(
        content: content,
        resources: resources,
        map: map,
        geometry: geometry,
        gameConfig: gameConfig,
        seed: seed,
        entryLoadout: loadout,
      );

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

/// Sendable CPU inputs. Tokens, controllers and callbacks stay on the UI isolate.
final class DoomLevelPreparationRequest {
  const DoomLevelPreparationRequest({
    required this.content,
    required this.limits,
    required this.geometryOptions,
    required this.gameConfig,
    required this.seed,
  });

  final DoomContent content;
  final DoomLimits limits;
  final GeometryOptions geometryOptions;
  final GameConfig gameConfig;
  final int seed;
}

typedef DoomLevelWorker =
    Future<PreparedDoomLevel> Function(DoomLevelPreparationRequest request);

/// Owns one active CPU job and one replaceable pending request. Sharing this
/// preparer across controller replacements bounds native isolate admission.
/// Cancellation fences publication; an active worker is allowed to finish.
final class DoomLevelPreparer {
  DoomLevelPreparer({
    this.limits = DoomLimits.defaults,
    GeometryOptions? geometryOptions,
    this.gameConfig = const GameConfig(),
    this.seed = 0,
    DoomLevelWorker? worker,
  }) : geometryOptions = (geometryOptions ?? GeometryOptions.defaults).copyWith(
         limits: limits,
       ),
       _worker = worker ?? _computeLevel;

  final DoomLimits limits;
  final GeometryOptions geometryOptions;
  final GameConfig gameConfig;
  final int seed;
  final DoomLevelWorker _worker;
  bool _running = false;
  _PendingPreparation? _pending;

  Future<PreparedDoomLevel> prepare(
    DoomContent content,
    LevelLoadToken token,
  ) async {
    token.throwIfCancelled();
    final pending = _PendingPreparation(
      DoomLevelPreparationRequest(
        content: content,
        limits: limits,
        geometryOptions: geometryOptions,
        gameConfig: gameConfig,
        seed: seed,
      ),
      token,
    );
    if (_running) {
      final previous = _pending;
      _pending = pending;
      previous?.result.completeError(
        LevelLoadCancelled(previous.token.generation),
      );
    } else {
      _running = true;
      unawaited(_run(pending));
    }
    return pending.result.future;
  }

  Future<void> _run(_PendingPreparation job) async {
    try {
      job.token.throwIfCancelled();
      final prepared = await _worker(job.request);
      job.token.throwIfCancelled();
      job.result.complete(prepared);
    } catch (error, stackTrace) {
      job.result.completeError(error, stackTrace);
    } finally {
      final next = _pending;
      _pending = null;
      if (next == null) {
        _running = false;
      } else {
        unawaited(_run(next));
      }
    }
  }
}

final class _PendingPreparation {
  _PendingPreparation(this.request, this.token);

  final DoomLevelPreparationRequest request;
  final LevelLoadToken token;
  final Completer<PreparedDoomLevel> result = Completer();
}

Future<PreparedDoomLevel> _computeLevel(
  DoomLevelPreparationRequest request,
) async {
  final prepared = await compute(
    _prepareLevel,
    request,
    debugLabel: 'Doom level preparation',
  );
  // Keep the caller's source identity across episode transitions. The worker's
  // resource caches and geometry are transferred back as one CPU result.
  return PreparedDoomLevel(
    content: request.content,
    resources: prepared.resources,
    map: prepared.map,
    geometry: prepared.geometry,
    gameConfig: request.gameConfig,
    seed: request.seed,
  );
}

// compute runs this on a native isolate. On web it uses the calling event loop;
// yielding between stages lets loading UI progress, but a stage is still CPU
// synchronous there. No Flame, GPU or Flutter binding enters the worker.
Future<PreparedDoomLevel> _prepareLevel(
  DoomLevelPreparationRequest request,
) async {
  final resources = WadResources.load(
    request.content.wads,
    limits: request.limits,
  );
  await Future<void>.delayed(Duration.zero);
  final map = MapData.load(
    request.content.wads,
    request.content.mapName,
    limits: request.limits,
  );
  await Future<void>.delayed(Duration.zero);
  final geometry = DoomGeometryCompiler.compile(
    map,
    resources,
    options: request.geometryOptions,
  );
  return PreparedDoomLevel(
    content: request.content,
    resources: resources,
    map: map,
    geometry: geometry,
    gameConfig: request.gameConfig,
    seed: request.seed,
  );
}
