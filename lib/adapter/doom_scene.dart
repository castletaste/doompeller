import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

import 'doom_scene_input.dart';
import 'doom_actor_pool.dart';
import 'doom_dynamic_geometry.dart';
import 'doom_sky.dart';
import 'doom_sprite_components.dart';
import 'packed_surface.dart';
import 'palette_material.dart';
import 'palette_textures.dart';
import 'render_diagnostics.dart';
import 'doom_sprite_atlas.dart';
import 'vertex_abi.dart';

export 'doom_scene_input.dart';
export 'doom_sprite_components.dart'
    show
        CameraLockedMeshComponent,
        SkyMeshComponent,
        ViewLockedWeaponComponent,
        YawBillboardMeshComponent,
        ActorSpriteComponent,
        ViewLockedWeaponSpriteComponent,
        ActorSpriteInstance,
        WeaponSpriteInstance;

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
    geometry.CompiledLevel? compiledLevel,
    Map<int, DoomGeometryBinding> geometryBindings = const {},
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
       _geometryBindings = geometryBindings,
       _dynamicGeometry = compiledLevel == null
           ? null
           : DoomDynamicGeometry(
               compiledLevel,
               bindings: geometryBindings,
               sectorLights: sectorLights,
               diagnostics: diagnostics,
             );

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
    final bindings = <int, DoomGeometryBinding>{};
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
      bindings[meshIndex] = DoomGeometryBinding(
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
      final surface = buildSkySurface(
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
  final DoomDynamicGeometry? _dynamicGeometry;
  final Map<int, DoomGeometryBinding> _geometryBindings;
  final DoomSpriteAtlas? _spriteAtlas;
  final Map<int, PaletteMaterial> _spriteMaterials;
  late final DoomActorPool _actors = DoomActorPool(
    atlas: _spriteAtlas,
    materials: _spriteMaterials,
    diagnostics: diagnostics,
    onCreated: (component, page) {
      root.add(component);
      _surfacesByPage
          .putIfAbsent('sprite:$page', () => [])
          .add(component.surface);
    },
  );

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
      _actors.surfaceIsActive(surface);
  int get actorSurfaceRegistryCount => _actors.actorSurfaceRegistryCount;
  int get activeActorSurfaceCount => _actors.activeActorSurfaceCount;
  int get pooledActorSurfaceCount => _actors.pooledActorSurfaceCount;
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
    final dynamicGeometry = _dynamicGeometry;
    if (dynamicGeometry != null) {
      return dynamicGeometry.updateSectorPlane(
        sectorIndex: sectorIndex,
        height: height,
        isCeiling: isCeiling,
      );
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

  DoomDynamicGeometry get _requiredGeometry =>
      _dynamicGeometry ??
      (throw StateError('This operation requires DoomScene.fromCompiledLevel'));

  int updateTextureAnimations(int levelTime) =>
      _requiredGeometry.updateTextureAnimations(levelTime);
  int updateAnimationFrames(int levelTime) =>
      updateTextureAnimations(levelTime);
  int updateSectorFloorFlat({
    required int sectorIndex,
    required String flatName,
  }) => _requiredGeometry.updateSectorFloorFlat(
    sectorIndex: sectorIndex,
    flatName: flatName,
  );
  int updateSwitchTexture(core.SwitchTextureChange change) =>
      _requiredGeometry.updateSwitchTexture(change);
  int updateWallsForSector({
    required int sectorIndex,
    required double floorHeight,
    required double ceilingHeight,
    required List<double> sectorFloors,
    required List<double> sectorCeilings,
  }) => _requiredGeometry.updateWallsForSector(
    sectorIndex: sectorIndex,
    floorHeight: floorHeight,
    ceilingHeight: ceilingHeight,
    sectorFloors: sectorFloors,
    sectorCeilings: sectorCeilings,
  );
  int updateSectorLight({required int sectorIndex, required int lightLevel}) =>
      _requiredGeometry.updateSectorLight(
        sectorIndex: sectorIndex,
        lightLevel: lightLevel,
      );
  void resetDynamicState(wad.MapData map) =>
      _requiredGeometry.resetDynamicState(map);

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

  ActorSpriteComponent? acquireActorSprite(ActorSpriteInstance actor) =>
      _actors.acquireActorSprite(actor);
  bool updateActorSprite(
    ActorSpriteComponent component,
    ActorSpriteInstance actor,
  ) => _actors.updateActorSprite(component, actor);
  void releaseActorSprite(ActorSpriteComponent component) =>
      _actors.releaseActorSprite(component);

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
    final quad = weaponSpriteQuad(
      entry,
      viewAnchorX: weapon.viewAnchorX,
      viewAnchorY: weapon.viewAnchorY,
      pixelScaleX: weapon.pixelScaleX,
      pixelScaleY: weapon.pixelScaleY,
    );
    final vertices = buildSpriteVertices(
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

/// Concrete parent for a level's renderable components.
///
/// [Component3D] is abstract and [Object3D] would add draw and culling work for
/// a node that has no geometry of its own, so the scene root is a plain
/// container whose only job is to group and transform its children.
final class DoomSceneRoot extends Component3D {
  DoomSceneRoot({super.position, super.children});
}
