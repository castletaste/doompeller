import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

import 'render_diagnostics.dart';
import 'vertex_abi.dart';

/// A [Surface] over buffers that were already packed in flame_3d's vertex ABI.
///
/// flame_3d's own [Surface] constructor insists on a list of [Vertex] objects
/// and re-packs them into a [Float32List]. Doom geometry is produced packed
/// already, so this subclass hands the base class an empty vertex list and
/// overrides every geometry-facing getter. Nothing is copied and nothing is
/// allocated per frame.
///
/// The buffers stay owned by the caller. Passing the same [Float32List] to a
/// surface and then mutating it elsewhere is supported and is exactly how
/// moving floors work: mutate, mark the touched vertices dirty, and the next
/// draw uploads only the touched byte range into the existing GPU buffer.
///
/// ## Why partial uploads matter
///
/// flame_3d allocates one host-visible [GpuBuffer] per surface holding vertices
/// followed by indices. Re-creating that buffer for a height change would
/// orphan the old one, and flame_3d 0.3.0 exposes no per-resource disposal, so
/// orphaned buffers cannot be reclaimed on demand. Writing in place keeps the
/// buffer count flat. Writing only the dirty range keeps a door on a merged
/// atlas page from re-uploading megabytes of untouched wall geometry.
final class PackedFlameSurface extends Surface {
  /// Wraps [vertices] and [indices] without copying them.
  ///
  /// [bounds] must enclose every position in [vertices]; it is used for frustum
  /// culling and is not derived from the buffer, because deriving it would cost
  /// a full scan the geometry compiler has already paid for.
  PackedFlameSurface({
    required Float32List vertices,
    required Uint16List indices,
    required Aabb3 bounds,
    required Material material,
    this.kind = DoomSurfaceKind.opaque,
    this.diagnostics,
    this.debugLabel,
  }) : // The public constructor takes non-private names, so an initializing
       // formal is not available here.
       // ignore: prefer_initializing_formals
       _vertices = vertices,
       // ignore: prefer_initializing_formals
       _indices = indices,
       _aabb = Aabb3.copy(bounds),
       super(
         vertices: const [],
         indices: const [],
         material: material,
         calculateNormals: false,
       ) {
    DoomVertexAbi.validateVertexBuffer(_vertices);
    DoomVertexAbi.validateIndexBuffer(_indices, vertexCount);
    _validateBounds(bounds);
    diagnostics?.onSurfaceCreated(triangleCount: _indices.length ~/ 3);
  }

  /// What this surface draws. Only used for diagnostics and scene grouping;
  /// blend and depth state are per render pass in flame_3d 0.3.0, never per
  /// material.
  final DoomSurfaceKind kind;

  /// Optional counters, shared with the rest of the renderer.
  final RenderDiagnostics? diagnostics;

  /// Human-readable name used in diagnostics dumps and test failures.
  final String? debugLabel;

  final Float32List _vertices;
  final Uint16List _indices;

  Aabb3 _aabb;
  Float32List? _positionsCache;
  GpuBuffer? _buffer;

  /// Sorted, non-overlapping inclusive dirty vertex ranges.
  final List<(int, int)> _dirtyRanges = <(int, int)>[];

  /// The live packed vertex buffer.
  ///
  /// Mutating it directly is allowed, but every touched vertex must be passed
  /// to [markVertexDirty] or the change will not reach the GPU.
  Float32List get packedVertices => _vertices;

  /// Whether a GPU buffer has been created for this surface yet.
  bool get hasGpuBuffer => _buffer != null;

  /// Whether there are CPU-side changes not yet uploaded.
  bool get hasPendingUpload => _dirtyRanges.isNotEmpty;

  /// Triangles in this surface.
  int get triangleCount => _indices.length ~/ 3;

  @override
  int get vertexCount => DoomVertexAbi.vertexCountOf(_vertices);

  @override
  int get verticesBytes => _vertices.lengthInBytes;

  @override
  int get indexCount => _indices.length;

  @override
  int get indicesBytes => _indices.lengthInBytes;

  @override
  Uint16List get indices => _indices;

  @override
  Aabb3 get aabb => _aabb;

  /// Positions as flame_3d exposes them, materialized on first read.
  ///
  /// Doompeller's own render path never needs this: positions already live
  /// interleaved in [packedVertices]. Keeping it lazy avoids paying 12 bytes
  /// per vertex for a view most surfaces never use, and later dirty writes are
  /// mirrored into the cache only once it exists.
  @override
  Float32List get positions {
    final cached = _positionsCache;
    if (cached != null) {
      return cached;
    }
    final count = vertexCount;
    final result = Float32List(count * 3);
    for (var vertex = 0; vertex < count; vertex++) {
      final source = DoomVertexAbi.floatOffsetOf(vertex);
      final target = vertex * 3;
      result[target] = _vertices[source];
      result[target + 1] = _vertices[source + 1];
      result[target + 2] = _vertices[source + 2];
    }
    return _positionsCache = result;
  }

  @override
  bool get recreateResource =>
      _buffer == null || resourceSizeInByes != verticesBytes + indicesBytes;

  /// The GPU buffer, flushing any pending in-place writes first.
  ///
  /// flame_3d reads this once per draw in [GraphicsDevice.bindGeometry], which
  /// makes it the natural upload point: a dynamic surface can be mutated any
  /// number of times per tick and still upload at most once per frame.
  @override
  GpuBuffer get resource {
    final buffer = super.resource;
    if (_dirtyRanges.isNotEmpty) {
      _uploadDirtyRanges(buffer);
    }
    return buffer;
  }

  @override
  GpuBuffer createResource() {
    final totalBytes = verticesBytes + indicesBytes;
    resourceSizeInByes = totalBytes;
    final buffer =
        GpuBackend.instance.createBuffer(
            storageMode: GpuStorageMode.hostVisible,
            sizeInBytes: totalBytes,
          )
          ..write(_byteView(_vertices))
          ..write(_byteView(_indices), destinationOffsetInBytes: verticesBytes);
    _buffer = buffer;
    _dirtyRanges.clear();
    diagnostics?.onGpuBufferCreated(bytes: totalBytes);
    return buffer;
  }

  /// Records that [vertexIndex] was mutated and must be re-uploaded.
  void markVertexDirty(int vertexIndex) {
    if (vertexIndex < 0 || vertexIndex >= vertexCount) {
      throw RangeError.range(vertexIndex, 0, vertexCount - 1, 'vertexIndex');
    }
    _insertDirtyRange(vertexIndex, vertexIndex);
    _syncPositionsRange(vertexIndex, vertexIndex);
  }

  /// Records a contiguous mutated range without walking it vertex by vertex.
  void markVertexRangeDirty(int firstVertex, int vertexCount) {
    if (vertexCount < 0) {
      throw RangeError.range(vertexCount, 0, null, 'vertexCount');
    }
    if (vertexCount == 0) {
      return;
    }
    final lastVertex = firstVertex + vertexCount - 1;
    if (firstVertex < 0 || lastVertex >= this.vertexCount) {
      throw RangeError(
        'vertex range $firstVertex..$lastVertex is outside '
        '0..${this.vertexCount - 1}',
      );
    }
    _insertDirtyRange(firstVertex, lastVertex);
    _syncPositionsRange(firstVertex, lastVertex);
  }

  /// Mutates vertices in place through [write] and uploads only what changed.
  ///
  /// [write] receives the live packed buffer and must call [markVertexDirty]
  /// for every vertex it touches. Supply [bounds] whenever positions move, so
  /// frustum culling stays correct without a full rescan.
  void updateVertices(
    void Function(Float32List vertices) write, {
    Aabb3? bounds,
  }) {
    write(_vertices);
    if (bounds != null) {
      _validateBounds(bounds);
      _aabb = Aabb3.copy(bounds);
    }
    _syncDirtyPositions();
    if (_dirtyRanges.isNotEmpty) {
      diagnostics?.onDynamicUpdate();
    }
  }

  /// Moves [vertexIndices] to [y], the common case for a floor, ceiling or
  /// door.
  ///
  /// Vertices already at [y] are skipped, so a plane that stopped moving costs
  /// nothing. Returns whether anything changed.
  bool setVertexHeights(List<int> vertexIndices, double y, {Aabb3? bounds}) {
    if (!y.isFinite) {
      throw ArgumentError.value(y, 'y', 'must be finite');
    }
    var changed = false;
    for (final vertexIndex in vertexIndices) {
      if (vertexIndex < 0 || vertexIndex >= vertexCount) {
        throw RangeError.range(vertexIndex, 0, vertexCount - 1, 'vertexIndex');
      }
      if (DoomVertexAbi.getY(_vertices, vertexIndex) == y) {
        continue;
      }
      DoomVertexAbi.setY(_vertices, vertexIndex, y);
      markVertexDirty(vertexIndex);
      changed = true;
    }
    if (!changed) {
      return false;
    }
    if (bounds != null) {
      _validateBounds(bounds);
      _aabb = Aabb3.copy(bounds);
    }
    _syncDirtyPositions();
    diagnostics?.onDynamicUpdate();
    return true;
  }

  /// Replaces this surface's bounds after an external mutation.
  void setBounds(Aabb3 bounds) {
    _validateBounds(bounds);
    _aabb = Aabb3.copy(bounds);
  }

  /// Conservatively grows only the vertical span after dynamic geometry.
  ///
  /// Bounds never shrink on the per-tic path, so moving one band cannot make
  /// unrelated geometry in the same surface disappear from frustum culling.
  void expandBoundsY(double y) {
    if (!y.isFinite) {
      throw ArgumentError.value(y, 'y', 'must be finite');
    }
    final min = _aabb.min;
    final max = _aabb.max;
    if (y >= min.y && y <= max.y) {
      return;
    }
    _aabb = Aabb3.minMax(
      Vector3(min.x, y < min.y ? y : min.y, min.z),
      Vector3(max.x, y > max.y ? y : max.y, max.z),
    );
  }

  /// Recomputes bounds by scanning every position. O(vertexCount); prefer
  /// passing known bounds on the hot path.
  Aabb3 recomputeBounds() {
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    final count = vertexCount;
    for (var vertex = 0; vertex < count; vertex++) {
      final offset = DoomVertexAbi.floatOffsetOf(vertex);
      final x = _vertices[offset];
      final y = _vertices[offset + 1];
      final z = _vertices[offset + 2];
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }
    return _aabb = Aabb3.minMax(
      Vector3(minX, minY, minZ),
      Vector3(maxX, maxY, maxZ),
    );
  }

  /// Uploads pending writes now instead of at the next draw.
  ///
  /// Returns whether bytes were sent. Does nothing before the first draw, since
  /// the initial [createResource] upload will include the changes anyway.
  bool flushPendingUpload() {
    final buffer = _buffer;
    if (buffer == null || _dirtyRanges.isEmpty) {
      return false;
    }
    _uploadDirtyRanges(buffer);
    return true;
  }

  void _uploadDirtyRanges(GpuBuffer buffer) {
    // Dirty tracking is vertex-granular. Even if a caller changed only atlas
    // rect floats 12..15, each upload covers the complete 80-byte records for
    // the touched vertices; it does not issue strided 16-byte writes.
    for (final range in _dirtyRanges) {
      final firstByte = DoomVertexAbi.byteOffsetOf(range.$1);
      final lastByte = DoomVertexAbi.byteOffsetOf(range.$2 + 1);
      final length = lastByte - firstByte;
      buffer.write(
        _vertices.buffer.asByteData(
          _vertices.offsetInBytes + firstByte,
          length,
        ),
        destinationOffsetInBytes: firstByte,
      );
      diagnostics?.onDynamicUpload(bytes: length);
    }
    _dirtyRanges.clear();
  }

  /// Keeps the lazily materialized [positions] view consistent, but only if
  /// something already asked for it.
  void _syncDirtyPositions() {
    final cache = _positionsCache;
    if (cache == null || _dirtyRanges.isEmpty) {
      return;
    }
    for (final range in _dirtyRanges) {
      _syncPositionsRange(range.$1, range.$2);
    }
  }

  void _syncPositionsRange(int first, int last) {
    final cache = _positionsCache;
    if (cache == null) {
      return;
    }
    for (var vertex = first; vertex <= last; vertex++) {
      final source = DoomVertexAbi.floatOffsetOf(vertex);
      final target = vertex * 3;
      cache[target] = _vertices[source];
      cache[target + 1] = _vertices[source + 1];
      cache[target + 2] = _vertices[source + 2];
    }
  }

  void _insertDirtyRange(int first, int last) {
    var mergedFirst = first;
    var mergedLast = last;
    var insertAt = 0;
    while (insertAt < _dirtyRanges.length &&
        _dirtyRanges[insertAt].$2 + 1 < mergedFirst) {
      insertAt++;
    }
    while (insertAt < _dirtyRanges.length &&
        _dirtyRanges[insertAt].$1 <= mergedLast + 1) {
      final current = _dirtyRanges.removeAt(insertAt);
      if (current.$1 < mergedFirst) {
        mergedFirst = current.$1;
      }
      if (current.$2 > mergedLast) {
        mergedLast = current.$2;
      }
    }
    _dirtyRanges.insert(insertAt, (mergedFirst, mergedLast));
  }

  void _validateBounds(Aabb3 bounds) {
    final min = bounds.min;
    final max = bounds.max;
    final values = [min.x, min.y, min.z, max.x, max.y, max.z];
    if (values.any((value) => !value.isFinite)) {
      throw ArgumentError.value(values, 'bounds', 'must be finite');
    }
    if (min.x > max.x || min.y > max.y || min.z > max.z) {
      throw ArgumentError.value(values, 'bounds', 'min must not exceed max');
    }
  }
}

/// What a surface represents in the Doom renderer.
///
/// flame_3d 0.3.0 applies blend and depth state per render pass rather than per
/// material, so this cannot switch GPU state. It drives scene grouping, draw
/// ordering and diagnostics instead.
enum DoomSurfaceKind {
  /// Solid walls, floors and ceilings.
  opaque,

  /// Two-sided midtextures with cut-out pixels.
  masked,

  /// The camera-locked sky.
  sky,

  /// Actor billboards.
  sprite,

  /// The camera-locked weapon quad.
  weapon,
}

ByteData _byteView(TypedData data) =>
    data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes);
