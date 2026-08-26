import 'dart:typed_data';

import 'atlas.dart';
import 'wad_types.dart';

/// Packed GPU buffers and the in-place update handles the runtime needs.
///
/// ## Coordinate convention
///
/// Doom map space is 2D (x, y) plus a separate sector height. The renderer is
/// right-handed with Y up, so this package maps
///
///     world = (mapX, height, -mapY)
///
/// The Y negation is not cosmetic: without it a counter-clockwise map polygon
/// becomes clockwise when viewed from above, and every floor would face away
/// from the camera. With it, map winding carries over unchanged, floors keep
/// their CCW order with a +Y normal, and ceilings are emitted reversed with a
/// -Y normal.
///
/// ## Vertex ABI
///
/// 20 floats per vertex, the same byte layout as flame_3d's Vertex.storage.
/// This must stay identical to lib/adapter/vertex_abi.dart, which is the
/// authority: it is pinned against a real flame_3d Vertex by a tripwire test.
///
///     [0..2]   position   x, y, z
///     [3..4]   texCoord   u, v
///     [5..8]   color      light, 1, 1, alpha
///     [9..11]  normal     x, y, z
///     [12..15] atlas rect u0, v0, u1, v1
///     [16..19] params     fullBright, lightRow, uvMode, unused
///
/// Two slots differ from flame_3d's nominal meaning, by design:
///
/// The colour record carries lighting, not colour. The palette shader resolves
/// real RGB through COLORMAP and PLAYPAL, so red holds the sector light level
/// (fake contrast already applied), green and blue are written as 1, and alpha
/// is reserved for geometry fades.
///
/// Floats 12..19 are flame_3d's skinning joints and weights. Doompeller never
/// skins anything, so instead each vertex carries its own atlas sub-rectangle
/// and sampling mode. That is what lets a single surface draw an entire atlas
/// page: wall, flat and sprite geometry sharing a page merge into one draw
/// rather than one draw per texture, which matters because flame_3d 0.3.0 has
/// no batching and sorts every visible draw.
abstract final class DoomVertexAbi {
  static const int floatsPerVertex = 20;
  static const int positionOffset = 0;
  static const int texCoordOffset = 3;
  static const int colorOffset = 5;
  static const int normalOffset = 9;

  /// flame_3d's joints slot; here the normalised atlas rect (u0, v0, u1, v1).
  static const int atlasRectOffset = 12;

  /// flame_3d's weights slot; here (fullBright, lightRow, uvMode, unused).
  static const int paramsOffset = 16;

  /// Clamp sampling to the vertex's atlas rect. Sprites, so filtering cannot
  /// bleed into a neighbouring entry.
  static const double uvModeClamp = 0;

  /// Tile within the vertex's atlas rect. Walls, flats and sky, whose UVs
  /// deliberately run past 1.
  static const double uvModeRepeat = 1;

  /// Derive the COLORMAP row from light and distance rather than forcing one.
  static const double lightRowAutomatic = -1;

  /// Hard ceiling from 16-bit indices. A mesh is split before crossing it.
  static const int maxVerticesPerMesh = 65535;

  /// Converts a Doom map coordinate pair plus a height into world space.
  static double worldX(double mapX) => mapX;
  static double worldY(double height) => height;
  static double worldZ(double mapY) => -mapY;
}

/// Which draw bucket a surface belongs to.
enum SurfaceKind {
  /// Fully covered geometry, depth-write on, no blending.
  opaque,

  /// Two-sided middle textures and anything with transparent texels.
  masked,

  /// Sky: drawn with the sky shader, never depth-clipped against the world.
  sky,
}

/// Which part of a sidedef a wall quad came from.
enum WallBandKind {
  /// The single wall of a one-sided linedef.
  solid,

  /// The step above a two-sided opening, between the two ceilings.
  upper,

  /// The step below a two-sided opening, between the two floors.
  lower,

  /// An optional see-through texture hung inside a two-sided opening.
  middle,
}

/// One packed, GPU-ready mesh.
class PackedMesh {
  PackedMesh({
    required this.vertices,
    required this.indices,
    required this.vertexCount,
    required this.indexCount,
    required this.atlasPage,
    required this.kind,
  });

  /// [vertexCount] * [DoomVertexAbi.floatsPerVertex] floats.
  final Float32List vertices;

  final Uint16List indices;
  final int vertexCount;
  final int indexCount;

  /// Atlas page every vertex in this mesh samples from.
  final int atlasPage;

  final SurfaceKind kind;

  int get triangleCount => indexCount ~/ 3;

  /// Rewrites the height (world Y) of one vertex. Used by the plane and band
  /// update paths; no mesh rebuild, no reallocation.
  void setVertexHeight(int vertex, double height) {
    vertices[vertex * DoomVertexAbi.floatsPerVertex +
            DoomVertexAbi.positionOffset +
            1] =
        height;
  }

  double vertexHeight(int vertex) =>
      vertices[vertex * DoomVertexAbi.floatsPerVertex +
          DoomVertexAbi.positionOffset +
          1];

  /// Rewrites the vertical texture coordinate of one vertex, so a moving wall
  /// keeps its texture pinned the way vanilla pegging says it should.
  void setVertexV(int vertex, double v) {
    vertices[vertex * DoomVertexAbi.floatsPerVertex +
            DoomVertexAbi.texCoordOffset +
            1] =
        v;
  }

  double vertexV(int vertex) =>
      vertices[vertex * DoomVertexAbi.floatsPerVertex +
          DoomVertexAbi.texCoordOffset +
          1];

  /// Rewrites the horizontal texture coordinate of one vertex. Scrolling-wall
  /// specials use this without changing atlas placement or geometry.
  void setVertexU(int vertex, double u) {
    vertices[vertex * DoomVertexAbi.floatsPerVertex +
            DoomVertexAbi.texCoordOffset] =
        u;
  }

  double vertexU(int vertex) =>
      vertices[vertex * DoomVertexAbi.floatsPerVertex +
          DoomVertexAbi.texCoordOffset];

  /// Rewrites the light level of one vertex, for light-changing sectors.
  void setVertexLight(int vertex, double light) {
    vertices[vertex * DoomVertexAbi.floatsPerVertex +
            DoomVertexAbi.colorOffset] =
        light;
  }

  void setVertexAtlasRect(int vertex, AtlasEntry entry, int atlasPageSize) {
    final int offset =
        vertex * DoomVertexAbi.floatsPerVertex + DoomVertexAbi.atlasRectOffset;
    vertices[offset] = entry.u0(atlasPageSize);
    vertices[offset + 1] = entry.v0(atlasPageSize);
    vertices[offset + 2] = entry.u1(atlasPageSize);
    vertices[offset + 3] = entry.v1(atlasPageSize);
  }
}

/// A contiguous run of vertices inside one mesh.
///
/// Splitting at 65535 vertices means a single sector's floor can land in more
/// than one mesh, so plane and band references hold a list of these rather than
/// a single mesh index.
class VertexRange {
  const VertexRange({
    required this.meshIndex,
    required this.firstVertex,
    required this.vertexCount,
  });

  final int meshIndex;
  final int firstVertex;
  final int vertexCount;
}

/// Handle for moving one sector's floor or ceiling without rebuilding meshes.
///
/// Every vertex of a plane shares the same height, so raising a door is a
/// straight write over [ranges].
class SectorPlaneRef {
  SectorPlaneRef({
    required this.sector,
    required this.isCeiling,
    required this.textureName,
    required this.ranges,
    required this.baseHeight,
  }) : _height = baseHeight;

  final int sector;
  final bool isCeiling;
  String textureName;
  final List<VertexRange> ranges;

  /// Height at compile time, the value the packed buffers were built with.
  final double baseHeight;

  double _height;

  /// Height currently written into the buffers.
  double get height => _height;

  int get vertexCount {
    var total = 0;
    for (var i = 0; i < ranges.length; i++) {
      total += ranges[i].vertexCount;
    }
    return total;
  }

  /// Writes [height] into every vertex of this plane. Returns the number of
  /// vertices touched, so callers can mark exactly the right buffer ranges
  /// dirty for re-upload.
  int applyHeight(List<PackedMesh> meshes, double height) {
    if (height == _height) {
      return 0;
    }
    _height = height;
    var touched = 0;
    for (var r = 0; r < ranges.length; r++) {
      final VertexRange range = ranges[r];
      final PackedMesh mesh = meshes[range.meshIndex];
      final int end = range.firstVertex + range.vertexCount;
      for (var v = range.firstVertex; v < end; v++) {
        mesh.setVertexHeight(v, height);
      }
      touched += range.vertexCount;
    }
    return touched;
  }

  int applyTexture(
    List<PackedMesh> meshes,
    AtlasEntry entry,
    int atlasPageSize,
  ) {
    if (textureName == entry.name) return 0;
    for (final VertexRange range in ranges) {
      final int page = meshes[range.meshIndex].atlasPage;
      if (page != entry.page) {
        throw DoomFormatFailure(
          'sector $sector floor transfer ${entry.name} spans atlas pages '
          '$page and ${entry.page}',
        );
      }
    }
    textureName = entry.name;
    var touched = 0;
    for (final VertexRange range in ranges) {
      final PackedMesh mesh = meshes[range.meshIndex];
      final int end = range.firstVertex + range.vertexCount;
      for (var vertex = range.firstVertex; vertex < end; vertex++) {
        mesh.setVertexAtlasRect(vertex, entry, atlasPageSize);
      }
      touched += range.vertexCount;
    }
    return touched;
  }
}

/// Everything needed to re-derive one wall quad's vertical extent and texture
/// alignment when the sectors it spans move.
///
/// A wall quad is four vertices in a fixed order: 0 bottom-left, 1 bottom-right,
/// 2 top-right, 3 top-left, where left/right follow the linedef direction as
/// seen from this side. Doors and lifts change the top or bottom pair, and
/// pegging decides whether the texture slides with the moving edge or stays
/// pinned; both are recomputed here from the stored alignment parameters.
class WallBandRef {
  WallBandRef({
    required this.linedef,
    required this.sidedef,
    required this.textureName,
    required this.band,
    required this.frontSector,
    required this.backSector,
    required this.meshIndex,
    required this.firstVertex,
    required this.lowerUnpegged,
    required this.upperUnpegged,
    required this.textureHeight,
    required this.textureWidth,
    required this.baseULeft,
    required this.baseURight,
    required this.scrollsHorizontally,
    required this.yOffset,
    required this.rawYOffset,
    required this.nearCeilingAnchor,
    required this.atlasV0,
    required this.atlasV1,
    required this.baseBottom,
    required this.baseTop,
  }) : _bottom = baseBottom,
       _top = baseTop;

  final int linedef;
  final int sidedef;
  final String textureName;
  final WallBandKind band;

  /// Sector this side faces into.
  final int frontSector;

  /// Sector on the far side, or -1 for a one-sided wall.
  final int backSector;

  final int meshIndex;

  /// First of the four vertices of this quad.
  final int firstVertex;

  final bool lowerUnpegged;
  final bool upperUnpegged;

  /// Height of the source texture in texels; 0 when untextured.
  final double textureHeight;

  /// Width of the source picture in texels, used to convert the classic
  /// one-texel-per-tic offset to texture-local UVs.
  final double textureWidth;

  final double baseULeft;
  final double baseURight;

  /// True for classic linedef special 48.
  final bool scrollsHorizontally;

  /// Sidedef vertical offset in texels.
  final double yOffset;

  /// Original sidedef row offset, before any band-specific pegging.
  final double rawYOffset;

  /// Near ceiling at compile time, used when no runtime value is supplied.
  final double nearCeilingAnchor;

  /// Atlas sub-rect this band samples, in normalised page coordinates.
  final double atlasV0;
  final double atlasV1;

  final double baseBottom;
  final double baseTop;

  double _bottom;
  double _top;

  double get bottom => _bottom;
  double get top => _top;

  static const int verticesPerQuad = 4;

  /// Applies the visual-only horizontal wall scroll for [levelTime].
  /// Returns false if this band is static or already contains the requested
  /// offset. The modulo keeps Float32 precision bounded while repeat sampling
  /// makes the wrapped result visually identical.
  bool applyHorizontalScroll(List<PackedMesh> meshes, int levelTime) {
    if (!scrollsHorizontally || textureWidth <= 0) return false;
    final double offset = (levelTime % textureWidth.toInt()) / textureWidth;
    final PackedMesh mesh = meshes[meshIndex];
    final double left = baseULeft + offset;
    final double right = baseURight + offset;
    if (mesh.vertexU(firstVertex) == left &&
        mesh.vertexU(firstVertex + 1) == right) {
      return false;
    }
    mesh.setVertexU(firstVertex, left);
    mesh.setVertexU(firstVertex + 1, right);
    mesh.setVertexU(firstVertex + 2, right);
    mesh.setVertexU(firstVertex + 3, left);
    return true;
  }

  /// Moves the quad to span [bottom]..[top] and re-pegs its texture.
  ///
  /// Returns false when the opening has closed, in which case the quad is
  /// collapsed to zero height rather than left stale or removed; the runtime
  /// keeps a stable draw list and the collapsed quad rasterises nothing.
  bool applyHeights(
    List<PackedMesh> meshes,
    double bottom,
    double top, {
    double? nearCeiling,
  }) {
    final double clampedTop = top < bottom ? bottom : top;
    double drawBottom = bottom;
    double drawTop = clampedTop;
    double topTexel = rawYOffset;
    double bottomTexel;
    final double height = clampedTop - bottom;
    switch (band) {
      case WallBandKind.solid:
        if (lowerUnpegged) {
          topTexel = rawYOffset + textureHeight - height;
        }
        bottomTexel = topTexel + height;
      case WallBandKind.lower:
        if (lowerUnpegged) {
          topTexel =
              rawYOffset + ((nearCeiling ?? nearCeilingAnchor) - clampedTop);
        }
        bottomTexel = topTexel + height;
      case WallBandKind.upper:
        if (!upperUnpegged) {
          topTexel = rawYOffset + textureHeight - height;
        }
        bottomTexel = topTexel + height;
      case WallBandKind.middle:
        final double unclippedTop = lowerUnpegged
            ? bottom + textureHeight + rawYOffset
            : clampedTop + rawYOffset;
        final double unclippedBottom = unclippedTop - textureHeight;
        drawTop = unclippedTop < clampedTop ? unclippedTop : clampedTop;
        drawBottom = unclippedBottom > bottom ? unclippedBottom : bottom;
        if (drawTop < drawBottom) {
          drawTop = drawBottom;
        }
        topTexel = unclippedTop - drawTop;
        bottomTexel = unclippedTop - drawBottom;
    }
    _bottom = drawBottom;
    _top = drawTop;
    final PackedMesh mesh = meshes[meshIndex];
    mesh.setVertexHeight(firstVertex, drawBottom);
    mesh.setVertexHeight(firstVertex + 1, drawBottom);
    mesh.setVertexHeight(firstVertex + 2, drawTop);
    mesh.setVertexHeight(firstVertex + 3, drawTop);
    if (textureHeight > 0) {
      // Texture coordinates stay local. The fragment shader applies atlasV0
      // and atlasV1 exactly once after repeat/clamp resolution.
      final double vTop = topTexel / textureHeight;
      final double vBottom = bottomTexel / textureHeight;
      mesh.setVertexV(firstVertex, vBottom);
      mesh.setVertexV(firstVertex + 1, vBottom);
      mesh.setVertexV(firstVertex + 2, vTop);
      mesh.setVertexV(firstVertex + 3, vTop);
    }
    return drawTop > drawBottom;
  }
}

/// Vertices whose atlas rectangle follows a classic picture animation.
class AnimatedSurfaceRef {
  AnimatedSurfaceRef({
    required this.frames,
    required this.speed,
    required this.initialFrame,
    required this.ranges,
  });

  final List<AtlasEntry> frames;
  final int speed;
  final int initialFrame;
  final List<VertexRange> ranges;

  int frameAt(int levelTime) =>
      (initialFrame + levelTime ~/ speed) % frames.length;
}
