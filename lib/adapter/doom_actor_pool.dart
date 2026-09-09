import 'dart:typed_data';

import 'package:flame_3d/resources.dart';
import 'package:vector_math/vector_math.dart';

import 'doom_sprite_atlas.dart';
import 'doom_sprite_components.dart';
import 'packed_surface.dart';
import 'palette_material.dart';
import 'render_diagnostics.dart';

/// Owns actor membership and reuse. The scene registers a surface only once,
/// when the pool allocates it; inactive components retain their GPU resources.
final class DoomActorPool {
  DoomActorPool({
    required DoomSpriteAtlas? atlas,
    required Map<int, PaletteMaterial> materials,
    required this.diagnostics,
    required this.onCreated,
  }) : _spriteAtlas = atlas,
       _spriteMaterials = materials;

  final DoomSpriteAtlas? _spriteAtlas;
  final Map<int, PaletteMaterial> _spriteMaterials;
  final RenderDiagnostics diagnostics;
  final void Function(ActorSpriteComponent component, int page) onCreated;

  final Set<ActorSpriteComponent> _activeActorSprites =
      <ActorSpriteComponent>{};
  final Map<String, List<ActorSpriteComponent>> _actorPool =
      <String, List<ActorSpriteComponent>>{};
  final Map<PackedFlameSurface, ActorSpriteComponent> _actorBySurface =
      <PackedFlameSurface, ActorSpriteComponent>{};

  bool surfaceIsActive(PackedFlameSurface surface) =>
      _actorBySurface[surface]?.active ?? true;

  /// Actor surfaces retained for reuse, active plus pooled.
  int get actorSurfaceRegistryCount =>
      _activeActorSprites.length +
      _actorPool.values.fold<int>(0, (sum, pool) => sum + pool.length);

  int get activeActorSurfaceCount =>
      _activeActorSprites.where((actor) => actor.active).length;

  int get pooledActorSurfaceCount =>
      _actorPool.values.fold<int>(0, (sum, pool) => sum + pool.length);

  bool isActorSpriteActive(ActorSpriteComponent actor) => actor.active;

  /// Acquires an actor billboard, reusing a retained inactive component first.
  /// Returns null when the requested prefix/frame is not in the bounded atlas.
  ActorSpriteComponent? acquireActorSprite(ActorSpriteInstance actor) {
    final spriteAtlas = _spriteAtlas;
    if (spriteAtlas == null) {
      return null;
    }
    final String prefix = actor.spritePrefix.toUpperCase();
    final selection =
        spriteAtlas.catalog.resolve(
          prefix: prefix,
          frame: actor.frame,
          rotation: 0,
        ) ??
        spriteAtlas.catalog.resolve(
          prefix: prefix,
          frame: actor.frame,
          rotation: 1,
        );
    if (selection == null) {
      return null;
    }
    final pool = _actorPool[prefix];
    if (pool != null) {
      for (var index = pool.length - 1; index >= 0; index--) {
        final candidate = pool[index];
        if (candidate.width != actor.width ||
            candidate.height != actor.height) {
          continue;
        }
        pool.removeAt(index);
        if (pool.isEmpty) {
          _actorPool.remove(prefix);
        }
        candidate.reactivate(actor, selection);
        _activeActorSprites.add(candidate);
        return candidate;
      }
    }
    final entry = spriteAtlas.atlas.entry(selection.lumpName)!;
    final material = _spriteMaterials[entry.page]!;
    final quad = actorSpriteQuad(
      entry,
      width: actor.width,
      height: actor.height,
    );
    final vertices = buildSpriteVertices(
      quad: quad,
      entry: entry,
      pageSize: spriteAtlas.atlas.pageSize,
      light: actor.light,
      fullBright: actor.fullBright,
      alpha: actor.fuzz ? 0.5 : 1,
    );
    final surface = PackedFlameSurface(
      vertices: vertices,
      indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
      bounds: quad.bounds,
      material: material,
      kind: DoomSurfaceKind.sprite,
      diagnostics: diagnostics,
      debugLabel: 'actor:$prefix',
    );
    final mesh = Mesh()..addSurface(surface);
    final component = ActorSpriteComponent(
      mesh: mesh,
      position: Vector3(actor.x, actor.y, actor.z),
      surface: surface,
      spriteAtlas: spriteAtlas,
      materialsByPage: _spriteMaterials,
      spritePrefix: prefix,
      frame: actor.frame,
      actorAngle: actor.actorAngle,
      width: actor.width,
      height: actor.height,
      light: actor.light,
      fullBright: actor.fullBright,
      fuzz: actor.fuzz,
      lumpName: selection.lumpName,
      mirrored: selection.mirrored,
    );
    _activeActorSprites.add(component);
    _actorBySurface[surface] = component;
    onCreated(component, entry.page);
    diagnostics
      ..onMeshBuilt()
      ..onComponentBuilt();
    return component;
  }

  /// Updates an active actor in place. A missing frame returns false without
  /// leaving the old visual active; callers should release the component.
  bool updateActorSprite(
    ActorSpriteComponent component,
    ActorSpriteInstance actor,
  ) {
    if (!component.active ||
        component.spritePrefix != actor.spritePrefix.toUpperCase()) {
      return false;
    }
    final selection =
        component.spriteAtlas.catalog.resolve(
          prefix: component.spritePrefix,
          frame: actor.frame,
          rotation: 0,
        ) ??
        component.spriteAtlas.catalog.resolve(
          prefix: component.spritePrefix,
          frame: actor.frame,
          rotation: 1,
        );
    if (selection == null) {
      return false;
    }
    final bool frameChanged = component.frame != actor.frame;
    component.updateActor(
      x: actor.x,
      y: actor.y,
      z: actor.z,
      frame: actor.frame,
      actorAngle: actor.actorAngle,
      light: actor.light,
      fullBright: actor.fullBright,
      fuzz: actor.fuzz,
    );
    if (frameChanged) {
      component.applySelection(selection);
    }
    return true;
  }

  /// Deactivates an actor but retains its surface and GPU buffer for reuse.
  void releaseActorSprite(ActorSpriteComponent component) {
    if (!_activeActorSprites.remove(component)) {
      return;
    }
    component.deactivate();
    _actorPool
        .putIfAbsent(component.spritePrefix, () => <ActorSpriteComponent>[])
        .add(component);
  }
}
