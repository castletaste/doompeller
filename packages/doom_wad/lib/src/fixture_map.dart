import 'dart:typed_data';

import 'bsp_builder.dart';
import 'map_loader.dart';
import 'map_model.dart';
import 'resources_model.dart';
import 'wad.dart';

/// The serialised map lumps of the fixture level.
class FixtureMapLumps {
  const FixtureMapLumps({
    required this.things,
    required this.linedefs,
    required this.sidedefs,
    required this.vertexes,
    required this.segs,
    required this.ssectors,
    required this.nodes,
    required this.sectors,
    required this.reject,
    required this.blockmap,
  });

  final Uint8List things;
  final Uint8List linedefs;
  final Uint8List sidedefs;
  final Uint8List vertexes;
  final Uint8List segs;
  final Uint8List ssectors;
  final Uint8List nodes;
  final Uint8List sectors;
  final Uint8List reject;
  final Uint8List blockmap;
}

/// Geometry of the fixture level, before serialisation.
///
/// The layout is four rooms in a row, each 256 units deep, sharing walls so
/// that every awkward case a geometry compiler has to survive is present:
///
///  * Sector 0, x 0..256: a plain convex box. The baseline case.
///  * Sector 1, x 256..512: an L, made concave by a notch cut out of its
///    top-right corner, so fan triangulation of the sector fails.
///  * Sector 2, x 512..768: a box containing sector 3 as an island, so the
///    floor has a hole and the outer sector's boundary has two loops.
///  * Sector 3: the island, raised well above sector 2's floor.
///  * Sector 4, x 768..1024: a sky room whose ceiling flat is F_SKY1.
///
/// Adjacent rooms are joined by two-sided linedefs with differing floor and
/// ceiling heights, which is what forces upper and lower wall bands to exist.
///
/// Winding matters and is easy to get backwards. A linedef's front (right)
/// side is the half-plane where
/// (x - v1.x) * dy - (y - v1.y) * dx is positive, which for a line pointing
/// along +Y is the +X side. Because a sidedef names the sector its own side
/// faces, every loop below is wound so that the front side looks INTO the
/// sector: clockwise for an outer boundary, and the same direction for an
/// island, whose "interior" is the island itself. Reversing a loop silently
/// produces a map whose BSP leaves report the wrong sector.
class FixtureGeometry {
  FixtureGeometry._(
    this.vertices,
    this.linedefs,
    this.sidedefs,
    this.sectors,
    this.things,
  );

  final List<MapVertex> vertices;
  final List<Linedef> linedefs;
  final List<Sidedef> sidedefs;
  final List<Sector> sectors;
  final List<Thing> things;

  /// Builds the level geometry. Deterministic: no randomness, no iteration over
  /// unordered collections.
  static FixtureGeometry build() {
    final _Builder builder = _Builder();

    // Sector 0: convex box, normal floor and ceiling.
    builder.addSector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'FLOOR0',
      ceilingFlat: 'CEIL0',
      lightLevel: 192,
    );
    // Sector 1: concave L, floor a step up and a lower ceiling.
    builder.addSector(
      floorHeight: 16,
      ceilingHeight: 112,
      floorFlat: 'FLAT1',
      ceilingFlat: 'CEIL0',
      lightLevel: 160,
    );
    // Sector 2: the room with a hole in its floor.
    builder.addSector(
      floorHeight: -32,
      ceilingHeight: 160,
      floorFlat: 'FLOOR0',
      ceilingFlat: 'CEIL0',
      lightLevel: 144,
    );
    // Sector 3: the island inside sector 2.
    builder.addSector(
      floorHeight: 48,
      ceilingHeight: 160,
      floorFlat: 'FLAT1',
      ceilingFlat: 'CEIL0',
      lightLevel: 208,
    );
    // Sector 4: open to the sky.
    builder.addSector(
      floorHeight: 0,
      ceilingHeight: 256,
      floorFlat: 'FLOOR0',
      ceilingFlat: kSkyFlatName,
      lightLevel: 255,
    );

    // Sector 0: a closed box. Edge 2 is the wall shared with sector 1.
    builder.solidLoop(<List<int>>[
      <int>[0, 0],
      <int>[0, 256],
      <int>[256, 256],
      <int>[256, 0],
    ], sector: 0, texture: 'WALL1', skipEdge: 2);
    // Shared wall 0 <-> 1, two-sided with a floor step and ceiling drop.
    builder.portal(
      from: <int>[256, 256],
      to: <int>[256, 0],
      frontSector: 0,
      backSector: 1,
      upper: 'WALL2',
      lower: 'WALL2',
    );

    // Sector 1: concave L. The notch is cut from the top-right, so the sector
    // boundary turns inward and no single fan covers it. Edge 3 is the portal
    // to sector 2 and edge 5 is the wall sector 0 already contributed.
    builder.solidLoop(<List<int>>[
      <int>[256, 256],
      <int>[384, 256],
      <int>[384, 160],
      <int>[512, 160],
      <int>[512, 0],
      <int>[256, 0],
    ], sector: 1, texture: 'WALL2', skipEdge: 3, skipSecondEdge: 5);
    // Shared wall 1 <-> 2 occupies the lower part of the x = 512 boundary.
    builder.portal(
      from: <int>[512, 160],
      to: <int>[512, 0],
      frontSector: 1,
      backSector: 2,
      upper: 'WALL1',
      lower: 'WALL1',
    );

    // Sector 2: outer box of the hole room. The left wall is split at y = 160
    // so only its lower half is a portal, which gives the sector a boundary
    // made of several separate linedef runs. Edge 0 is that portal (already
    // built by sector 1) and edge 3 is the portal to sector 4.
    builder.solidLoop(<List<int>>[
      <int>[512, 0],
      <int>[512, 160],
      <int>[512, 256],
      <int>[768, 256],
      <int>[768, 0],
    ], sector: 2, texture: 'WALL3', skipEdge: 0, skipSecondEdge: 3);
    // Shared wall 2 <-> 4.
    builder.portal(
      from: <int>[768, 256],
      to: <int>[768, 0],
      frontSector: 2,
      backSector: 4,
      upper: 'WALL3',
      lower: 'WALL3',
    );

    // Sector 3: the island. Wound clockwise so its front faces inward, which is
    // how a hole in a sector floor is expressed.
    builder.portalLoop(<List<int>>[
      <int>[576, 64],
      <int>[576, 192],
      <int>[704, 192],
      <int>[704, 64],
    ], innerSector: 3, outerSector: 2, upper: 'WALL1', lower: 'WALL2');

    // Sector 4: sky room, closed on three sides. Edge 0 is the portal back to
    // sector 2, already built above.
    builder.solidLoop(<List<int>>[
      <int>[768, 0],
      <int>[768, 256],
      <int>[1024, 256],
      <int>[1024, 0],
    ], sector: 4, texture: 'WALL1', skipEdge: 0);

    // Player 1 start, a co-op start, and two pickups spread across the rooms.
    builder.addThing(x: 128, y: 128, angle: 90, type: 1, flags: 7);
    builder.addThing(x: 384, y: 64, angle: 180, type: 2, flags: 7);
    builder.addThing(x: 640, y: 128, angle: 0, type: 2014, flags: 7);
    builder.addThing(x: 896, y: 128, angle: 270, type: 2015, flags: 7);

    return FixtureGeometry._(
      builder.vertices,
      builder.linedefs,
      builder.sidedefs,
      builder.sectors,
      builder.things,
    );
  }
}

class _Builder {
  final List<MapVertex> vertices = <MapVertex>[];
  final List<Linedef> linedefs = <Linedef>[];
  final List<Sidedef> sidedefs = <Sidedef>[];
  final List<Sector> sectors = <Sector>[];
  final List<Thing> things = <Thing>[];
  final Map<int, int> _vertexIds = <int, int>{};

  /// Interns a vertex so shared corners resolve to one index.
  int vertex(int x, int y) {
    // Coordinates fit well inside 16 bits, so pack them into one key.
    final int key = ((x & 0xFFFF) << 16) | (y & 0xFFFF);
    final int? existing = _vertexIds[key];
    if (existing != null) {
      return existing;
    }
    vertices.add(MapVertex(x, y));
    final int index = vertices.length - 1;
    _vertexIds[key] = index;
    return index;
  }

  void addSector({
    required int floorHeight,
    required int ceilingHeight,
    required String floorFlat,
    required String ceilingFlat,
    required int lightLevel,
  }) {
    sectors.add(
      Sector(
        floorHeight: floorHeight,
        ceilingHeight: ceilingHeight,
        floorFlat: floorFlat,
        ceilingFlat: ceilingFlat,
        lightLevel: lightLevel,
        special: 0,
        tag: 0,
      ),
    );
  }

  void addThing({
    required int x,
    required int y,
    required int angle,
    required int type,
    required int flags,
  }) {
    things.add(Thing(x: x, y: y, angle: angle, type: type, flags: flags));
  }

  int addSidedef(int sector, {String upper = '-', String lower = '-', String middle = '-'}) {
    sidedefs.add(
      Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: upper,
        lowerTexture: lower,
        middleTexture: middle,
        sector: sector,
      ),
    );
    return sidedefs.length - 1;
  }

  /// Adds a one-sided wall from [a] to [b].
  void solidLine(List<int> a, List<int> b, int sector, String texture) {
    final int right = addSidedef(sector, middle: texture);
    linedefs.add(
      Linedef(
        v1: vertex(a[0], a[1]),
        v2: vertex(b[0], b[1]),
        flags: LinedefFlags.blocking,
        special: 0,
        tag: 0,
        rightSidedef: right,
        leftSidedef: kNoSidedef,
      ),
    );
  }

  /// Walls a closed loop of points, optionally skipping edges that a portal
  /// will cover instead. Edge n runs from point n to point n + 1.
  void solidLoop(
    List<List<int>> points, {
    required int sector,
    required String texture,
    int skipEdge = -1,
    int skipSecondEdge = -1,
  }) {
    for (var i = 0; i < points.length; i++) {
      if (i == skipEdge || i == skipSecondEdge) {
        continue;
      }
      solidLine(points[i], points[(i + 1) % points.length], sector, texture);
    }
  }

  /// Adds a two-sided linedef joining two sectors.
  void portal({
    required List<int> from,
    required List<int> to,
    required int frontSector,
    required int backSector,
    required String upper,
    required String lower,
  }) {
    final int right = addSidedef(frontSector, upper: upper, lower: lower);
    final int left = addSidedef(backSector, upper: upper, lower: lower);
    linedefs.add(
      Linedef(
        v1: vertex(from[0], from[1]),
        v2: vertex(to[0], to[1]),
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: right,
        leftSidedef: left,
      ),
    );
  }

  /// Rings [points] with two-sided linedefs so [innerSector] sits as an island
  /// inside [outerSector].
  void portalLoop(
    List<List<int>> points, {
    required int innerSector,
    required int outerSector,
    required String upper,
    required String lower,
  }) {
    for (var i = 0; i < points.length; i++) {
      portal(
        from: points[i],
        to: points[(i + 1) % points.length],
        frontSector: innerSector,
        backSector: outerSector,
        upper: upper,
        lower: lower,
      );
    }
  }
}

/// Builds every map lump of the fixture level, BSP tree included.
FixtureMapLumps buildFixtureMapLumps() {
  final FixtureGeometry geometry = FixtureGeometry.build();

  // One seg per sidedef: the front side runs along the linedef, the back side
  // runs against it. This is what a node builder starts from.
  final List<BspSeg> input = <BspSeg>[];
  for (var i = 0; i < geometry.linedefs.length; i++) {
    final Linedef line = geometry.linedefs[i];
    final MapVertex a = geometry.vertices[line.v1];
    final MapVertex b = geometry.vertices[line.v2];
    input.add(BspSeg(x1: a.x, y1: a.y, x2: b.x, y2: b.y, linedef: i, side: 0));
    if (line.leftSidedef != kNoSidedef) {
      input.add(BspSeg(x1: b.x, y1: b.y, x2: a.x, y2: a.y, linedef: i, side: 1));
    }
  }

  final BspTree tree = buildBspTree(input);

  // Splitting introduces new points, so vertices grow while segs are written.
  final List<MapVertex> vertices = List<MapVertex>.of(geometry.vertices);
  final Map<int, int> vertexIds = <int, int>{};
  for (var i = 0; i < vertices.length; i++) {
    vertexIds[((vertices[i].x & 0xFFFF) << 16) | (vertices[i].y & 0xFFFF)] = i;
  }
  int internVertex(int x, int y) {
    final int key = ((x & 0xFFFF) << 16) | (y & 0xFFFF);
    final int? existing = vertexIds[key];
    if (existing != null) {
      return existing;
    }
    vertices.add(MapVertex(x, y));
    final int index = vertices.length - 1;
    vertexIds[key] = index;
    return index;
  }

  final Uint8List segs = Uint8List(tree.segs.length * kSegBytes);
  final ByteData segView = ByteData.sublistView(segs);
  for (var i = 0; i < tree.segs.length; i++) {
    final BspSeg seg = tree.segs[i];
    final Linedef line = geometry.linedefs[seg.linedef];
    // The offset is the distance from the seg's start back to the start of the
    // side of the linedef it belongs to, which is how texture u is anchored.
    final MapVertex anchor =
        seg.side == 0 ? geometry.vertices[line.v1] : geometry.vertices[line.v2];
    final int o = i * kSegBytes;
    segView.setUint16(o, internVertex(seg.x1, seg.y1), Endian.little);
    segView.setUint16(o + 2, internVertex(seg.x2, seg.y2), Endian.little);
    segView.setUint16(o + 4, bamAngle(seg.dx, seg.dy), Endian.little);
    segView.setUint16(o + 6, seg.linedef, Endian.little);
    segView.setUint16(o + 8, seg.side, Endian.little);
    segView.setInt16(o + 10, distanceBetween(anchor.x, anchor.y, seg.x1, seg.y1), Endian.little);
  }

  final Uint8List ssectors = Uint8List(tree.subsectors.length * kSubsectorBytes);
  final ByteData ssectorView = ByteData.sublistView(ssectors);
  for (var i = 0; i < tree.subsectors.length; i++) {
    ssectorView.setUint16(i * kSubsectorBytes, tree.subsectors[i].segCount, Endian.little);
    ssectorView.setUint16(i * kSubsectorBytes + 2, tree.subsectors[i].firstSeg, Endian.little);
  }

  final Uint8List nodes = Uint8List(tree.nodes.length * kNodeBytes);
  final ByteData nodeView = ByteData.sublistView(nodes);
  for (var i = 0; i < tree.nodes.length; i++) {
    final BspNodeOut node = tree.nodes[i];
    final int o = i * kNodeBytes;
    nodeView.setInt16(o, node.x, Endian.little);
    nodeView.setInt16(o + 2, node.y, Endian.little);
    nodeView.setInt16(o + 4, node.dx, Endian.little);
    nodeView.setInt16(o + 6, node.dy, Endian.little);
    for (var b = 0; b < 4; b++) {
      nodeView.setInt16(o + 8 + b * 2, node.rightBox[b], Endian.little);
      nodeView.setInt16(o + 16 + b * 2, node.leftBox[b], Endian.little);
    }
    nodeView.setUint16(o + 24, node.rightChild, Endian.little);
    nodeView.setUint16(o + 26, node.leftChild, Endian.little);
  }

  final Uint8List vertexes = Uint8List(vertices.length * kVertexBytes);
  final ByteData vertexView = ByteData.sublistView(vertexes);
  for (var i = 0; i < vertices.length; i++) {
    vertexView.setInt16(i * kVertexBytes, vertices[i].x, Endian.little);
    vertexView.setInt16(i * kVertexBytes + 2, vertices[i].y, Endian.little);
  }

  final Uint8List linedefs = Uint8List(geometry.linedefs.length * kLinedefBytes);
  final ByteData linedefView = ByteData.sublistView(linedefs);
  for (var i = 0; i < geometry.linedefs.length; i++) {
    final Linedef line = geometry.linedefs[i];
    final int o = i * kLinedefBytes;
    linedefView.setUint16(o, line.v1, Endian.little);
    linedefView.setUint16(o + 2, line.v2, Endian.little);
    linedefView.setUint16(o + 4, line.flags, Endian.little);
    linedefView.setUint16(o + 6, line.special, Endian.little);
    linedefView.setUint16(o + 8, line.tag, Endian.little);
    linedefView.setUint16(o + 10, line.rightSidedef & 0xFFFF, Endian.little);
    linedefView.setUint16(o + 12, line.leftSidedef & 0xFFFF, Endian.little);
  }

  final Uint8List sidedefs = Uint8List(geometry.sidedefs.length * kSidedefBytes);
  final ByteData sidedefView = ByteData.sublistView(sidedefs);
  for (var i = 0; i < geometry.sidedefs.length; i++) {
    final Sidedef side = geometry.sidedefs[i];
    final int o = i * kSidedefBytes;
    sidedefView.setInt16(o, side.xOffset, Endian.little);
    sidedefView.setInt16(o + 2, side.yOffset, Endian.little);
    encodeLumpName(sidedefs, o + 4, side.upperTexture);
    encodeLumpName(sidedefs, o + 12, side.lowerTexture);
    encodeLumpName(sidedefs, o + 20, side.middleTexture);
    sidedefView.setInt16(o + 28, side.sector, Endian.little);
  }

  final Uint8List sectors = Uint8List(geometry.sectors.length * kSectorBytes);
  final ByteData sectorView = ByteData.sublistView(sectors);
  for (var i = 0; i < geometry.sectors.length; i++) {
    final Sector sector = geometry.sectors[i];
    final int o = i * kSectorBytes;
    sectorView.setInt16(o, sector.floorHeight, Endian.little);
    sectorView.setInt16(o + 2, sector.ceilingHeight, Endian.little);
    encodeLumpName(sectors, o + 4, sector.floorFlat);
    encodeLumpName(sectors, o + 12, sector.ceilingFlat);
    sectorView.setInt16(o + 20, sector.lightLevel, Endian.little);
    sectorView.setInt16(o + 22, sector.special, Endian.little);
    sectorView.setInt16(o + 24, sector.tag, Endian.little);
  }

  final Uint8List things = Uint8List(geometry.things.length * kThingBytes);
  final ByteData thingView = ByteData.sublistView(things);
  for (var i = 0; i < geometry.things.length; i++) {
    final Thing thing = geometry.things[i];
    final int o = i * kThingBytes;
    thingView.setInt16(o, thing.x, Endian.little);
    thingView.setInt16(o + 2, thing.y, Endian.little);
    thingView.setInt16(o + 4, thing.angle, Endian.little);
    thingView.setUint16(o + 6, thing.type, Endian.little);
    thingView.setUint16(o + 8, thing.flags, Endian.little);
  }

  // All-zero REJECT: every sector pair is potentially visible.
  final int rejectBits = geometry.sectors.length * geometry.sectors.length;
  final Uint8List reject = Uint8List((rejectBits + 7) ~/ 8);

  return FixtureMapLumps(
    things: things,
    linedefs: linedefs,
    sidedefs: sidedefs,
    vertexes: vertexes,
    segs: segs,
    ssectors: ssectors,
    nodes: nodes,
    sectors: sectors,
    reject: reject,
    blockmap: buildFixtureBlockmap(vertices, geometry.linedefs),
  );
}

/// Builds a BLOCKMAP over [linedefs] in the vanilla layout.
///
/// A linedef is assigned to every 128x128 cell its bounding box touches, which
/// over-includes diagonal lines but never misses one, matching what vanilla
/// node builders emit.
Uint8List buildFixtureBlockmap(List<MapVertex> vertices, List<Linedef> linedefs) {
  var minX = 2147483647;
  var minY = 2147483647;
  var maxX = -2147483648;
  var maxY = -2147483648;
  for (final MapVertex v in vertices) {
    if (v.x < minX) minX = v.x;
    if (v.y < minY) minY = v.y;
    if (v.x > maxX) maxX = v.x;
    if (v.y > maxY) maxY = v.y;
  }
  // Vanilla insets the origin by 8 units so lines on the edge still land in a
  // cell.
  final int originX = minX - 8;
  final int originY = minY - 8;
  final int columns = (maxX - originX) ~/ Blockmap.blockSize + 1;
  final int rows = (maxY - originY) ~/ Blockmap.blockSize + 1;
  final int cellCount = columns * rows;

  final List<List<int>> cells = List<List<int>>.generate(
    cellCount,
    (int _) => <int>[],
    growable: false,
  );
  for (var i = 0; i < linedefs.length; i++) {
    final MapVertex a = vertices[linedefs[i].v1];
    final MapVertex b = vertices[linedefs[i].v2];
    final int c0 = (_min(a.x, b.x) - originX) ~/ Blockmap.blockSize;
    final int c1 = (_max(a.x, b.x) - originX) ~/ Blockmap.blockSize;
    final int r0 = (_min(a.y, b.y) - originY) ~/ Blockmap.blockSize;
    final int r1 = (_max(a.y, b.y) - originY) ~/ Blockmap.blockSize;
    for (var r = r0; r <= r1 && r < rows; r++) {
      for (var c = c0; c <= c1 && c < columns; c++) {
        cells[r * columns + c].add(i);
      }
    }
  }

  // Header is 4 words, then one offset word per cell, then the lists.
  var words = 4 + cellCount;
  for (final List<int> cell in cells) {
    words += cell.length + 2; // leading 0x0000 pad and trailing 0xFFFF
  }

  final Uint8List out = Uint8List(words * 2);
  final ByteData view = ByteData.sublistView(out);
  view.setInt16(0, originX, Endian.little);
  view.setInt16(2, originY, Endian.little);
  view.setUint16(4, columns, Endian.little);
  view.setUint16(6, rows, Endian.little);

  var cursor = 4 + cellCount;
  for (var i = 0; i < cellCount; i++) {
    view.setUint16(8 + i * 2, cursor, Endian.little);
    view.setUint16(cursor * 2, 0, Endian.little);
    cursor++;
    for (final int line in cells[i]) {
      view.setUint16(cursor * 2, line, Endian.little);
      cursor++;
    }
    view.setUint16(cursor * 2, 0xFFFF, Endian.little);
    cursor++;
  }
  return out;
}

int _min(int a, int b) => a < b ? a : b;
int _max(int a, int b) => a > b ? a : b;
