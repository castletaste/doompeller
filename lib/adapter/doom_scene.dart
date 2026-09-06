import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas;

import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;
import 'package:flame/game.dart' as flame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

import 'packed_surface.dart';
import 'palette_material.dart';
import 'palette_textures.dart';
import 'render_diagnostics.dart';
import 'doom_sprite_atlas.dart';
import 'doom_sprite_catalog.dart';
import 'vertex_abi.dart';

/// One packed, GPU-ready mesh handed to the adapter.
///
/// This mirrors doom_geometry's PackedMesh from docs/CONTRACTS.md without
/// importing it: the adapter must not depend on a package that is still being
/// written, and the pure-Dart side must not depend on flame_3d. The compiler
/// produces this shape; the adapter consumes it.
final class SceneMeshInput {
  SceneMeshInput({
    required this.vertices,
    required this.indices,
    required this.atlasPage,
    required this.kind,
    required this.bounds,
    this.debugLabel,
  }) {
    DoomVertexAbi.validateVertexBuffer(vertices);
    DoomVertexAbi.validateIndexBuffer(
      indices,
      DoomVertexAbi.vertexCountOf(vertices),
    );
    if (atlasPage.isEmpty) {
      throw ArgumentError.value(atlasPage, 'atlasPage', 'must not be empty');
    }
  }

  /// Interleaved vertices in the 20-float ABI. Retained without copying.
  final Float32List vertices;

  /// Triangle indices, uint16 because that is all flame_3d 0.3.0 binds.
  final Uint16List indices;

  /// Which atlas page this mesh samples. Meshes sharing a page and a kind are
  /// merged into one surface.
  final String atlasPage;

  /// What this mesh draws.
  final DoomSurfaceKind kind;

  /// Precomputed bounds, min then max as (x, y, z).
  final SceneBounds bounds;

  final String? debugLabel;

  int get vertexCount => DoomVertexAbi.vertexCountOf(vertices);
  int get triangleCount => indices.length ~/ 3;
}

/// Axis-aligned bounds as plain doubles.
///
/// Kept free of vector_math so the geometry compiler never has to share a
/// mutable [Vector3] with the renderer.
final class SceneBounds {
  const SceneBounds({
    required this.minX,
    required this.minY,
    required this.minZ,
    required this.maxX,
    required this.maxY,
    required this.maxZ,
  });

  /// Bounds spanning nothing, useful as a fold seed.
  static const SceneBounds empty = SceneBounds(
    minX: 0,
    minY: 0,
    minZ: 0,
    maxX: 0,
    maxY: 0,
    maxZ: 0,
  );

  final double minX;
  final double minY;
  final double minZ;
  final double maxX;
  final double maxY;
  final double maxZ;

  /// Smallest bounds containing both operands.
  SceneBounds union(SceneBounds other) => SceneBounds(
    minX: minX < other.minX ? minX : other.minX,
    minY: minY < other.minY ? minY : other.minY,
    minZ: minZ < other.minZ ? minZ : other.minZ,
    maxX: maxX > other.maxX ? maxX : other.maxX,
    maxY: maxY > other.maxY ? maxY : other.maxY,
    maxZ: maxZ > other.maxZ ? maxZ : other.maxZ,
  );

  /// Same bounds with a new vertical span, for a plane that moved.
  SceneBounds withHeights(double low, double high) => SceneBounds(
    minX: minX,
    minY: low < high ? low : high,
    minZ: minZ,
    maxX: maxX,
    maxY: low < high ? high : low,
    maxZ: maxZ,
  );

  Aabb3 toAabb3() =>
      Aabb3.minMax(Vector3(minX, minY, minZ), Vector3(maxX, maxY, maxZ));
}

/// A sector plane whose height changes at runtime.
///
/// Mirrors SectorPlaneRef from docs/CONTRACTS.md. [vertexIndices] address the
/// merged surface for the plane's atlas page, which is why the compiler emits
/// them rather than the adapter deriving them.
final class SectorPlaneRef {
  const SectorPlaneRef({
    required this.sectorIndex,
    required this.atlasPage,
    required this.vertexIndices,
    required this.bounds,
  });

  final int sectorIndex;
  final String atlasPage;
  final List<int> vertexIndices;
  final SceneBounds bounds;
}

/// A wall band whose height or texture anchor changes at runtime.
///
/// Mirrors WallBandRef from docs/CONTRACTS.md. A door's upper band moves its
/// top vertices and, when the sidedef is unpegged, re-anchors V at the same
/// time.
final class WallBandRef {
  const WallBandRef({
    required this.linedefIndex,
    required this.atlasPage,
    required this.topVertexIndices,
    required this.bottomVertexIndices,
    required this.bounds,
    this.unpegged = false,
    this.textureHeight = 128,
  });

  final int linedefIndex;
  final String atlasPage;

  /// Vertices that follow the band's upper edge.
  final List<int> topVertexIndices;

  /// Vertices that follow the band's lower edge.
  final List<int> bottomVertexIndices;

  final SceneBounds bounds;

  /// Whether the texture is pegged to the moving edge, which changes how V is
  /// recomputed as the band resizes.
  final bool unpegged;

  /// Source texture height in world units, used to convert a height delta into
  /// a V delta.
  final double textureHeight;
}

/// Everything the adapter needs to build a level's renderable scene.
///
/// Mirrors CompiledLevel from docs/CONTRACTS.md.
final class CompiledLevelInput {
  CompiledLevelInput({
    required this.meshes,
    required this.atlasPages,
    this.floorPlanes = const [],
    this.ceilingPlanes = const [],
    this.wallBands = const [],
  });

  final List<SceneMeshInput> meshes;

  /// Lookup textures per atlas page. Every mesh's page must be present.
  final Map<String, PaletteTextures> atlasPages;

  final List<SectorPlaneRef> floorPlanes;
  final List<SectorPlaneRef> ceilingPlanes;
  final List<WallBandRef> wallBands;
}

/// Builds and owns the Flame objects for one level.
///
/// ## Merging strategy
///
/// flame_3d 0.3.0 has no batching. Every visible object is inserted into a
/// draw list that is insertion-sorted back-to-front each frame, so the cost is
/// quadratic in visible object count. Meshes are therefore merged by (atlas
/// page, surface kind) into as few surfaces as uint16 indices allow, giving one
/// draw per page per kind instead of one per texture.
///
/// Merging stops at 65536 vertices per surface because that is the uint16
/// index ceiling; an oversized page simply continues into another surface.
///
/// ## Ordering
///
/// Sky is mounted first and the weapon last, matching the order Doom composites
/// them. Sky and weapon are camera-locked children, so they translate with the
/// view and can never be walked out of.
final class DoomScene {
  DoomScene._({
    required this.root,
    required this.diagnostics,
    required Map<String, List<PackedFlameSurface>> surfacesByPage,
    required List<SectorPlaneRef> floorPlanes,
    required List<SectorPlaneRef> ceilingPlanes,
    required List<WallBandRef> wallBands,
    required this.materials,
    this._compiledLevel,
    this._geometryBindings = const {},
    this._spriteAtlas,
    this._spriteMaterials = const {},
    List<int> sectorLights = const <int>[],
  }) : // These are exposed through narrower read-only accessors, so the
       // backing fields stay private.
       // ignore: prefer_initializing_formals
       _surfacesByPage = surfacesByPage,
       // ignore: prefer_initializing_formals
       _floorPlanes = floorPlanes,
       // ignore: prefer_initializing_formals
       _ceilingPlanes = ceilingPlanes,
       // ignore: prefer_initializing_formals
       _wallBands = wallBands,
       _sectorLights = List<int>.of(sectorLights);

  /// Assembles a scene from compiled level data.
  factory DoomScene.build(
    CompiledLevelInput level, {
    RenderDiagnostics? diagnostics,
    PaletteMaterialCache? materials,
  }) {
    final counters = diagnostics ?? RenderDiagnostics();
    final materialCache = materials ?? PaletteMaterialCache();
    materialCache.beginScene();
    final root = DoomSceneRoot();
    final surfacesByPage = <String, List<PackedFlameSurface>>{};

    // Group first so the merge sees every mesh for a page at once.
    final groups = <(String, DoomSurfaceKind), List<SceneMeshInput>>{};
    for (final mesh in level.meshes) {
      groups.putIfAbsent((mesh.atlasPage, mesh.kind), () => []).add(mesh);
    }

    // Sky first, weapon last; the rest in between.
    final orderedKeys = groups.keys.toList()
      ..sort((a, b) => _kindOrder(a.$2).compareTo(_kindOrder(b.$2)));

    for (final key in orderedKeys) {
      final (page, kind) = key;
      final textures = level.atlasPages[page];
      if (textures == null) {
        throw StateError('No atlas textures registered for page "$page"');
      }
      final material = materialCache.resolve(
        atlasKey: page,
        textures: textures,
        alphaCutout: _needsCutout(kind),
      );

      for (final batch in _mergeBatches(groups[key]!)) {
        final surface = PackedFlameSurface(
          vertices: batch.vertices,
          indices: batch.indices,
          bounds: batch.bounds.toAabb3(),
          material: material,
          kind: kind,
          diagnostics: counters,
          debugLabel: '$page/${kind.name}',
        );
        surfacesByPage.putIfAbsent(page, () => []).add(surface);

        final mesh = Mesh()..addSurface(surface);
        counters.onMeshBuilt();
        final component = _componentFor(kind, mesh);
        counters.onComponentBuilt();
        root.add(component);
      }
    }

    return DoomScene._(
      root: root,
      diagnostics: counters,
      surfacesByPage: surfacesByPage,
      floorPlanes: level.floorPlanes,
      ceilingPlanes: level.ceilingPlanes,
      wallBands: level.wallBands,
      materials: materialCache,
    );
  }

  /// Builds directly from the pure-Dart compiler's production objects.
  ///
  /// Geometry already batches by atlas page and kind. Each [PackedMesh] stays
  /// one [PackedFlameSurface], retaining the compiler's vertex buffer by
  /// identity so its mesh-indexed dynamic references remain exact.
  factory DoomScene.fromCompiledLevel(
    geometry.CompiledLevel level,
    wad.WadResources resources, {
    RenderDiagnostics? diagnostics,
    PaletteMaterialCache? materials,
    Set<String> spritePrefixes = const <String>{},
    Set<String> spriteNames = const <String>{},
    List<int> sectorLights = const <int>[],
    geometry.GeometryOptions spriteAtlasOptions =
        geometry.GeometryOptions.defaults,
  }) {
    final counters = diagnostics ?? RenderDiagnostics();
    final materialCache = materials ?? PaletteMaterialCache();
    materialCache.beginScene();
    final root = DoomSceneRoot();
    final surfacesByPage = <String, List<PackedFlameSurface>>{};
    final bindings = <int, _GeometryBinding>{};
    final pageTextures = <int, PaletteTextures>{};
    final spriteMaterials = <int, PaletteMaterial>{};

    for (final page in level.atlas.pages) {
      if (page.index < 0 || page.index >= level.atlas.pages.length) {
        throw StateError('Atlas page has invalid index ${page.index}');
      }
      pageTextures[page.index] = PaletteTextures(
        PaletteTextureData.fromDoomResources(page: page, resources: resources),
        diagnostics: counters,
      );
    }

    final spriteAtlas = spritePrefixes.isEmpty && spriteNames.isEmpty
        ? null
        : DoomSpriteAtlas.build(
            resources,
            requiredPrefixes: spritePrefixes,
            requiredNames: spriteNames,
            options: spriteAtlasOptions,
          );
    if (spriteAtlas != null) {
      for (final page in spriteAtlas.atlas.pages) {
        final textures = PaletteTextures(
          PaletteTextureData.fromDoomResources(
            page: page,
            resources: resources,
          ),
          diagnostics: counters,
        );
        spriteMaterials[page.index] = materialCache.resolve(
          atlasKey: 'sprite:${page.index}',
          textures: textures,
          alphaCutout: true,
        );
      }
    }

    for (var meshIndex = 0; meshIndex < level.meshes.length; meshIndex++) {
      final source = level.meshes[meshIndex];
      final textures = pageTextures[source.atlasPage];
      if (textures == null) {
        throw StateError(
          'PackedMesh $meshIndex references missing atlas page '
          '${source.atlasPage}',
        );
      }
      final kind = _fromGeometryKind(source.kind);
      final material = materialCache.resolve(
        atlasKey: 'geometry:${source.atlasPage}',
        textures: textures,
        alphaCutout: _needsCutout(kind),
      );
      final surface = PackedFlameSurface(
        vertices: source.vertices,
        indices: source.indices,
        bounds: _boundsOf(source.vertices),
        material: material,
        kind: kind,
        diagnostics: counters,
        debugLabel: 'mesh:$meshIndex/page:${source.atlasPage}/${kind.name}',
      );
      final flameMesh = Mesh()..addSurface(surface);
      final component = _componentFor(kind, flameMesh);
      counters
        ..onMeshBuilt()
        ..onComponentBuilt();
      root.add(component);
      bindings[meshIndex] = _GeometryBinding(
        surface: surface,
        mesh: flameMesh,
        component: component,
      );
      surfacesByPage
          .putIfAbsent('geometry:${source.atlasPage}', () => [])
          .add(surface);
    }

    final skyEntry = level.skyTextureEntry;
    if (skyEntry != null) {
      final textures = pageTextures[skyEntry.page];
      if (textures == null) {
        throw StateError('Sky references missing atlas page ${skyEntry.page}');
      }
      final material = materialCache.resolve(
        atlasKey: 'geometry:${skyEntry.page}',
        textures: textures,
        alphaCutout: false,
      );
      final surface = _buildSkySurface(
        entry: skyEntry,
        pageSize: level.atlas.pageSize,
        material: material,
        diagnostics: counters,
      );
      final skyMesh = Mesh()..addSurface(surface);
      root.add(SkyMeshComponent(mesh: skyMesh));
      counters
        ..onMeshBuilt()
        ..onComponentBuilt();
      surfacesByPage
          .putIfAbsent('geometry:${skyEntry.page}', () => [])
          .add(surface);
    }

    return DoomScene._(
      root: root,
      diagnostics: counters,
      surfacesByPage: surfacesByPage,
      floorPlanes: const [],
      ceilingPlanes: const [],
      wallBands: const [],
      materials: materialCache,
      compiledLevel: level,
      geometryBindings: bindings,
      spriteAtlas: spriteAtlas,
      spriteMaterials: spriteMaterials,
      sectorLights: sectorLights,
    );
  }

  /// Mount this under a World3D to render the level.
  final DoomSceneRoot root;

  final RenderDiagnostics diagnostics;

  /// Shared materials, also the entry point for palette flashes.
  final PaletteMaterialCache materials;

  final Map<String, List<PackedFlameSurface>> _surfacesByPage;
  final List<SectorPlaneRef> _floorPlanes;
  final List<SectorPlaneRef> _ceilingPlanes;
  final List<WallBandRef> _wallBands;
  final geometry.CompiledLevel? _compiledLevel;
  final Map<int, _GeometryBinding> _geometryBindings;
  final DoomSpriteAtlas? _spriteAtlas;
  final Map<int, PaletteMaterial> _spriteMaterials;
  final List<int> _sectorLights;
  final Set<ActorSpriteComponent> _activeActorSprites =
      <ActorSpriteComponent>{};
  final Map<String, List<ActorSpriteComponent>> _actorPool =
      <String, List<ActorSpriteComponent>>{};
  final Set<PackedFlameSurface> _inactiveActorSurfaces = <PackedFlameSurface>{};
  final Map<PackedFlameSurface, ActorSpriteComponent> _actorBySurface =
      <PackedFlameSurface, ActorSpriteComponent>{};

  /// Applies the authoritative camera pose to view-dependent scene objects.
  ///
  /// Flame exposes `currentCamera` only while traversing the render tree, not
  /// during component updates. Keeping this explicit lets the normal runtime
  /// update billboards, sky, and weapon immediately before rendering without
  /// relying on that transient static.
  void syncToCamera(CameraComponent3D camera) {
    for (final Component3D child in root.children.whereType<Component3D>()) {
      if (child is CameraLockedMeshComponent) {
        child.syncToCamera(camera);
      } else if (child is YawBillboardMeshComponent) {
        child.syncToCamera(camera);
      }
    }
  }

  /// Exact source mesh identity used by the compiler's dynamic references.
  PackedFlameSurface surfaceForMesh(int meshIndex) {
    final binding = _geometryBindings[meshIndex];
    if (binding == null) {
      throw RangeError.index(meshIndex, _geometryBindings, 'meshIndex');
    }
    return binding.surface;
  }

  /// Total surfaces, the number that drives per-frame draw cost.
  int get surfaceCount => surfaces.length;

  /// Every surface, in creation order.
  Iterable<PackedFlameSurface> get surfaces =>
      _surfacesByPage.values.expand((list) => list).where(_surfaceIsActive);

  bool _surfaceIsActive(PackedFlameSurface surface) =>
      !_inactiveActorSurfaces.contains(surface) &&
      (_actorBySurface[surface]?.active ?? true);

  /// Actor surfaces retained for reuse, active plus pooled.
  int get actorSurfaceRegistryCount =>
      _activeActorSprites.length +
      _actorPool.values.fold<int>(0, (sum, pool) => sum + pool.length);

  int get activeActorSurfaceCount =>
      _activeActorSprites.where((actor) => actor.active).length;

  int get pooledActorSurfaceCount =>
      _actorPool.values.fold<int>(0, (sum, pool) => sum + pool.length);

  bool isActorSpriteActive(ActorSpriteComponent actor) => actor.active;

  /// Surfaces drawing [page].
  List<PackedFlameSurface> surfacesForPage(String page) => List.unmodifiable(
    (_surfacesByPage[page] ?? const <PackedFlameSurface>[]).where(
      _surfaceIsActive,
    ),
  );

  /// Moves a floor or ceiling to [height].
  ///
  /// Writes in place and uploads only the touched vertex range, so a lift
  /// running every tic never recreates a GPU buffer. Returns whether anything
  /// moved.
  bool updateSectorPlane({
    required int sectorIndex,
    required double height,
    required bool isCeiling,
  }) {
    final compiled = _compiledLevel;
    if (compiled != null) {
      final planes = isCeiling ? compiled.ceilingPlanes : compiled.floorPlanes;
      geometry.SectorPlaneRef? target;
      for (final plane in planes) {
        if (plane.sector == sectorIndex) {
          target = plane;
          break;
        }
      }
      if (target == null || target.height == height) {
        return false;
      }
      if (!height.isFinite) {
        throw ArgumentError.value(height, 'height', 'must be finite');
      }
      if (isCeiling) {
        compiled.setCeilingHeight(sectorIndex, height);
      } else {
        compiled.setFloorHeight(sectorIndex, height);
      }
      for (final range in target.ranges) {
        final binding = _geometryBindings[range.meshIndex]!;
        binding.surface
          ..markVertexRangeDirty(range.firstVertex, range.vertexCount)
          ..expandBoundsY(height);
        binding.markBoundsDirty();
      }
      diagnostics.onDynamicUpdate();
      return true;
    }

    final planes = isCeiling ? _ceilingPlanes : _floorPlanes;
    var changed = false;
    for (final plane in planes) {
      if (plane.sectorIndex != sectorIndex) {
        continue;
      }
      for (final surface in _surfacesByPage[plane.atlasPage] ?? const []) {
        if (surface.kind != DoomSurfaceKind.opaque) {
          continue;
        }
        final moved = surface.setVertexHeights(
          plane.vertexIndices,
          height,
          bounds: _expandBounds(surface.aabb, height),
        );
        changed = changed || moved;
      }
    }
    return changed;
  }

  /// Advances classic texture/flat animations by rewriting atlas rectangles.
  /// Only ranges whose frame changed are dirtied; geometry and GPU buffers stay
  /// allocated. Frames are co-located on one page by the geometry compiler.
  int updateTextureAnimations(int levelTime) {
    final compiled = _compiledLevel;
    if (compiled == null) {
      throw StateError('updateTextureAnimations requires fromCompiledLevel');
    }
    final Set<(int, int, int)> planeRanges = <(int, int, int)>{};
    final List<geometry.SectorPlaneRef> planes = <geometry.SectorPlaneRef>[
      ...compiled.floorPlanes,
      ...compiled.ceilingPlanes,
    ];
    for (final plane in planes) {
      for (final range in plane.ranges) {
        planeRanges.add((
          range.meshIndex,
          range.firstVertex,
          range.vertexCount,
        ));
      }
    }

    var touched = 0;
    void updateRanges(
      Iterable<geometry.VertexRange> ranges,
      geometry.AtlasEntry entry,
    ) {
      for (final range in ranges) {
        final mesh = compiled.meshes[range.meshIndex];
        final int rectOffset =
            range.firstVertex * geometry.DoomVertexAbi.floatsPerVertex +
            geometry.DoomVertexAbi.atlasRectOffset;
        final current = mesh.vertices[rectOffset];
        final next = entry.u0(compiled.atlas.pageSize);
        if (current == next &&
            mesh.vertices[rectOffset + 1] ==
                entry.v0(compiled.atlas.pageSize) &&
            mesh.vertices[rectOffset + 2] ==
                entry.u1(compiled.atlas.pageSize) &&
            mesh.vertices[rectOffset + 3] ==
                entry.v1(compiled.atlas.pageSize)) {
          continue;
        }
        _writeAtlasRect(
          mesh.vertices,
          range.firstVertex,
          range.vertexCount,
          entry,
          compiled.atlas.pageSize,
        );
        _geometryBindings[range.meshIndex]!.surface.markVertexRangeDirty(
          range.firstVertex,
          range.vertexCount,
        );
        touched += range.vertexCount;
      }
    }

    // Plane texture names are mutable. Resolve their current animation base
    // each frame so transferring onto or away from an animated flat cannot
    // leave the old range binding alive.
    for (final plane in planes) {
      geometry.AnimatedSurfaceRef? selected;
      for (final animation in compiled.animations) {
        if (animation.frames[animation.initialFrame].name ==
            plane.textureName) {
          selected = animation;
          break;
        }
      }
      if (selected != null) {
        updateRanges(
          plane.ranges,
          selected.frames[selected.frameAt(levelTime)],
        );
      }
    }
    for (final animation in compiled.animations) {
      final entry = animation.frames[animation.frameAt(levelTime)];
      updateRanges(
        animation.ranges.where(
          (geometry.VertexRange range) => !planeRanges.contains((
            range.meshIndex,
            range.firstVertex,
            range.vertexCount,
          )),
        ),
        entry,
      );
    }
    for (final band in compiled.wallBands) {
      if (!band.applyHorizontalScroll(compiled.meshes, levelTime)) continue;
      _geometryBindings[band.meshIndex]!.surface.markVertexRangeDirty(
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
      );
      touched += geometry.WallBandRef.verticesPerQuad;
    }
    if (touched > 0) diagnostics.onDynamicUpdate();
    return touched;
  }

  int updateAnimationFrames(int levelTime) =>
      updateTextureAnimations(levelTime);

  int updateSectorFloorFlat({
    required int sectorIndex,
    required String flatName,
  }) {
    final compiled = _compiledLevel;
    if (compiled == null) {
      throw StateError('updateSectorFloorFlat requires fromCompiledLevel');
    }
    geometry.SectorPlaneRef? target;
    for (final plane in compiled.floorPlanes) {
      if (plane.sector == sectorIndex) {
        target = plane;
        break;
      }
    }
    if (target == null || target.textureName == flatName) return 0;
    final int touched = compiled.setFloorFlat(sectorIndex, flatName);
    for (final range in target.ranges) {
      _geometryBindings[range.meshIndex]!.surface.markVertexRangeDirty(
        range.firstVertex,
        range.vertexCount,
      );
    }
    if (touched > 0) diagnostics.onDynamicUpdate();
    return touched;
  }

  int updateSwitchTexture(core.SwitchTextureChange change) {
    final compiled = _compiledLevel;
    if (compiled == null) {
      throw StateError('updateSwitchTexture requires fromCompiledLevel');
    }
    final geometry.AtlasEntry? entry = compiled.atlas.entry(change.textureName);
    if (entry == null) return 0;
    var touched = 0;
    for (final band in compiled.wallBands) {
      if (band.linedef != change.linedef ||
          band.sidedef != change.sidedef ||
          !_slotMatches(change.slot, band.band)) {
        continue;
      }
      if (compiled.meshes[band.meshIndex].atlasPage != entry.page) continue;
      _writeAtlasRect(
        compiled.meshes[band.meshIndex].vertices,
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
        entry,
        compiled.atlas.pageSize,
      );
      _geometryBindings[band.meshIndex]!.surface.markVertexRangeDirty(
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
      );
      touched += geometry.WallBandRef.verticesPerQuad;
    }
    if (touched > 0) diagnostics.onDynamicUpdate();
    return touched;
  }

  /// Recomputes every wall quad touching [sectorIndex] through geometry's
  /// pegging oracle, then marks only each referenced four-vertex quad dirty.
  int updateWallsForSector({
    required int sectorIndex,
    required double floorHeight,
    required double ceilingHeight,
    required List<double> sectorFloors,
    required List<double> sectorCeilings,
  }) {
    final compiled = _compiledLevel;
    if (compiled == null) {
      throw StateError('updateWallsForSector requires fromCompiledLevel');
    }
    final affected = <geometry.WallBandRef>[
      for (final band in compiled.wallBands)
        if (band.frontSector == sectorIndex || band.backSector == sectorIndex)
          band,
    ];
    if (affected.isEmpty) {
      return 0;
    }
    final updated = compiled.updateWallsForSector(
      sectorIndex,
      floorHeight,
      ceilingHeight,
      sectorFloors,
      sectorCeilings,
    );
    for (final band in affected) {
      final binding = _geometryBindings[band.meshIndex]!;
      binding.surface
        ..markVertexRangeDirty(
          band.firstVertex,
          geometry.WallBandRef.verticesPerQuad,
        )
        ..expandBoundsY(band.bottom)
        ..expandBoundsY(band.top);
      binding.markBoundsDirty();
    }
    diagnostics.onDynamicUpdate();
    return updated;
  }

  /// Rewrites the exact retained plane and near-wall vertices lit by a sector.
  ///
  /// Fake-contrast offsets already present on walls are retained. Only dirty
  /// ranges are marked; no mesh, surface, or GPU buffer is recreated.
  int updateSectorLight({required int sectorIndex, required int lightLevel}) {
    final compiled = _compiledLevel;
    if (compiled == null) {
      throw StateError('updateSectorLight requires fromCompiledLevel');
    }
    if (sectorIndex < 0 || sectorIndex >= _sectorLights.length) {
      throw RangeError.index(sectorIndex, _sectorLights, 'sectorIndex');
    }
    if (lightLevel < 0 || lightLevel > 255) {
      throw RangeError.range(lightLevel, 0, 255, 'lightLevel');
    }
    final int previousLevel = _sectorLights[sectorIndex];
    if (previousLevel == lightLevel) {
      return 0;
    }
    _sectorLights[sectorIndex] = lightLevel;
    final double previous = previousLevel / 255.0;
    final double next = lightLevel / 255.0;
    var touched = 0;

    void updateRange(
      int meshIndex,
      int firstVertex,
      int vertexCount, {
      required bool preserveContrast,
    }) {
      final mesh = compiled.meshes[meshIndex];
      for (
        var vertex = firstVertex;
        vertex < firstVertex + vertexCount;
        vertex++
      ) {
        final offset =
            vertex * geometry.DoomVertexAbi.floatsPerVertex +
            geometry.DoomVertexAbi.colorOffset;
        final double value = preserveContrast
            ? (mesh.vertices[offset] - previous + next).clamp(0.0, 1.0)
            : next;
        mesh.setVertexLight(vertex, value);
      }
      _geometryBindings[meshIndex]!.surface.markVertexRangeDirty(
        firstVertex,
        vertexCount,
      );
      touched += vertexCount;
    }

    for (final plane in compiled.floorPlanes) {
      if (plane.sector != sectorIndex) {
        continue;
      }
      for (final range in plane.ranges) {
        updateRange(
          range.meshIndex,
          range.firstVertex,
          range.vertexCount,
          preserveContrast: false,
        );
      }
    }
    for (final plane in compiled.ceilingPlanes) {
      if (plane.sector != sectorIndex) {
        continue;
      }
      for (final range in plane.ranges) {
        updateRange(
          range.meshIndex,
          range.firstVertex,
          range.vertexCount,
          preserveContrast: false,
        );
      }
    }
    for (final band in compiled.wallBands) {
      if (band.frontSector != sectorIndex) {
        continue;
      }
      updateRange(
        band.meshIndex,
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
        preserveContrast: true,
      );
    }
    if (touched > 0) {
      diagnostics.onDynamicUpdate();
    }
    return touched;
  }

  /// Restores every runtime-mutated world surface to the source map state.
  ///
  /// This rewrites retained vertex buffers in place. It does not rebuild a
  /// mesh, material, texture, surface, component, or GPU buffer.
  void resetDynamicState(wad.MapData map) {
    final compiled = _compiledLevel;
    if (compiled == null) {
      throw StateError('resetDynamicState requires fromCompiledLevel');
    }
    if (map.sectors.length != _sectorLights.length) {
      throw StateError('prepared map and retained scene sector counts differ');
    }

    final floors = <double>[
      for (final sector in map.sectors) sector.floorHeight.toDouble(),
    ];
    final ceilings = <double>[
      for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
    ];
    for (var sector = 0; sector < map.sectors.length; sector++) {
      updateSectorPlane(
        sectorIndex: sector,
        height: floors[sector],
        isCeiling: false,
      );
      updateSectorPlane(
        sectorIndex: sector,
        height: ceilings[sector],
        isCeiling: true,
      );
      updateSectorFloorFlat(
        sectorIndex: sector,
        flatName: map.sectors[sector].floorFlat,
      );
      updateSectorLight(
        sectorIndex: sector,
        lightLevel: map.sectors[sector].lightLevel,
      );
    }
    for (var sector = 0; sector < map.sectors.length; sector++) {
      updateWallsForSector(
        sectorIndex: sector,
        floorHeight: floors[sector],
        ceilingHeight: ceilings[sector],
        sectorFloors: floors,
        sectorCeilings: ceilings,
      );
    }

    for (final band in compiled.wallBands) {
      final geometry.AtlasEntry? entry = compiled.atlas.entry(band.textureName);
      if (entry == null ||
          compiled.meshes[band.meshIndex].atlasPage != entry.page) {
        continue;
      }
      _writeAtlasRect(
        compiled.meshes[band.meshIndex].vertices,
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
        entry,
        compiled.atlas.pageSize,
      );
      _geometryBindings[band.meshIndex]!.surface.markVertexRangeDirty(
        band.firstVertex,
        geometry.WallBandRef.verticesPerQuad,
      );
    }
    updateTextureAnimations(0);
  }

  /// Adds one upright actor billboard from the bounded supplemental atlas.
  ActorSpriteComponent addActorSprite(ActorSpriteInstance actor) {
    final component = acquireActorSprite(actor);
    if (component == null) {
      throw StateError(
        'No sprite for ${actor.spritePrefix} frame ${actor.frame}',
      );
    }
    return component;
  }

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
        _inactiveActorSurfaces.remove(candidate.surface);
        return candidate;
      }
    }
    final entry = spriteAtlas.atlas.entry(selection.lumpName)!;
    final material = _spriteMaterials[entry.page]!;
    final quad = _actorSpriteQuad(
      entry,
      width: actor.width,
      height: actor.height,
    );
    final vertices = _spriteQuad(
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
    root.add(component);
    _activeActorSprites.add(component);
    _actorBySurface[surface] = component;
    _surfacesByPage.putIfAbsent('sprite:${entry.page}', () => []).add(surface);
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
    _inactiveActorSurfaces.add(component.surface);
    _actorPool
        .putIfAbsent(component.spritePrefix, () => <ActorSpriteComponent>[])
        .add(component);
  }

  /// Adds a camera-view-locked first-person weapon frame.
  ViewLockedWeaponSpriteComponent addWeaponSprite(WeaponSpriteInstance weapon) {
    final spriteAtlas = _spriteAtlas;
    if (spriteAtlas == null) {
      throw StateError(
        'No supplemental sprite atlas was requested for this scene',
      );
    }
    final selection = spriteAtlas.catalog.exact(weapon.lumpName);
    if (selection == null) {
      throw StateError('Weapon sprite ${weapon.lumpName} is not packed');
    }
    final entry = spriteAtlas.atlas.entry(selection.lumpName)!;
    final quad = _weaponSpriteQuad(
      entry,
      viewAnchorX: weapon.viewAnchorX,
      viewAnchorY: weapon.viewAnchorY,
      pixelScaleX: weapon.pixelScaleX,
      pixelScaleY: weapon.pixelScaleY,
    );
    final vertices = _spriteQuad(
      quad: quad,
      entry: entry,
      pageSize: spriteAtlas.atlas.pageSize,
      light: 1,
      fullBright: weapon.fullBright,
      depthLayer: weapon.depthLayer,
    );
    final surface = PackedFlameSurface(
      vertices: vertices,
      indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
      bounds: quad.bounds,
      material: _spriteMaterials[entry.page]!,
      kind: DoomSurfaceKind.weapon,
      diagnostics: diagnostics,
      debugLabel: 'weapon:${weapon.lumpName}',
    );
    final mesh = Mesh()..addSurface(surface);
    final component = ViewLockedWeaponSpriteComponent(
      mesh: mesh,
      surface: surface,
      spriteAtlas: spriteAtlas,
      materialsByPage: _spriteMaterials,
      lumpName: selection.lumpName,
      viewAnchorX: weapon.viewAnchorX,
      viewAnchorY: weapon.viewAnchorY,
      pixelScaleX: weapon.pixelScaleX,
      pixelScaleY: weapon.pixelScaleY,
    );
    root.add(component);
    _surfacesByPage.putIfAbsent('sprite:${entry.page}', () => []).add(surface);
    diagnostics
      ..onMeshBuilt()
      ..onComponentBuilt();
    return component;
  }

  /// Resizes a wall band, as a door or lift does.
  ///
  /// When the band's sidedef is unpegged, the texture stays anchored to the
  /// moving edge, so V is re-derived from the new height instead of stretching
  /// with the geometry. Returns whether anything moved.
  bool updateWallBand({
    required int linedefIndex,
    required double topHeight,
    required double bottomHeight,
  }) {
    if (!topHeight.isFinite || !bottomHeight.isFinite) {
      throw ArgumentError('Wall band heights must be finite');
    }
    var changed = false;
    for (final band in _wallBands) {
      if (band.linedefIndex != linedefIndex) {
        continue;
      }
      final bounds = band.bounds.withHeights(bottomHeight, topHeight).toAabb3();
      for (final surface in _surfacesByPage[band.atlasPage] ?? const []) {
        var surfaceChanged = false;
        surface.updateVertices((vertices) {
          surfaceChanged = _writeBand(
            vertices,
            surface,
            band,
            topHeight,
            bottomHeight,
          );
        }, bounds: bounds);
        changed = changed || surfaceChanged;
      }
    }
    return changed;
  }

  /// Sets the PLAYPAL row on every material, which is how screen flashes work.
  void setPaletteIndex(int paletteIndex) =>
      materials.setPaletteIndex(paletteIndex);

  /// Uploads all pending dynamic writes immediately.
  ///
  /// Normally unnecessary: a surface flushes itself when the renderer reads its
  /// buffer. Useful for tests and for measuring upload cost off the draw path.
  int flushPendingUploads() {
    var flushed = 0;
    for (final surface in surfaces) {
      if (surface.flushPendingUpload()) {
        flushed++;
      }
    }
    return flushed;
  }

  static bool _writeBand(
    Float32List vertices,
    PackedFlameSurface surface,
    WallBandRef band,
    double topHeight,
    double bottomHeight,
  ) {
    var changed = false;

    for (final vertexIndex in band.topVertexIndices) {
      if (DoomVertexAbi.getY(vertices, vertexIndex) == topHeight) {
        continue;
      }
      DoomVertexAbi.setY(vertices, vertexIndex, topHeight);
      surface.markVertexDirty(vertexIndex);
      changed = true;
    }
    for (final vertexIndex in band.bottomVertexIndices) {
      if (DoomVertexAbi.getY(vertices, vertexIndex) == bottomHeight) {
        continue;
      }
      DoomVertexAbi.setY(vertices, vertexIndex, bottomHeight);
      surface.markVertexDirty(vertexIndex);
      changed = true;
    }

    if (!changed || !band.unpegged || band.textureHeight <= 0) {
      return changed;
    }

    // Unpegged bands keep the texture fixed to the top edge, so the visible
    // span is measured downward from it. Pegged bands need no V change: their
    // texture simply stretches with the geometry.
    final span = (topHeight - bottomHeight).abs() / band.textureHeight;
    for (final vertexIndex in band.topVertexIndices) {
      DoomVertexAbi.setV(vertices, vertexIndex, 0);
      surface.markVertexDirty(vertexIndex);
    }
    for (final vertexIndex in band.bottomVertexIndices) {
      DoomVertexAbi.setV(vertices, vertexIndex, span);
      surface.markVertexDirty(vertexIndex);
    }
    return true;
  }

  static Aabb3 _expandBounds(Aabb3 current, double height) {
    final min = current.min;
    final max = current.max;
    final low = height < min.y ? height : min.y;
    final high = height > max.y ? height : max.y;
    return Aabb3.minMax(
      Vector3(min.x, low, min.z),
      Vector3(max.x, high, max.z),
    );
  }

  static bool _needsCutout(DoomSurfaceKind kind) => switch (kind) {
    DoomSurfaceKind.masked ||
    DoomSurfaceKind.sprite ||
    DoomSurfaceKind.weapon => true,
    DoomSurfaceKind.opaque || DoomSurfaceKind.sky => false,
  };

  static int _kindOrder(DoomSurfaceKind kind) => switch (kind) {
    DoomSurfaceKind.sky => 0,
    DoomSurfaceKind.opaque => 1,
    DoomSurfaceKind.masked => 2,
    DoomSurfaceKind.sprite => 3,
    DoomSurfaceKind.weapon => 4,
  };

  static Component3D _componentFor(DoomSurfaceKind kind, Mesh mesh) =>
      switch (kind) {
        DoomSurfaceKind.sky => SkyMeshComponent(mesh: mesh),
        DoomSurfaceKind.weapon => ViewLockedWeaponComponent(mesh: mesh),
        DoomSurfaceKind.sprite => YawBillboardMeshComponent(mesh: mesh),
        _ => MeshComponent(mesh: mesh),
      };

  /// Splits meshes into surfaces that respect the uint16 vertex ceiling.
  static List<_MergedBatch> _mergeBatches(List<SceneMeshInput> meshes) {
    final batches = <_MergedBatch>[];
    var pending = <SceneMeshInput>[];
    var pendingVertices = 0;

    void flush() {
      if (pending.isEmpty) {
        return;
      }
      batches.add(_MergedBatch.of(pending));
      pending = <SceneMeshInput>[];
      pendingVertices = 0;
    }

    for (final mesh in meshes) {
      if (pendingVertices + mesh.vertexCount >
          DoomVertexAbi.maxVerticesPerSurface) {
        flush();
      }
      pending.add(mesh);
      pendingVertices += mesh.vertexCount;
    }
    flush();
    return batches;
  }
}

/// One merged vertex and index buffer, plus its bounds.
final class _MergedBatch {
  _MergedBatch({
    required this.vertices,
    required this.indices,
    required this.bounds,
  });

  /// Concatenates meshes, rebasing each one's indices.
  ///
  /// A single-mesh batch reuses the caller's buffers untouched, so the common
  /// case copies nothing at all.
  factory _MergedBatch.of(List<SceneMeshInput> meshes) {
    if (meshes.length == 1) {
      final only = meshes.single;
      return _MergedBatch(
        vertices: only.vertices,
        indices: only.indices,
        bounds: only.bounds,
      );
    }

    var totalFloats = 0;
    var totalIndices = 0;
    for (final mesh in meshes) {
      totalFloats += mesh.vertices.length;
      totalIndices += mesh.indices.length;
    }

    final vertices = Float32List(totalFloats);
    final indices = Uint16List(totalIndices);
    var floatCursor = 0;
    var indexCursor = 0;
    var vertexBase = 0;
    var bounds = meshes.first.bounds;

    for (final mesh in meshes) {
      vertices.setRange(
        floatCursor,
        floatCursor + mesh.vertices.length,
        mesh.vertices,
      );
      for (var i = 0; i < mesh.indices.length; i++) {
        indices[indexCursor + i] = mesh.indices[i] + vertexBase;
      }
      floatCursor += mesh.vertices.length;
      indexCursor += mesh.indices.length;
      vertexBase += mesh.vertexCount;
      bounds = bounds.union(mesh.bounds);
    }

    return _MergedBatch(vertices: vertices, indices: indices, bounds: bounds);
  }

  final Float32List vertices;
  final Uint16List indices;
  final SceneBounds bounds;
}

DoomSurfaceKind _fromGeometryKind(geometry.SurfaceKind kind) => switch (kind) {
  geometry.SurfaceKind.opaque => DoomSurfaceKind.opaque,
  geometry.SurfaceKind.masked => DoomSurfaceKind.masked,
  geometry.SurfaceKind.sky => DoomSurfaceKind.sky,
};

Aabb3 _boundsOf(Float32List vertices) {
  var minX = double.infinity;
  var minY = double.infinity;
  var minZ = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  var maxZ = double.negativeInfinity;
  final count = DoomVertexAbi.vertexCountOf(vertices);
  for (var vertex = 0; vertex < count; vertex++) {
    final offset = DoomVertexAbi.floatOffsetOf(vertex);
    final x = vertices[offset];
    final y = vertices[offset + 1];
    final z = vertices[offset + 2];
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    minZ = math.min(minZ, z);
    maxX = math.max(maxX, x);
    maxY = math.max(maxY, y);
    maxZ = math.max(maxZ, z);
  }
  return Aabb3.minMax(Vector3(minX, minY, minZ), Vector3(maxX, maxY, maxZ));
}

Float32List _spriteQuad({
  required _SpriteQuad quad,
  required geometry.AtlasEntry entry,
  required int pageSize,
  required double light,
  required bool fullBright,
  double alpha = 1,
  double depthLayer = 0,
}) {
  final vertices = DoomVertexAbi.allocate(4);
  final u0 = entry.u0(pageSize);
  final v0 = entry.v0(pageSize);
  final u1 = entry.u1(pageSize);
  final v1 = entry.v1(pageSize);
  void write(int index, double x, double y, double u, double v) {
    DoomVertexAbi.writeVertex(
      vertices,
      index,
      x: x,
      y: y,
      z: 0,
      u: u,
      v: v,
      nz: 1,
      light: light,
      alpha: alpha,
      atlasLeft: u0,
      atlasTop: v0,
      atlasRight: u1,
      atlasBottom: v1,
      uvMode: DoomVertexAbi.uvModeClamp,
      fullBright: fullBright,
      depthLayer: depthLayer,
    );
  }

  write(0, quad.left, quad.bottom, 0, 1);
  write(1, quad.right, quad.bottom, 1, 1);
  write(2, quad.right, quad.top, 1, 0);
  write(3, quad.left, quad.top, 0, 0);
  return vertices;
}

void _setSpriteSelection(
  PackedFlameSurface surface,
  geometry.AtlasEntry entry,
  int pageSize, {
  required bool mirrored,
  _SpriteQuad? quad,
}) {
  final u0 = entry.u0(pageSize);
  final v0 = entry.v0(pageSize);
  final u1 = entry.u1(pageSize);
  final v1 = entry.v1(pageSize);
  surface.updateVertices((vertices) {
    if (quad != null) {
      _writeSpriteQuadPositions(vertices, quad);
    }
    for (var vertex = 0; vertex < 4; vertex++) {
      final offset = DoomVertexAbi.floatOffsetOf(vertex);
      vertices[offset + DoomVertexAbi.atlasRectOffset] = u0;
      vertices[offset + DoomVertexAbi.atlasRectOffset + 1] = v0;
      vertices[offset + DoomVertexAbi.atlasRectOffset + 2] = u1;
      vertices[offset + DoomVertexAbi.atlasRectOffset + 3] = v1;
    }
    final leftU = mirrored ? 1.0 : 0.0;
    final rightU = mirrored ? 0.0 : 1.0;
    vertices[DoomVertexAbi.texCoordOffset] = leftU;
    vertices[DoomVertexAbi.floatOffsetOf(1) + DoomVertexAbi.texCoordOffset] =
        rightU;
    vertices[DoomVertexAbi.floatOffsetOf(2) + DoomVertexAbi.texCoordOffset] =
        rightU;
    vertices[DoomVertexAbi.floatOffsetOf(3) + DoomVertexAbi.texCoordOffset] =
        leftU;
    surface.markVertexRangeDirty(0, 4);
  });
}

void _writeSpriteQuadPositions(Float32List vertices, _SpriteQuad quad) {
  final points = <(double, double)>[
    (quad.left, quad.bottom),
    (quad.right, quad.bottom),
    (quad.right, quad.top),
    (quad.left, quad.top),
  ];
  for (var vertex = 0; vertex < 4; vertex++) {
    final offset = DoomVertexAbi.floatOffsetOf(vertex);
    vertices[offset] = points[vertex].$1;
    vertices[offset + 1] = points[vertex].$2;
  }
}

_SpriteQuad _actorSpriteQuad(
  geometry.AtlasEntry entry, {
  double? width,
  double? height,
}) {
  final scaleX = width == null ? 1.0 : width / entry.width;
  final scaleY = height == null ? 1.0 : height / entry.height;
  return _SpriteQuad(
    left: -entry.leftOffset * scaleX,
    right: (entry.width - entry.leftOffset) * scaleX,
    bottom: (entry.topOffset - entry.height) * scaleY,
    top: entry.topOffset * scaleY,
  );
}

_SpriteQuad _weaponSpriteQuad(
  geometry.AtlasEntry entry, {
  required double viewAnchorX,
  required double viewAnchorY,
  required double pixelScaleX,
  required double pixelScaleY,
}) => _SpriteQuad(
  left: viewAnchorX - entry.leftOffset * pixelScaleX,
  right: viewAnchorX + (entry.width - entry.leftOffset) * pixelScaleX,
  bottom: viewAnchorY + (entry.topOffset - entry.height) * pixelScaleY,
  top: viewAnchorY + entry.topOffset * pixelScaleY,
);

final class _SpriteQuad {
  const _SpriteQuad({
    required this.left,
    required this.right,
    required this.bottom,
    required this.top,
  });

  final double left;
  final double right;
  final double bottom;
  final double top;

  Aabb3 get bounds =>
      Aabb3.minMax(Vector3(left, bottom, 0), Vector3(right, top, 0));
}

PackedFlameSurface _buildSkySurface({
  required geometry.AtlasEntry entry,
  required int pageSize,
  required Material material,
  required RenderDiagnostics diagnostics,
}) {
  const extent = 500.0;
  final vertices = DoomVertexAbi.allocate(24);
  final indices = Uint16List(36);
  final u0 = entry.u0(pageSize);
  final v0 = entry.v0(pageSize);
  final u1 = entry.u1(pageSize);
  final v1 = entry.v1(pageSize);
  var vertexCursor = 0;
  var indexCursor = 0;

  void face(
    List<(double, double, double)> corners,
    (double, double, double) normal,
    double localU0,
    double localU1,
  ) {
    final localUvs = <(double, double)>[
      (localU0, 1),
      (localU1, 1),
      (localU1, 0),
      (localU0, 0),
    ];
    for (var i = 0; i < 4; i++) {
      final point = corners[i];
      final uv = localUvs[i];
      DoomVertexAbi.writeVertex(
        vertices,
        vertexCursor + i,
        x: point.$1,
        y: point.$2,
        z: point.$3,
        u: uv.$1,
        v: uv.$2,
        nx: normal.$1,
        ny: normal.$2,
        nz: normal.$3,
        atlasLeft: u0,
        atlasTop: v0,
        atlasRight: u1,
        atlasBottom: v1,
        // The four vertical faces consume one continuous panorama. Clamp is
        // essential: repeat would turn U=1 into U=0 and add another seam.
        // Top/bottom use the stable full-width mapping documented below.
        uvMode: DoomVertexAbi.uvModeClamp,
        fullBright: true,
        depthLayer: 1,
      );
    }
    indices.setRange(indexCursor, indexCursor + 6, <int>[
      vertexCursor,
      vertexCursor + 1,
      vertexCursor + 2,
      vertexCursor,
      vertexCursor + 2,
      vertexCursor + 3,
    ]);
    vertexCursor += 4;
    indexCursor += 6;
  }

  face(
    const [
      (-extent, -extent, -extent),
      (extent, -extent, -extent),
      (extent, extent, -extent),
      (-extent, extent, -extent),
    ],
    (0, 0, 1),
    0,
    0.25,
  );
  face(
    const [
      (extent, -extent, extent),
      (-extent, -extent, extent),
      (-extent, extent, extent),
      (extent, extent, extent),
    ],
    (0, 0, -1),
    0.5,
    0.75,
  );
  face(
    const [
      (-extent, -extent, extent),
      (-extent, -extent, -extent),
      (-extent, extent, -extent),
      (-extent, extent, extent),
    ],
    (1, 0, 0),
    0.75,
    1,
  );
  face(
    const [
      (extent, -extent, -extent),
      (extent, -extent, extent),
      (extent, extent, extent),
      (extent, extent, -extent),
    ],
    (-1, 0, 0),
    0.25,
    0.5,
  );
  face(
    const [
      (-extent, extent, -extent),
      (extent, extent, -extent),
      (extent, extent, extent),
      (-extent, extent, extent),
    ],
    (0, -1, 0),
    0,
    1,
  );
  face(
    const [
      (-extent, -extent, extent),
      (extent, -extent, extent),
      (extent, -extent, -extent),
      (-extent, -extent, -extent),
    ],
    (0, 1, 0),
    0,
    1,
  );

  return PackedFlameSurface(
    vertices: vertices,
    indices: indices,
    bounds: Aabb3.minMax(Vector3.all(-extent), Vector3.all(extent)),
    material: material,
    kind: DoomSurfaceKind.sky,
    diagnostics: diagnostics,
    debugLabel: 'sky:${entry.name}',
  );
}

/// A mesh that translates with the camera but does not rotate with it.
///
/// The sky and the weapon both need this: the sky must stay infinitely far
/// away, and the weapon must stay glued to the view. Following the camera's
/// position while keeping world orientation gives the sky its parallax-free
/// look without a separate render pass, which matters because flame_3d applies
/// blend and depth state per pass, not per object.
class CameraLockedMeshComponent extends MeshComponent {
  CameraLockedMeshComponent({required super.mesh});

  void syncToCamera(CameraComponent3D camera) {
    position.setFrom(camera.position);
  }

  /// Always drawn: a camera-locked mesh surrounds the view, so frustum culling
  /// it is both wrong and wasted work.
  @override
  bool isVisible(CameraComponent3D camera) => true;
}

/// Camera-centred sky with world-fixed orientation.
///
/// Only translation follows the camera, so yaw and pitch move the view across
/// the texture. The cube is emitted far behind world geometry and uses normal
/// depth testing, so it fills clear pixels without overwriting nearer world
/// fragments.
final class SkyMeshComponent extends CameraLockedMeshComponent {
  SkyMeshComponent({required super.mesh});
}

/// Weapon geometry locked to the camera's actual look basis.
///
/// CameraComponent3D renders from position/target/up; its `rotation` field is
/// not authoritative. Deriving the quaternion from forward/right/up keeps the
/// weapon stable through yaw and pitch even when `target` changes directly.
class ViewLockedWeaponComponent extends CameraLockedMeshComponent {
  ViewLockedWeaponComponent({required super.mesh, this.weaponDistance = 2});

  final double weaponDistance;

  @override
  void syncToCamera(CameraComponent3D camera) {
    final forward = camera.forward.normalized();
    final right = forward.cross(camera.up)..normalize();
    final up = right.cross(forward)..normalize();
    final verticalScale =
        2 * weaponDistance * math.tan(camera.fovY * math.pi / 360);
    final aspectRatio = _cameraAspectRatio(camera);
    position.setFrom(camera.position + forward * weaponDistance);
    // Weapon vertices are normalized 320x200 psprite coordinates: one local
    // unit spans the full viewport on either axis. Place the physical quad
    // beyond DoomCamera's near plane for Flame's pre-render AABB cull, then
    // scale it to the view plane so its projected size remains unchanged.
    scale.setValues(verticalScale * aspectRatio, verticalScale, verticalScale);
    rotation.setFrom(
      Quaternion.fromRotation(Matrix3.columns(right, up, -forward))
        ..normalize(),
    );
  }
}

double _cameraAspectRatio(CameraComponent3D camera) {
  // The runtime performs an initial camera sync in its constructor, before
  // Flame has received its first layout. MaxViewport tries to read the parent
  // game's canvas size in that state, which is not available yet.
  final parent = camera.parent;
  if (parent is flame.FlameGame && !parent.hasLayout) {
    return 4 / 3;
  }
  final size = camera.viewport.virtualSize;
  if (!size.x.isFinite || !size.y.isFinite || size.x <= 0 || size.y <= 0) {
    return 4 / 3;
  }
  return size.x / size.y;
}

/// Upright actor sprite that rotates only around world Y.
class YawBillboardMeshComponent extends MeshComponent {
  YawBillboardMeshComponent({required super.mesh, super.position});

  void syncToCamera(CameraComponent3D camera) {
    final dx = camera.position.x - position.x;
    final dz = camera.position.z - position.z;
    if (dx == 0 && dz == 0) {
      return;
    }
    rotation.setFrom(
      Quaternion.axisAngle(Vector3(0, 1, 0), math.atan2(dx, dz)),
    );
  }
}

/// Actor billboard that also selects classic view rotations in-place.
final class ActorSpriteComponent extends YawBillboardMeshComponent {
  ActorSpriteComponent({
    required super.mesh,
    required super.position,
    required this.surface,
    required this.spriteAtlas,
    required this.materialsByPage,
    required this.spritePrefix,
    required this.frame,
    required this.actorAngle,
    required this.width,
    required this.height,
    required this.light,
    required this.fullBright,
    required this.fuzz,
    required this._lumpName,
    required this._mirrored,
  });

  final PackedFlameSurface surface;
  final DoomSpriteAtlas spriteAtlas;
  final Map<int, PaletteMaterial> materialsByPage;
  final String spritePrefix;
  double actorAngle;
  int frame;
  final double? width;
  final double? height;
  double light;
  bool fullBright;
  bool fuzz;

  String _lumpName;
  bool _mirrored;
  bool _active = true;

  String get lumpName => _lumpName;
  bool get mirrored => _mirrored;
  bool get active => _active;

  void deactivate() => _active = false;

  void reactivate(ActorSpriteInstance actor, DoomSpriteSelection selection) {
    _active = true;
    updateActor(
      x: actor.x,
      y: actor.y,
      z: actor.z,
      frame: actor.frame,
      actorAngle: actor.actorAngle,
      light: actor.light,
      fullBright: actor.fullBright,
      fuzz: actor.fuzz,
    );
    applySelection(selection);
  }

  /// Updates the stable retained actor component for a new simulation view.
  void updateActor({
    required double x,
    required double y,
    required double z,
    required int frame,
    required double actorAngle,
    required double light,
    required bool fullBright,
    bool fuzz = false,
  }) {
    position.setValues(x, y, z);
    this.frame = frame;
    this.actorAngle = actorAngle;
    if (this.light == light &&
        this.fullBright == fullBright &&
        this.fuzz == fuzz) {
      return;
    }
    this.light = light;
    this.fullBright = fullBright;
    this.fuzz = fuzz;
    surface.updateVertices((vertices) {
      for (var vertex = 0; vertex < 4; vertex++) {
        final offset = DoomVertexAbi.floatOffsetOf(vertex);
        vertices[offset + DoomVertexAbi.lightOffset] = light;
        vertices[offset + DoomVertexAbi.alphaOffset] = fuzz ? 0.5 : 1;
        vertices[offset + DoomVertexAbi.paramsOffset] = fullBright ? 1 : 0;
      }
      surface.markVertexRangeDirty(0, 4);
    });
  }

  void applySelection(DoomSpriteSelection selection) {
    if (selection.lumpName == _lumpName && selection.mirrored == _mirrored) {
      return;
    }
    final entry = spriteAtlas.atlas.entry(selection.lumpName)!;
    final quad = _actorSpriteQuad(entry, width: width, height: height);
    surface.material = materialsByPage[entry.page]!;
    _setSpriteSelection(
      surface,
      entry,
      spriteAtlas.atlas.pageSize,
      mirrored: selection.mirrored,
      quad: quad,
    );
    surface.setBounds(quad.bounds);
    mesh.updateBounds();
    markAabbDirty();
    _lumpName = selection.lumpName;
    _mirrored = selection.mirrored;
  }

  @override
  void update(double dt) {
    if (!_active) {
      return;
    }
    super.update(dt);
  }

  @override
  void renderTree(Canvas canvas) {
    // flame_3d 0.3.0 bypasses isVisible() when an AABB is fully inside the
    // frustum. Retained pooled actors therefore need a gate before Object3D's
    // culling fast path or their last PUFF/BEXP frame remains in the draw list.
    if (!_active) {
      return;
    }
    super.renderTree(canvas);
  }

  @override
  bool isVisible(CameraComponent3D camera) =>
      _active && super.isVisible(camera);

  @override
  void syncToCamera(CameraComponent3D camera) {
    if (!_active) {
      return;
    }
    super.syncToCamera(camera);
    final rotation = DoomSpriteCatalog.cameraRotation(
      actorAngle: actorAngle,
      actorX: position.x,
      actorZ: position.z,
      cameraX: camera.position.x,
      cameraZ: camera.position.z,
    );
    final selection = spriteAtlas.catalog.resolve(
      prefix: spritePrefix,
      frame: frame,
      rotation: rotation,
    );
    if (selection == null) {
      _active = false;
      return;
    }
    applySelection(selection);
  }
}

/// View-locked weapon quad whose exact WAD frame can change in-place.
final class ViewLockedWeaponSpriteComponent extends ViewLockedWeaponComponent {
  ViewLockedWeaponSpriteComponent({
    required super.mesh,
    required this.surface,
    required this.spriteAtlas,
    required this.materialsByPage,
    required this._lumpName,
    required this.viewAnchorX,
    required this.viewAnchorY,
    required this.pixelScaleX,
    required this.pixelScaleY,
  });

  final PackedFlameSurface surface;
  final DoomSpriteAtlas spriteAtlas;
  final Map<int, PaletteMaterial> materialsByPage;
  String _lumpName;
  double viewAnchorX;
  double viewAnchorY;
  final double pixelScaleX;
  final double pixelScaleY;
  bool _visible = true;

  String get lumpName => _lumpName;
  bool get visible => _visible;

  void setVisible(bool value) => _visible = value;

  @override
  void renderTree(Canvas canvas) {
    // See ActorSpriteComponent.renderTree: isVisible() is not a reliable
    // dynamic visibility gate in the pinned flame_3d release.
    if (!_visible) {
      return;
    }
    super.renderTree(canvas);
  }

  @override
  bool isVisible(CameraComponent3D camera) =>
      _visible && super.isVisible(camera);

  bool setFrame(String lumpName, {double? viewAnchorX, double? viewAnchorY}) {
    final selection = spriteAtlas.catalog.exact(lumpName);
    if (selection == null) {
      throw StateError('Weapon sprite $lumpName is not packed');
    }
    final double nextX = viewAnchorX ?? this.viewAnchorX;
    final double nextY = viewAnchorY ?? this.viewAnchorY;
    if (selection.lumpName == _lumpName &&
        nextX == this.viewAnchorX &&
        nextY == this.viewAnchorY) {
      return false;
    }
    final entry = spriteAtlas.atlas.entry(selection.lumpName)!;
    final quad = _weaponSpriteQuad(
      entry,
      viewAnchorX: nextX,
      viewAnchorY: nextY,
      pixelScaleX: pixelScaleX,
      pixelScaleY: pixelScaleY,
    );
    surface.material = materialsByPage[entry.page]!;
    _setSpriteSelection(
      surface,
      entry,
      spriteAtlas.atlas.pageSize,
      mirrored: false,
      quad: quad,
    );
    surface.setBounds(quad.bounds);
    mesh.updateBounds();
    markAabbDirty();
    _lumpName = selection.lumpName;
    this.viewAnchorX = nextX;
    this.viewAnchorY = nextY;
    return true;
  }
}

/// Plain-data actor placement for [DoomScene.addActorSprite].
final class ActorSpriteInstance {
  const ActorSpriteInstance({
    required this.spritePrefix,
    required this.x,
    required this.y,
    required this.z,
    this.frame = 0,
    this.actorAngle = 0,
    this.width,
    this.height,
    this.light = 1,
    this.fullBright = false,
    this.fuzz = false,
  });

  final String spritePrefix;
  final int frame;
  final double actorAngle;
  final double x;
  final double y;
  final double z;
  final double? width;
  final double? height;
  final double light;
  final bool fullBright;
  final bool fuzz;
}

/// One exact first-person weapon frame in the supplemental sprite atlas.
final class WeaponSpriteInstance {
  const WeaponSpriteInstance({
    required this.lumpName,
    required this.viewAnchorX,
    required this.viewAnchorY,
    this.pixelScaleX = 1 / 320,
    this.pixelScaleY = 1 / 200,
    this.fullBright = false,
    this.depthLayer = -1,
  });

  final String lumpName;

  /// Camera-local pivot position corresponding to the patch origin.
  final double viewAnchorX;
  final double viewAnchorY;

  /// Camera-local units per source patch pixel.
  final double pixelScaleX;
  final double pixelScaleY;
  final bool fullBright;
  final double depthLayer;
}

final class _GeometryBinding {
  const _GeometryBinding({
    required this.surface,
    required this.mesh,
    required this.component,
  });

  final PackedFlameSurface surface;
  final Mesh mesh;
  final Component3D component;

  void markBoundsDirty() {
    mesh.updateBounds();
    component.markAabbDirty();
  }
}

/// Concrete parent for a level's renderable components.
///
/// [Component3D] is abstract and [Object3D] would add draw and culling work for
/// a node that has no geometry of its own, so the scene root is a plain
/// container whose only job is to group and transform its children.
final class DoomSceneRoot extends Component3D {
  DoomSceneRoot({super.position, super.children});
}

void _writeAtlasRect(
  Float32List vertices,
  int firstVertex,
  int vertexCount,
  geometry.AtlasEntry entry,
  int pageSize,
) {
  final double u0 = entry.u0(pageSize);
  final double v0 = entry.v0(pageSize);
  final double u1 = entry.u1(pageSize);
  final double v1 = entry.v1(pageSize);
  for (var vertex = firstVertex; vertex < firstVertex + vertexCount; vertex++) {
    final int offset =
        vertex * geometry.DoomVertexAbi.floatsPerVertex +
        geometry.DoomVertexAbi.atlasRectOffset;
    vertices[offset] = u0;
    vertices[offset + 1] = v0;
    vertices[offset + 2] = u1;
    vertices[offset + 3] = v1;
  }
}

bool _slotMatches(core.SwitchTextureSlot slot, geometry.WallBandKind band) =>
    switch (slot) {
      core.SwitchTextureSlot.upper => band == geometry.WallBandKind.upper,
      core.SwitchTextureSlot.middle =>
        band == geometry.WallBandKind.middle ||
            band == geometry.WallBandKind.solid,
      core.SwitchTextureSlot.lower => band == geometry.WallBandKind.lower,
    };
