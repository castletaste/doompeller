/// Doompeller's interleaved 20-float vertex ABI, expressed once.
///
/// Every geometry producer in this project writes this record straight into
/// a [Float32List]: the geometry compiler, sprites, the weapon and the sky.
/// The renderer uploads those buffers unchanged and binds them through the
/// caller-declared layout in scene_gpu.dart, so nothing is re-packed and
/// nothing is allocated per vertex.
///
/// test/adapter/vertex_abi_test.dart is the tripwire: it checks these offsets
/// against the declared GPU layout and against the attribute declarations in
/// shaders/doom_palette.vert, so a change on any side fails loudly instead of
/// silently rendering garbage.
///
/// | floats | field                                       |
/// |--------|---------------------------------------------|
/// | 0..2   | position (x, y, z)                          |
/// | 3..4   | texture coordinate (u, v)                   |
/// | 5..8   | color: sector light, reserved, reserved, alpha |
/// | 9..11  | normal                                      |
/// | 12..15 | atlas rect (u0, v0, u1, v1)                 |
/// | 16..19 | (fullBright, lightRow, uvMode, depthLayer)  |
///
/// Carrying the atlas rect and sampling mode per vertex is what lets one
/// [PackedSurface] draw an entire atlas page: wall, flat and sprite geometry
/// sharing a page merge into a single draw instead of one draw per texture,
/// and surface count is the per-frame cost that matters most.
library;

import 'dart:typed_data';

import 'packed_surface.dart';

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

  /// Normalized atlas rectangle (u0, v0, u1, v1) for this vertex's texture.
  static const int atlasRectOffset = 12;

  /// (fullBright, lightRowOverride, uvMode, depthLayer).
  ///
  /// The depth layer is written as clip depth by the vertex shader, which
  /// relies on flutter_scene's 0..w clip range with reversed depth off.
  static const int paramsOffset = 16;

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

  /// Surfaces bind uint16 index buffers, so one surface can address at most
  /// 65536 vertices.
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
