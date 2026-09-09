import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

import 'palette_textures.dart';
import 'packed_surface.dart';
import 'vertex_abi.dart';

/// One packed, GPU-ready mesh handed to the adapter.
///
/// Compatibility input for callers that assemble meshes directly. Compiled WAD
/// levels use DoomScene.fromCompiledLevel instead.
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
