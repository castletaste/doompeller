import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_geometry/src/wad_types.dart';

/// Test-only map construction: a small map DSL plus a vanilla-shaped node
/// builder.
///
/// The node builder is the important part. It deliberately reproduces the
/// property that makes M2 hard: **minisegs are not emitted**. Only segments
/// lying on real linedefs end up in SEGS, exactly as vanilla's builder did, so
/// subsector polygons genuinely cannot be closed from segs alone and the BSP
/// clipper is tested against the real problem rather than a friendly one.

/// Mutable map under construction.
class MapBuilder {
  MapBuilder(this.name);

  final String name;
  final List<MapVertex> vertices = <MapVertex>[];
  final List<Linedef> linedefs = <Linedef>[];
  final List<Sidedef> sidedefs = <Sidedef>[];
  final List<Sector> sectors = <Sector>[];
  final List<Thing> things = <Thing>[];

  final Map<int, int> _vertexLookup = <int, int>{};

  /// Adds a vertex, reusing an existing one at the same integer position.
  int vertex(int x, int y) {
    final int key = (x + 32768) * 65536 + (y + 32768);
    final int? existing = _vertexLookup[key];
    if (existing != null) {
      return existing;
    }
    vertices.add(MapVertex(x, y));
    _vertexLookup[key] = vertices.length - 1;
    return vertices.length - 1;
  }

  int sector({
    int floorHeight = 0,
    int ceilingHeight = 128,
    String floorFlat = 'FLOOR0_1',
    String ceilingFlat = 'CEIL1_1',
    int lightLevel = 160,
    int special = 0,
    int tag = 0,
  }) {
    sectors.add(
      Sector(
        floorHeight: floorHeight,
        ceilingHeight: ceilingHeight,
        floorFlat: floorFlat,
        ceilingFlat: ceilingFlat,
        lightLevel: lightLevel,
        special: special,
        tag: tag,
      ),
    );
    return sectors.length - 1;
  }

  int sidedef({
    required int sector,
    int xOffset = 0,
    int yOffset = 0,
    String upper = '-',
    String lower = '-',
    String middle = '-',
  }) {
    sidedefs.add(
      Sidedef(
        xOffset: xOffset,
        yOffset: yOffset,
        upperTexture: upper,
        lowerTexture: lower,
        middleTexture: middle,
        sector: sector,
      ),
    );
    return sidedefs.length - 1;
  }

  int line({
    required int v1,
    required int v2,
    required int right,
    int left = kNoSidedef,
    int flags = 0,
    int special = 0,
    int tag = 0,
  }) {
    final int resolved = left == kNoSidedef
        ? flags
        : flags | LinedefFlags.twoSided;
    linedefs.add(
      Linedef(
        v1: v1,
        v2: v2,
        flags: resolved,
        special: special,
        tag: tag,
        rightSidedef: right,
        leftSidedef: left,
      ),
    );
    return linedefs.length - 1;
  }

  /// Walks a closed ring of points as one-sided walls around [sector].
  ///
  /// Vanilla puts a one-sided line's sector on its RIGHT. In a y-up frame the
  /// right of a direction (dx, dy) is (dy, -dx), so an outer boundary whose
  /// interior is on the right is wound CLOCKWISE. Callers may pass points in
  /// either order; the ring is reoriented here so the map is always valid.
  void solidLoop(
    List<int> points,
    int sector, {
    String middle = 'STARTAN3',
    int xOffset = 0,
    int yOffset = 0,
    int flags = 0,
  }) {
    final List<int> ring = _oriented(points, clockwise: true);
    final int count = ring.length ~/ 2;
    for (var i = 0; i < count; i++) {
      final int j = (i + 1) % count;
      final int a = vertex(ring[i * 2], ring[i * 2 + 1]);
      final int b = vertex(ring[j * 2], ring[j * 2 + 1]);
      final int side = sidedef(
        sector: sector,
        middle: middle,
        xOffset: xOffset,
        yOffset: yOffset,
      );
      line(v1: a, v2: b, right: side, flags: flags | LinedefFlags.blocking);
    }
  }

  /// Two-sided ring separating [frontSector] from [backSector].
  ///
  /// The front side is on the right, so with [frontEnclosed] false the ring
  /// encloses [backSector] (the pillar-in-a-room case, wound counter-clockwise)
  /// and with it true the ring encloses [frontSector] instead.
  void twoSidedLoop(
    List<int> points,
    int frontSector,
    int backSector, {
    String upper = 'STARTAN3',
    String lower = 'STARTAN3',
    String middle = '-',
    int flags = 0,
    int xOffset = 0,
    int yOffset = 0,
    bool frontEnclosed = false,
  }) {
    final List<int> ring = _oriented(points, clockwise: frontEnclosed);
    final int count = ring.length ~/ 2;
    for (var i = 0; i < count; i++) {
      final int j = (i + 1) % count;
      final int a = vertex(ring[i * 2], ring[i * 2 + 1]);
      final int b = vertex(ring[j * 2], ring[j * 2 + 1]);
      final int front = sidedef(
        sector: frontSector,
        upper: upper,
        lower: lower,
        middle: middle,
        xOffset: xOffset,
        yOffset: yOffset,
      );
      final int back = sidedef(
        sector: backSector,
        upper: upper,
        lower: lower,
        middle: middle,
        xOffset: xOffset,
        yOffset: yOffset,
      );
      line(v1: a, v2: b, right: front, left: back, flags: flags);
    }
  }

  /// Returns [points] wound the requested way.
  static List<int> _oriented(List<int> points, {required bool clockwise}) {
    final int count = points.length ~/ 2;
    var twiceArea = 0;
    for (var i = 0; i < count; i++) {
      final int j = (i + 1) % count;
      twiceArea +=
          points[i * 2] * points[j * 2 + 1] - points[j * 2] * points[i * 2 + 1];
    }
    final bool isClockwise = twiceArea < 0;
    if (isClockwise == clockwise) {
      return points;
    }
    final List<int> out = <int>[];
    for (var i = count - 1; i >= 0; i--) {
      out.add(points[i * 2]);
      out.add(points[i * 2 + 1]);
    }
    return out;
  }

  void thing(int x, int y, {int angle = 0, int type = 1, int flags = 7}) {
    things.add(Thing(x: x, y: y, angle: angle, type: type, flags: flags));
  }

  /// Finishes the map, running the node builder to produce SEGS/SSECTORS/NODES.
  MapData build({bool buildNodes = true}) {
    if (!buildNodes) {
      return MapData(
        name: name,
        vertices: List<MapVertex>.unmodifiable(vertices),
        linedefs: List<Linedef>.unmodifiable(linedefs),
        sidedefs: List<Sidedef>.unmodifiable(sidedefs),
        sectors: List<Sector>.unmodifiable(sectors),
        segs: const <Seg>[],
        subsectors: const <Subsector>[],
        nodes: const <BspNode>[],
        things: List<Thing>.unmodifiable(things),
        blockmap: null,
        reject: null,
      );
    }
    return NodeBuilder(this).build();
  }
}

/// A segment during node building, before it is frozen into a [Seg].
class _WorkSeg {
  _WorkSeg({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.linedef,
    required this.side,
    required this.offset,
  });

  double x1;
  double y1;
  double x2;
  double y2;
  final int linedef;
  final int side;

  /// Distance from the linedef's start vertex to this segment's start.
  double offset;

  double get dx => x2 - x1;
  double get dy => y2 - y1;
  double get length => math.sqrt(dx * dx + dy * dy);
}

/// Minimal BSP node builder producing vanilla-shaped lumps.
///
/// Partition candidates are the segs themselves, scored by how evenly they
/// split the remaining set and how many segs they cut. Segments straddling the
/// partition are split; segments lying exactly on it are assigned by facing.
///
/// It does NOT emit minisegs. That is the point: the resulting SSECTORS have
/// open seg chains, exactly like vanilla, so the geometry compiler has to
/// recover the closing edges from the partition planes.
class NodeBuilder {
  NodeBuilder(this.builder);

  final MapBuilder builder;

  final List<Seg> _segs = <Seg>[];
  final List<Subsector> _subsectors = <Subsector>[];
  final List<BspNode> _nodes = <BspNode>[];

  MapData build() {
    final List<_WorkSeg> initial = <_WorkSeg>[];
    for (var i = 0; i < builder.linedefs.length; i++) {
      final Linedef line = builder.linedefs[i];
      if (line.v1 >= builder.vertices.length ||
          line.v2 >= builder.vertices.length) {
        continue;
      }
      final MapVertex a = builder.vertices[line.v1];
      final MapVertex b = builder.vertices[line.v2];
      if (a.x == b.x && a.y == b.y) {
        continue;
      }
      if (line.rightSidedef != kNoSidedef) {
        initial.add(
          _WorkSeg(
            x1: a.x.toDouble(),
            y1: a.y.toDouble(),
            x2: b.x.toDouble(),
            y2: b.y.toDouble(),
            linedef: i,
            side: 0,
            offset: 0,
          ),
        );
      }
      if (line.leftSidedef != kNoSidedef) {
        initial.add(
          _WorkSeg(
            x1: b.x.toDouble(),
            y1: b.y.toDouble(),
            x2: a.x.toDouble(),
            y2: a.y.toDouble(),
            linedef: i,
            side: 1,
            offset: 0,
          ),
        );
      }
    }

    final int rootWord = initial.isEmpty
        ? _emitSubsector(<_WorkSeg>[])
        : _partition(initial, 0);
    // Vanilla stores the root last; when the whole map is one leaf there are no
    // nodes at all and MapData.hasBsp stays false, which is itself a case worth
    // testing.
    final int rootIndex = rootWord & ~kSubsectorBit;
    if (_nodes.isEmpty && (rootWord & kSubsectorBit) != 0 && rootIndex == 0) {
      // single subsector, no nodes
    }
    return MapData(
      name: builder.name,
      vertices: List<MapVertex>.unmodifiable(builder.vertices),
      linedefs: List<Linedef>.unmodifiable(builder.linedefs),
      sidedefs: List<Sidedef>.unmodifiable(builder.sidedefs),
      sectors: List<Sector>.unmodifiable(builder.sectors),
      segs: List<Seg>.unmodifiable(_segs),
      subsectors: List<Subsector>.unmodifiable(_subsectors),
      nodes: List<BspNode>.unmodifiable(_nodes),
      things: List<Thing>.unmodifiable(builder.things),
      blockmap: null,
      reject: null,
    );
  }

  /// Returns a child word: either a node index or a subsector with the bit set.
  int _partition(List<_WorkSeg> segs, int depth) {
    if (segs.isEmpty) {
      return _emitSubsector(segs);
    }
    final int chosen = depth > 64 ? -1 : _chooseSplitter(segs);
    if (chosen < 0) {
      return _emitSubsector(segs);
    }
    final _WorkSeg splitter = segs[chosen];
    final double px = splitter.x1;
    final double py = splitter.y1;
    final double pdx = splitter.dx;
    final double pdy = splitter.dy;

    final List<_WorkSeg> right = <_WorkSeg>[];
    final List<_WorkSeg> left = <_WorkSeg>[];
    for (var i = 0; i < segs.length; i++) {
      _classify(segs[i], px, py, pdx, pdy, right, left);
    }
    if (right.isEmpty || left.isEmpty) {
      return _emitSubsector(segs);
    }

    final int rightChild = _partition(right, depth + 1);
    final int leftChild = _partition(left, depth + 1);
    _nodes.add(
      BspNode(
        x: px.round(),
        y: py.round(),
        dx: pdx.round(),
        dy: pdy.round(),
        rightBox: _bounds(right),
        leftBox: _bounds(left),
        rightChild: rightChild,
        leftChild: leftChild,
      ),
    );
    return _nodes.length - 1;
  }

  /// Picks the seg that splits the set most evenly while cutting the fewest
  /// other segs. Same objective as a real builder, just brute-forced.
  int _chooseSplitter(List<_WorkSeg> segs) {
    var best = -1;
    var bestCost = double.infinity;
    final int limit = segs.length < 48 ? segs.length : 48;
    for (var i = 0; i < limit; i++) {
      final _WorkSeg cand = segs[i];
      final double px = cand.x1;
      final double py = cand.y1;
      final double pdx = cand.dx;
      final double pdy = cand.dy;
      if (pdx == 0 && pdy == 0) {
        continue;
      }
      var rightCount = 0;
      var leftCount = 0;
      var splits = 0;
      for (var j = 0; j < segs.length; j++) {
        final _WorkSeg other = segs[j];
        final double d1 = _side(other.x1, other.y1, px, py, pdx, pdy);
        final double d2 = _side(other.x2, other.y2, px, py, pdx, pdy);
        if (d1 > _eps && d2 < -_eps || d1 < -_eps && d2 > _eps) {
          splits++;
          rightCount++;
          leftCount++;
        } else if (d1 > _eps || d2 > _eps) {
          rightCount++;
        } else if (d1 < -_eps || d2 < -_eps) {
          leftCount++;
        } else {
          // Collinear: goes with the side it faces.
          if (other.dx * pdx + other.dy * pdy > 0) {
            rightCount++;
          } else {
            leftCount++;
          }
        }
      }
      if (rightCount == 0 || leftCount == 0) {
        continue;
      }
      final double cost =
          (rightCount - leftCount).abs().toDouble() + splits * 8.0;
      if (cost < bestCost) {
        bestCost = cost;
        best = i;
      }
    }
    return best;
  }

  void _classify(
    _WorkSeg seg,
    double px,
    double py,
    double pdx,
    double pdy,
    List<_WorkSeg> right,
    List<_WorkSeg> left,
  ) {
    final double d1 = _side(seg.x1, seg.y1, px, py, pdx, pdy);
    final double d2 = _side(seg.x2, seg.y2, px, py, pdx, pdy);
    final bool straddles =
        (d1 > _eps && d2 < -_eps) || (d1 < -_eps && d2 > _eps);
    if (straddles) {
      final double t = d1 / (d1 - d2);
      final double ix = seg.x1 + (seg.x2 - seg.x1) * t;
      final double iy = seg.y1 + (seg.y2 - seg.y1) * t;
      final double firstLen = math.sqrt(
        (ix - seg.x1) * (ix - seg.x1) + (iy - seg.y1) * (iy - seg.y1),
      );
      final _WorkSeg tail = _WorkSeg(
        x1: ix,
        y1: iy,
        x2: seg.x2,
        y2: seg.y2,
        linedef: seg.linedef,
        side: seg.side,
        offset: seg.offset + firstLen,
      );
      final _WorkSeg head = _WorkSeg(
        x1: seg.x1,
        y1: seg.y1,
        x2: ix,
        y2: iy,
        linedef: seg.linedef,
        side: seg.side,
        offset: seg.offset,
      );
      if (d1 > 0) {
        right.add(head);
        left.add(tail);
      } else {
        left.add(head);
        right.add(tail);
      }
      return;
    }
    if (d1 > _eps || d2 > _eps) {
      right.add(seg);
    } else if (d1 < -_eps || d2 < -_eps) {
      left.add(seg);
    } else if (seg.dx * pdx + seg.dy * pdy > 0) {
      right.add(seg);
    } else {
      left.add(seg);
    }
  }

  int _emitSubsector(List<_WorkSeg> segs) {
    final int first = _segs.length;
    for (var i = 0; i < segs.length; i++) {
      final _WorkSeg s = segs[i];
      final int v1 = _internVertex(s.x1, s.y1);
      final int v2 = _internVertex(s.x2, s.y2);
      _segs.add(
        Seg(
          v1: v1,
          v2: v2,
          angle: _bamAngle(s.dx, s.dy),
          linedef: s.linedef,
          side: s.side,
          offset: s.offset.round(),
        ),
      );
    }
    _subsectors.add(Subsector(segCount: segs.length, firstSeg: first));
    return (_subsectors.length - 1) | kSubsectorBit;
  }

  /// Split points become new map vertices, matching how a real builder appends
  /// to VERTEXES.
  int _internVertex(double x, double y) {
    final int ix = x.round();
    final int iy = y.round();
    for (var i = 0; i < builder.vertices.length; i++) {
      final MapVertex v = builder.vertices[i];
      if (v.x == ix && v.y == iy) {
        return i;
      }
    }
    builder.vertices.add(MapVertex(ix, iy));
    return builder.vertices.length - 1;
  }

  static int _bamAngle(double dx, double dy) {
    final double radians = math.atan2(dy, dx);
    final int bam = (radians / (2 * math.pi) * 65536.0).round() & 0xFFFF;
    return bam;
  }

  static Int16List _bounds(List<_WorkSeg> segs) {
    var top = -32768.0;
    var bottom = 32767.0;
    var left = 32767.0;
    var right = -32768.0;
    for (var i = 0; i < segs.length; i++) {
      final _WorkSeg s = segs[i];
      top = math.max(top, math.max(s.y1, s.y2));
      bottom = math.min(bottom, math.min(s.y1, s.y2));
      left = math.min(left, math.min(s.x1, s.x2));
      right = math.max(right, math.max(s.x1, s.x2));
    }
    final Int16List box = Int16List(4);
    box[0] = top.round();
    box[1] = bottom.round();
    box[2] = left.round();
    box[3] = right.round();
    return box;
  }

  /// Positive on the right/front side, matching the package-wide convention.
  static double _side(
    double x,
    double y,
    double px,
    double py,
    double pdx,
    double pdy,
  ) => (x - px) * pdy - (y - py) * pdx;

  static const double _eps = 0.01;
}
