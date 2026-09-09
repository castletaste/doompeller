import 'dart:typed_data';

import 'limits.dart';
import 'map_loader.dart';
import 'wad.dart';

/// Pure data model for one Doom map. No behaviour, no Flutter, no rendering.
///
/// Field names follow the classic lump layouts so cross-checking against the
/// published WAD format documentation stays mechanical.

/// A map vertex in Doom map units. Doom uses integer coordinates where the
/// player is 56 units tall and 32 units wide.
class MapVertex {
  const MapVertex(this.x, this.y);

  final int x;
  final int y;

  @override
  String toString() => 'MapVertex($x, $y)';
}

/// Linedef flags, matching the vanilla bit layout.
abstract final class LinedefFlags {
  static const int blocking = 0x0001;
  static const int blockMonsters = 0x0002;
  static const int twoSided = 0x0004;
  static const int upperUnpegged = 0x0008;
  static const int lowerUnpegged = 0x0010;
  static const int secret = 0x0020;
  static const int soundBlock = 0x0040;
  static const int dontDraw = 0x0080;
  static const int mapped = 0x0100;
}

/// Sentinel used by vanilla for "no sidedef on this side".
const int kNoSidedef = -1;

/// Sentinel used by vanilla for "no sector".
const int kNoSector = -1;

class Linedef {
  const Linedef({
    required this.v1,
    required this.v2,
    required this.flags,
    required this.special,
    required this.tag,
    required this.rightSidedef,
    required this.leftSidedef,
  });

  final int v1;
  final int v2;
  final int flags;
  final int special;
  final int tag;

  /// Front side. Vanilla maps always have one; a missing right side is invalid.
  final int rightSidedef;

  /// Back side, or [kNoSidedef].
  final int leftSidedef;

  bool get isTwoSided =>
      (flags & LinedefFlags.twoSided) != 0 && leftSidedef != kNoSidedef;
  bool get blocksMovement => (flags & LinedefFlags.blocking) != 0;
  bool get lowerUnpegged => (flags & LinedefFlags.lowerUnpegged) != 0;
  bool get upperUnpegged => (flags & LinedefFlags.upperUnpegged) != 0;
}

class Sidedef {
  const Sidedef({
    required this.xOffset,
    required this.yOffset,
    required this.upperTexture,
    required this.lowerTexture,
    required this.middleTexture,
    required this.sector,
  });

  final int xOffset;
  final int yOffset;

  /// Uppercase, '-' means "no texture".
  final String upperTexture;
  final String lowerTexture;
  final String middleTexture;
  final int sector;
}

class Sector {
  const Sector({
    required this.floorHeight,
    required this.ceilingHeight,
    required this.floorFlat,
    required this.ceilingFlat,
    required this.lightLevel,
    required this.special,
    required this.tag,
  });

  final int floorHeight;
  final int ceilingHeight;
  final String floorFlat;
  final String ceilingFlat;
  final int lightLevel;
  final int special;
  final int tag;

  /// F_SKY1 is the magic flat name that means "render sky here".
  bool get ceilingIsSky => ceilingFlat == 'F_SKY1';
  bool get floorIsSky => floorFlat == 'F_SKY1';
}

/// One BSP segment. Vanilla SEGS omit minisegs, so subsector polygons cannot be
/// closed from segs alone; the geometry compiler must clip against BSP planes.
class Seg {
  const Seg({
    required this.v1,
    required this.v2,
    required this.angle,
    required this.linedef,
    required this.side,
    required this.offset,
  });

  final int v1;
  final int v2;

  /// BAM angle (0..65535 maps to 0..360 degrees).
  final int angle;
  final int linedef;

  /// 0 = seg follows the linedef's right side, 1 = left side.
  final int side;
  final int offset;
}

class Subsector {
  const Subsector({required this.segCount, required this.firstSeg});

  final int segCount;
  final int firstSeg;
}

/// Child pointer marker: when set, the low 15 bits index SSECTORS.
const int kSubsectorBit = 0x8000;

class BspNode {
  const BspNode({
    required this.x,
    required this.y,
    required this.dx,
    required this.dy,
    required this.rightBox,
    required this.leftBox,
    required this.rightChild,
    required this.leftChild,
  });

  /// Partition line origin.
  final int x;
  final int y;

  /// Partition line delta.
  final int dx;
  final int dy;

  /// Bounding boxes as [top, bottom, left, right].
  final Int16List rightBox;
  final Int16List leftBox;

  /// Raw child words; [kSubsectorBit] distinguishes leaves from nodes.
  final int rightChild;
  final int leftChild;

  bool get rightIsSubsector => (rightChild & kSubsectorBit) != 0;
  bool get leftIsSubsector => (leftChild & kSubsectorBit) != 0;
  int get rightIndex => rightChild & ~kSubsectorBit;
  int get leftIndex => leftChild & ~kSubsectorBit;
}

abstract final class ThingFlags {
  static const int easy = 0x0001;
  static const int medium = 0x0002;
  static const int hard = 0x0004;
  static const int ambush = 0x0008;
  static const int multiplayerOnly = 0x0010;
}

class Thing {
  const Thing({
    required this.x,
    required this.y,
    required this.angle,
    required this.type,
    required this.flags,
  });

  final int x;
  final int y;

  /// Degrees, 0 = east, counter-clockwise.
  final int angle;
  final int type;
  final int flags;
}

/// Vanilla collision acceleration structure. Retained because the gameplay
/// simulation reuses it rather than building its own broadphase.
class Blockmap {
  const Blockmap({
    required this.originX,
    required this.originY,
    required this.columns,
    required this.rows,
    required this.cells,
  });

  final int originX;
  final int originY;
  final int columns;
  final int rows;

  /// One list of linedef indices per cell, row-major.
  final List<Uint16List> cells;

  static const int blockSize = 128;

  List<Uint16List> get allCells => cells;

  Uint16List? cellAt(int column, int row) {
    if (column < 0 || row < 0 || column >= columns || row >= rows) {
      return null;
    }
    return cells[row * columns + column];
  }
}

/// All map lumps for a single level, already validated against limits.
class MapData {
  const MapData({
    required this.name,
    required this.vertices,
    required this.linedefs,
    required this.sidedefs,
    required this.sectors,
    required this.segs,
    required this.subsectors,
    required this.nodes,
    required this.things,
    required this.blockmap,
    required this.reject,
  });

  final String name;
  final List<MapVertex> vertices;
  final List<Linedef> linedefs;
  final List<Sidedef> sidedefs;
  final List<Sector> sectors;
  final List<Seg> segs;
  final List<Subsector> subsectors;
  final List<BspNode> nodes;
  final List<Thing> things;
  final Blockmap? blockmap;
  final Uint8List? reject;

  /// Reads and validates [mapName] from [set]. See loadMapData for the rules
  /// applied to malformed input.
  static MapData load(
    WadSet set,
    String mapName, {
    DoomLimits limits = DoomLimits.defaults,
  }) => loadMapData(set, mapName, limits: limits);

  bool get hasBsp =>
      nodes.isNotEmpty && subsectors.isNotEmpty && segs.isNotEmpty;

  /// Root node index for BSP traversal; vanilla stores the root last.
  int get bspRoot => nodes.length - 1;
}
