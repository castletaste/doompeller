import 'dart:typed_data';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

import 'packed_surface.dart';
import 'palette_material.dart';
import 'palette_textures.dart';
import 'render_diagnostics.dart';
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

  Aabb3 toAabb3() => Aabb3.minMax(
    Vector3(minX, minY, minZ),
    Vector3(maxX, maxY, maxZ),
  );
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
  }) : // These are exposed through narrower read-only accessors, so the
       // backing fields stay private.
       // ignore: prefer_initializing_formals
       _surfacesByPage = surfacesByPage,
       // ignore: prefer_initializing_formals
       _floorPlanes = floorPlanes,
       // ignore: prefer_initializing_formals
       _ceilingPlanes = ceilingPlanes,
       // ignore: prefer_initializing_formals
       _wallBands = wallBands;

  /// Assembles a scene from compiled level data.
  factory DoomScene.build(
    CompiledLevelInput level, {
    RenderDiagnostics? diagnostics,
    PaletteMaterialCache? materials,
  }) {
    final counters = diagnostics ?? RenderDiagnostics();
    final materialCache = materials ?? PaletteMaterialCache();
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

  /// Mount this under a World3D to render the level.
  final DoomSceneRoot root;

  final RenderDiagnostics diagnostics;

  /// Shared materials, also the entry point for palette flashes.
  final PaletteMaterialCache materials;

  final Map<String, List<PackedFlameSurface>> _surfacesByPage;
  final List<SectorPlaneRef> _floorPlanes;
  final List<SectorPlaneRef> _ceilingPlanes;
  final List<WallBandRef> _wallBands;

  /// Total surfaces, the number that drives per-frame draw cost.
  int get surfaceCount =>
      _surfacesByPage.values.fold(0, (sum, list) => sum + list.length);

  /// Every surface, in creation order.
  Iterable<PackedFlameSurface> get surfaces =>
      _surfacesByPage.values.expand((list) => list);

  /// Surfaces drawing [page].
  List<PackedFlameSurface> surfacesForPage(String page) =>
      List.unmodifiable(_surfacesByPage[page] ?? const []);

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
        surface.updateVertices(
          (vertices) {
            surfaceChanged = _writeBand(
              vertices,
              surface,
              band,
              topHeight,
              bottomHeight,
            );
          },
          bounds: bounds,
        );
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
        DoomSurfaceKind.sky ||
        DoomSurfaceKind.weapon => CameraLockedMeshComponent(mesh: mesh),
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

    return _MergedBatch(
      vertices: vertices,
      indices: indices,
      bounds: bounds,
    );
  }

  final Float32List vertices;
  final Uint16List indices;
  final SceneBounds bounds;
}

/// A mesh that translates with the camera but does not rotate with it.
///
/// The sky and the weapon both need this: the sky must stay infinitely far
/// away, and the weapon must stay glued to the view. Following the camera's
/// position while keeping world orientation gives the sky its parallax-free
/// look without a separate render pass, which matters because flame_3d applies
/// blend and depth state per pass, not per object.
final class CameraLockedMeshComponent extends MeshComponent {
  CameraLockedMeshComponent({required super.mesh});

  @override
  void update(double dt) {
    super.update(dt);
    final camera = CameraComponent3D.currentCamera;
    if (camera != null) {
      position.setFrom(camera.position);
    }
  }

  /// Always drawn: a camera-locked mesh surrounds the view, so frustum culling
  /// it is both wrong and wasted work.
  @override
  bool isVisible(CameraComponent3D camera) => true;
}

/// Concrete parent for a level's renderable components.
///
/// [Component3D] is abstract and [Object3D] would add draw and culling work for
/// a node that has no geometry of its own, so the scene root is a plain
/// container whose only job is to group and transform its children.
final class DoomSceneRoot extends Component3D {
  DoomSceneRoot({super.position, super.children});
}
