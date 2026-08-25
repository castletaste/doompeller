import 'dart:typed_data';

import 'atlas.dart';
import 'packed_mesh.dart';

/// Accumulates vertices into 65535-vertex meshes, split by atlas page and
/// surface kind.
///
/// Indices are 16-bit, so a mesh can address at most 65536 vertices. Rather
/// than fail on a large level, the packer starts a new mesh whenever the
/// current one cannot fit the next primitive whole. Primitives are never split
/// across meshes, which is what lets plane and band references stay contiguous.
class MeshPacker {
  MeshPacker();

  final List<_Bucket> _buckets = <_Bucket>[];
  final Map<int, _Bucket> _openBucket = <int, _Bucket>{};

  /// Current mesh index for a page/kind pair, or -1 if none is open.
  int _keyFor(int page, SurfaceKind kind) => page * 8 + kind.index;

  /// Reserves space for [vertexCount] vertices, returning the bucket that will
  /// hold them. Starts a new mesh when the open one is too full.
  _Bucket _bucketFor(int page, SurfaceKind kind, int vertexCount) {
    final int key = _keyFor(page, kind);
    final _Bucket? open = _openBucket[key];
    if (open != null &&
        open.vertexCount + vertexCount <= DoomVertexAbi.maxVerticesPerMesh) {
      return open;
    }
    final _Bucket fresh = _Bucket(_buckets.length, page, kind);
    _buckets.add(fresh);
    _openBucket[key] = fresh;
    return fresh;
  }

  /// Appends indexed triangle soup, splitting it before 16-bit narrowing.
  ///
  /// [positions] is x, y, z triples; [uvs] u, v pairs; [normal] is shared by
  /// every vertex; [indices] are local to this primitive. Returns the range the
  /// vertices landed in so callers can build update handles.
  List<VertexRange> addPrimitive({
    required int page,
    required SurfaceKind kind,
    required Float64List positions,
    required Float64List uvs,
    required List<int> indices,
    required double normalX,
    required double normalY,
    required double normalZ,
    required double light,
    required double atlasU0,
    required double atlasV0,
    required double atlasU1,
    required double atlasV1,
    double uvMode = DoomVertexAbi.uvModeRepeat,
    bool fullBright = false,
  }) {
    if (positions.length % 3 != 0 || uvs.length % 2 != 0) {
      throw ArgumentError('positions and uvs must contain complete vertices');
    }
    final int sourceVertexCount = positions.length ~/ 3;
    if (uvs.length ~/ 2 != sourceVertexCount || indices.length % 3 != 0) {
      throw ArgumentError('vertex attributes and triangle indices disagree');
    }

    final List<VertexRange> ranges = <VertexRange>[];
    final Map<int, int> remap = <int, int>{};
    final List<int> sourceVertices = <int>[];
    final List<int> localIndices = <int>[];

    void flush() {
      if (localIndices.isEmpty) {
        return;
      }
      final _Bucket bucket = _bucketFor(page, kind, sourceVertices.length);
      final int base = bucket.vertexCount;
      for (final int source in sourceVertices) {
        bucket.pushVertex(
          positions[source * 3],
          positions[source * 3 + 1],
          positions[source * 3 + 2],
          uvs[source * 2],
          uvs[source * 2 + 1],
          light,
          normalX,
          normalY,
          normalZ,
          atlasU0,
          atlasV0,
          atlasU1,
          atlasV1,
          uvMode,
          fullBright,
        );
      }
      for (final int index in localIndices) {
        bucket.pushIndex(base + index);
      }
      ranges.add(
        VertexRange(
          meshIndex: bucket.index,
          firstVertex: base,
          vertexCount: sourceVertices.length,
        ),
      );
      remap.clear();
      sourceVertices.clear();
      localIndices.clear();
    }

    for (var t = 0; t < indices.length; t += 3) {
      var newVertices = 0;
      for (var corner = 0; corner < 3; corner++) {
        final int source = indices[t + corner];
        if (source < 0 || source >= sourceVertexCount) {
          throw RangeError.range(source, 0, sourceVertexCount - 1, 'index');
        }
        if (!remap.containsKey(source)) {
          newVertices++;
        }
      }
      if (sourceVertices.isNotEmpty &&
          sourceVertices.length + newVertices >
              DoomVertexAbi.maxVerticesPerMesh) {
        flush();
      }
      for (var corner = 0; corner < 3; corner++) {
        final int source = indices[t + corner];
        final int local = remap.putIfAbsent(source, () {
          sourceVertices.add(source);
          return sourceVertices.length - 1;
        });
        localIndices.add(local);
      }
    }
    flush();
    return ranges;
  }

  List<PackedMesh> finish() {
    final List<PackedMesh> out = <PackedMesh>[];
    for (var i = 0; i < _buckets.length; i++) {
      out.add(_buckets[i].freeze());
    }
    return out;
  }

  int get meshCount => _buckets.length;

  int get totalVertices {
    var total = 0;
    for (var i = 0; i < _buckets.length; i++) {
      total += _buckets[i].vertexCount;
    }
    return total;
  }

  int get totalTriangles {
    var total = 0;
    for (var i = 0; i < _buckets.length; i++) {
      total += _buckets[i].indexCount ~/ 3;
    }
    return total;
  }
}

class _Bucket {
  _Bucket(this.index, this.page, this.kind);

  final int index;
  final int page;
  final SurfaceKind kind;

  Float32List _vertices = Float32List(1024 * DoomVertexAbi.floatsPerVertex);
  Uint16List _indices = Uint16List(2048);
  int vertexCount = 0;
  int indexCount = 0;

  void pushVertex(
    double x,
    double y,
    double z,
    double u,
    double v,
    double light,
    double nx,
    double ny,
    double nz,
    double atlasU0,
    double atlasV0,
    double atlasU1,
    double atlasV1,
    double uvMode,
    bool fullBright,
  ) {
    final int need = (vertexCount + 1) * DoomVertexAbi.floatsPerVertex;
    if (need > _vertices.length) {
      final Float32List grown = Float32List(_vertices.length * 2);
      grown.setRange(0, vertexCount * DoomVertexAbi.floatsPerVertex, _vertices);
      _vertices = grown;
    }
    final int o = vertexCount * DoomVertexAbi.floatsPerVertex;
    _vertices[o] = x;
    _vertices[o + 1] = y;
    _vertices[o + 2] = z;
    _vertices[o + 3] = u;
    _vertices[o + 4] = v;
    // Colour carries lighting, not colour: the palette shader resolves real
    // RGB through COLORMAP, so red is the light level, green and blue are
    // written as 1 and alpha is reserved for geometry fades.
    _vertices[o + 5] = light;
    _vertices[o + 6] = 1.0;
    _vertices[o + 7] = 1.0;
    _vertices[o + 8] = 1.0;
    _vertices[o + 9] = nx;
    _vertices[o + 10] = ny;
    _vertices[o + 11] = nz;
    // Skinning slots repurposed: each vertex carries the atlas sub-rect it
    // samples and how to sample it, so one surface can draw a whole page.
    _vertices[o + 12] = atlasU0;
    _vertices[o + 13] = atlasV0;
    _vertices[o + 14] = atlasU1;
    _vertices[o + 15] = atlasV1;
    _vertices[o + 16] = fullBright ? 1.0 : 0.0;
    _vertices[o + 17] = DoomVertexAbi.lightRowAutomatic;
    _vertices[o + 18] = uvMode;
    _vertices[o + 19] = 0.0;
    vertexCount++;
  }

  void pushIndex(int value) {
    if (indexCount + 1 > _indices.length) {
      final Uint16List grown = Uint16List(_indices.length * 2);
      grown.setRange(0, indexCount, _indices);
      _indices = grown;
    }
    _indices[indexCount++] = value;
  }

  PackedMesh freeze() {
    final Float32List verts = Float32List(
      vertexCount * DoomVertexAbi.floatsPerVertex,
    );
    verts.setRange(0, verts.length, _vertices);
    final Uint16List idx = Uint16List(indexCount);
    idx.setRange(0, indexCount, _indices);
    return PackedMesh(
      vertices: verts,
      indices: idx,
      vertexCount: vertexCount,
      indexCount: indexCount,
      atlasPage: page,
      kind: kind,
    );
  }
}

/// Maps a world-space point onto a flat's texture.
///
/// Flats are not projected: Doom aligns them to a fixed 64-unit world grid, so
/// a floor's texture stays put as the floor moves and lines up across every
/// sector that shares it. The shader owns atlas-rect mapping, so this mapper
/// emits texture-local UV only.
class FlatUvMapper {
  const FlatUvMapper(this.entry, this.pageSize);

  final AtlasEntry entry;
  final int pageSize;

  double u(double mapX) {
    return mapX / kFlatTileSize;
  }

  double v(double mapY) {
    // Map Y grows north while texture V grows down, so the sign flips here to
    // keep flats reading the same way they do in the original.
    return -mapY / kFlatTileSize;
  }
}

/// Doom flats are 64x64 and cover 64x64 map units.
const double kFlatTileSize = 64.0;
