/// The pinned flame_3d 0.3.0 interleaved vertex ABI, expressed once.
///
/// flame_3d builds vertex buffers by concatenating [Vertex.storage], a fixed
/// 20-float interleaved record. Every geometry producer in this project writes
/// that record straight into a [Float32List]; building a list of [Vertex]
/// objects and letting [Surface] re-pack it is roughly 40x slower per remesh
/// and allocates one object per vertex.
///
/// The layout is asserted float-for-float against a real [Vertex] in
/// test/adapter/vertex_abi_test.dart. That test is the pin tripwire: if a
/// flame_3d bump reorders or resizes the record, it fails loudly instead of
/// silently rendering garbage.
///
/// ## Doompeller's use of the skinning slots
///
/// flame_3d reserves floats 12..19 for GPU skinning (joints and weights).
/// Doompeller never skins anything, so those eight floats would stay zero
/// forever. They are repurposed as per-vertex renderer parameters:
///
/// | floats | flame_3d meaning | Doompeller meaning                          |
/// |--------|------------------|---------------------------------------------|
/// | 12..15 | joints           | atlas rect (u0, v0, u1, v1)                 |
/// | 16..19 | weights          | (fullBright, lightRow, uvMode, depthLayer)  |
///
/// This is what lets one [PackedFlameSurface] draw an entire atlas page: each
/// vertex carries its own sub-rectangle and sampling mode, so wall, flat and
/// sprite geometry sharing a page merge into a single draw instead of one draw
/// per texture. flame_3d 0.3.0 has no batching and insertion-sorts visible
/// draws back-to-front, so surface count is the cost that matters most.
///
/// The byte layout is unchanged, so the pipeline's vertex descriptor stays
/// identical to flame_3d's own materials. The custom vertex shader must
/// therefore still declare vertexJoints and vertexWeights, in the same order,
/// to preserve the 80-byte stride.
library;

import 'dart:typed_data';
import 'dart:ui' show Color;

/// Static description of the 20-float vertex record.
abstract final class DoomVertexAbi {
  /// Floats in one vertex record.
  static const int floatsPerVertex = 20;

  /// Bytes in one vertex record.
  static const int bytesPerVertex =
      floatsPerVertex * Float32List.bytesPerElement;

  /// Position (x, y, z).
  static const int positionOffset = 0;

  /// Texture coordinate (u, v). Leaves 0..1 for repeating world geometry.
  static const int texCoordOffset = 3;

  /// Color (r, g, b, a), each normalized to 0..1.
  ///
  /// Doompeller stores the sector light level in the red channel and a fade
  /// factor in alpha. Green and blue are reserved and written as 1.
  static const int colorOffset = 5;

  /// Normal (x, y, z).
  static const int normalOffset = 9;

  /// flame_3d's joints slot; Doompeller's atlas rect.
  static const int jointsOffset = 12;

  /// flame_3d's weights slot; Doompeller's per-vertex surface parameters.
  static const int weightsOffset = 16;

  /// Normalized atlas rectangle (u0, v0, u1, v1) for this vertex's texture.
  static const int atlasRectOffset = jointsOffset;

  /// (fullBright, lightRowOverride, uvMode, depthLayer).
  ///
  /// The depth-layer clip-space convention is live-verified on the current
  /// macOS Impeller Metal target. A non-Metal backend's post-main Z remap is a
  /// separate QA item and is not claimed by this adapter verification.
  static const int paramsOffset = weightsOffset;

  /// Sector light level, 0..1, stored in the color record's red channel.
  static const int lightOffset = colorOffset;

  /// Vertex alpha, used only for geometry fades. 1.0 is the normal case.
  static const int alphaOffset = colorOffset + 3;

  /// UV mode: clamp sampling to the vertex's atlas rect.
  ///
  /// Used by sprites and the weapon quad, where sampling must never bleed into
  /// a neighbouring atlas entry.
  static const double uvModeClamp = 0;

  /// UV mode: tile the texture inside the vertex's atlas rect.
  ///
  /// Used by walls, flats and the sky, where Doom's UVs run past 1.0.
  static const double uvModeRepeat = 1;

  /// Sentinel meaning 'derive the COLORMAP row from light and distance'.
  static const double lightRowAutomatic = -1;

  /// flame_3d 0.3.0 binds index buffers as uint16 only, so one surface can
  /// address at most 65536 vertices.
  static const int maxVerticesPerSurface = 65535;

  /// First float belonging to [vertexIndex].
  static int floatOffsetOf(int vertexIndex) => vertexIndex * floatsPerVertex;

  /// First byte belonging to [vertexIndex].
  static int byteOffsetOf(int vertexIndex) => vertexIndex * bytesPerVertex;

  /// Number of complete vertices in [vertices].
  static int vertexCountOf(Float32List vertices) =>
      vertices.length ~/ floatsPerVertex;

  /// Allocates a buffer sized for [vertexCount] vertices.
  static Float32List allocate(int vertexCount) {
    if (vertexCount < 0) {
      throw RangeError.range(vertexCount, 0, null, 'vertexCount');
    }
    return Float32List(vertexCount * floatsPerVertex);
  }

  /// Writes one complete vertex record into [target] at [vertexIndex].
  ///
  /// This is the single writer used by geometry producers. It allocates
  /// nothing.
  static void writeVertex(
    Float32List target,
    int vertexIndex, {
    required double x,
    required double y,
    required double z,
    required double u,
    required double v,
    double nx = 0,
    double ny = 1,
    double nz = 0,
    double light = 1,
    double alpha = 1,
    double atlasLeft = 0,
    double atlasTop = 0,
    double atlasRight = 1,
    double atlasBottom = 1,
    double uvMode = uvModeRepeat,
    bool fullBright = false,
    double lightRowOverride = lightRowAutomatic,
    double depthLayer = 0,
  }) {
    final offset = floatOffsetOf(vertexIndex);
    target[offset] = x;
    target[offset + 1] = y;
    target[offset + 2] = z;
    target[offset + 3] = u;
    target[offset + 4] = v;
    target[offset + 5] = light;
    target[offset + 6] = 1;
    target[offset + 7] = 1;
    target[offset + 8] = alpha;
    target[offset + 9] = nx;
    target[offset + 10] = ny;
    target[offset + 11] = nz;
    target[offset + 12] = atlasLeft;
    target[offset + 13] = atlasTop;
    target[offset + 14] = atlasRight;
    target[offset + 15] = atlasBottom;
    target[offset + 16] = fullBright ? 1 : 0;
    target[offset + 17] = lightRowOverride;
    target[offset + 18] = uvMode;
    target[offset + 19] = depthLayer;
  }

  /// Writes the exact float record flame_3d's [Vertex] would produce.
  ///
  /// Only the pin tripwire test needs this. Production geometry uses
  /// [writeVertex], which gives the skinning slots their Doompeller meaning.
  static void writeFlameVertex(
    Float32List target,
    int vertexIndex, {
    required double x,
    required double y,
    required double z,
    required double u,
    required double v,
    required Color color,
    required double nx,
    required double ny,
    required double nz,
    required double joint0,
    required double joint1,
    required double joint2,
    required double joint3,
    required double weight0,
    required double weight1,
    required double weight2,
    required double weight3,
  }) {
    final offset = floatOffsetOf(vertexIndex);
    target[offset] = x;
    target[offset + 1] = y;
    target[offset + 2] = z;
    target[offset + 3] = u;
    target[offset + 4] = v;
    target[offset + 5] = color.r;
    target[offset + 6] = color.g;
    target[offset + 7] = color.b;
    target[offset + 8] = color.a;
    target[offset + 9] = nx;
    target[offset + 10] = ny;
    target[offset + 11] = nz;
    target[offset + 12] = joint0;
    target[offset + 13] = joint1;
    target[offset + 14] = joint2;
    target[offset + 15] = joint3;
    target[offset + 16] = weight0;
    target[offset + 17] = weight1;
    target[offset + 18] = weight2;
    target[offset + 19] = weight3;
  }

  /// Overwrites only the Y coordinate of [vertexIndex].
  ///
  /// Moving floors, ceilings and doors change nothing else, so this is the hot
  /// path for dynamic geometry.
  static void setY(Float32List target, int vertexIndex, double y) {
    target[floatOffsetOf(vertexIndex) + positionOffset + 1] = y;
  }

  /// Reads the Y coordinate of [vertexIndex].
  static double getY(Float32List target, int vertexIndex) =>
      target[floatOffsetOf(vertexIndex) + positionOffset + 1];

  /// Overwrites the V texture coordinate of [vertexIndex].
  ///
  /// Doom's unpegged wall bands re-anchor their vertical texture offset when a
  /// door moves, which changes V without changing the atlas rect.
  static void setV(Float32List target, int vertexIndex, double v) {
    target[floatOffsetOf(vertexIndex) + texCoordOffset + 1] = v;
  }

  /// Reads the V texture coordinate of [vertexIndex].
  static double getV(Float32List target, int vertexIndex) =>
      target[floatOffsetOf(vertexIndex) + texCoordOffset + 1];

  /// Overwrites the sector light level of [vertexIndex].
  static void setLight(Float32List target, int vertexIndex, double light) {
    target[floatOffsetOf(vertexIndex) + lightOffset] = light;
  }

  /// Reads the sector light level of [vertexIndex].
  static double getLight(Float32List target, int vertexIndex) =>
      target[floatOffsetOf(vertexIndex) + lightOffset];

  /// Throws unless [vertices] holds whole vertex records within the uint16
  /// index limit.
  static void validateVertexBuffer(Float32List vertices) {
    if (vertices.isEmpty || vertices.length % floatsPerVertex != 0) {
      throw ArgumentError.value(
        vertices.length,
        'vertices',
        'must be a positive multiple of floatsPerVertex',
      );
    }
    final count = vertexCountOf(vertices);
    if (count > maxVerticesPerSurface) {
      throw RangeError.range(count, 1, maxVerticesPerSurface, 'vertexCount');
    }
  }

  /// Throws unless every index in [indices] addresses a vertex that exists.
  static void validateIndexBuffer(Uint16List indices, int vertexCount) {
    if (indices.isEmpty || indices.length % 3 != 0) {
      throw ArgumentError.value(
        indices.length,
        'indices',
        'must be a positive multiple of 3',
      );
    }
    for (final index in indices) {
      if (index >= vertexCount) {
        throw RangeError.range(index, 0, vertexCount - 1, 'index');
      }
    }
  }
}
