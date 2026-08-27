import 'package:doom_wad/doom_wad.dart';

import 'fixed.dart';
import 'sector_runtime.dart';

/// Derived, immutable map queries plus mutable sector state. All collections
/// preserve lump/index order, which is part of replay determinism.
class MapRuntime {
  MapRuntime(this.map)
    : sectors = List<SectorRuntime>.generate(
        map.sectors.length,
        (int i) => SectorRuntime(index: i, staticData: map.sectors[i]),
      ) {
    for (var sector = 0; sector < map.sectors.length; sector++) {
      _sectorIndicesByTag
          .putIfAbsent(map.sectors[sector].tag, () => <int>[])
          .add(sector);
    }
    for (int i = 0; i < map.linedefs.length; i++) {
      final Linedef line = map.linedefs[i];
      sectors[map.sidedefs[line.rightSidedef].sector].touchingLinedefs.add(i);
      if (line.leftSidedef != kNoSidedef) {
        sectors[map.sidedefs[line.leftSidedef].sector].touchingLinedefs.add(i);
      }
    }
  }
  final MapData map;
  final List<SectorRuntime> sectors;
  final Map<int, List<int>> _sectorIndicesByTag = <int, List<int>>{};

  /// Sector indices carrying [tag], in canonical map order.
  ///
  /// Tagged specials call this instead of rescanning every sector. The lists
  /// are built once with the other level-derived indices and never mutated
  /// after construction, preserving deterministic activation order.
  Iterable<int> sectorsWithTag(int tag) =>
      _sectorIndicesByTag[tag] ?? const <int>[];

  int frontSector(Linedef line) => map.sidedefs[line.rightSidedef].sector;
  int? backSector(Linedef line) => line.leftSidedef == kNoSidedef
      ? null
      : map.sidedefs[line.leftSidedef].sector;

  /// BSP answer when possible, with an explicit polygon/line fallback. A map
  /// can be playable without BLOCKMAP and even without BSP (synthetic tests).
  int sectorAt(int x, int y, {int fallback = 0}) {
    if (map.hasBsp) {
      int child = map.bspRoot;
      int guard = 0;
      while ((child & kSubsectorBit) == 0 && guard++ < map.nodes.length + 1) {
        if (child < 0 || child >= map.nodes.length) break;
        final BspNode node = map.nodes[child];
        final int side =
            (x - toFixed(node.x)) * node.dy - (y - toFixed(node.y)) * node.dx;
        child = side >= 0 ? node.rightChild : node.leftChild;
      }
      if ((child & kSubsectorBit) != 0) {
        final int ss = child & ~kSubsectorBit;
        if (ss >= 0 && ss < map.subsectors.length) {
          final Subsector subsector = map.subsectors[ss];
          if (subsector.segCount > 0) {
            final Seg seg = map.segs[subsector.firstSeg];
            final Linedef line = map.linedefs[seg.linedef];
            final int sideDef = seg.side == 0
                ? line.rightSidedef
                : line.leftSidedef;
            if (sideDef != kNoSidedef) return map.sidedefs[sideDef].sector;
          }
        }
      }
    }
    // Closest sidedef is a deterministic and useful fallback for small test maps.
    int best = fallback;
    int? bestDistance;
    for (final Linedef line in map.linedefs) {
      final MapVertex a = map.vertices[line.v1];
      final MapVertex b = map.vertices[line.v2];
      final int d = _distanceToSegmentQuantized(
        x,
        y,
        toFixed(a.x),
        toFixed(a.y),
        toFixed(b.x),
        toFixed(b.y),
      );
      if (bestDistance == null || d < bestDistance) {
        bestDistance = d;
        final int cross =
            (toFixed(b.x - a.x) * (y - toFixed(a.y))) -
            (toFixed(b.y - a.y) * (x - toFixed(a.x)));
        final int? back = backSector(line);
        best = cross <= 0 || back == null ? frontSector(line) : back;
      }
    }
    return best;
  }

  Iterable<int> candidateLines(int x, int y, int radius) sync* {
    final Blockmap? blockmap = map.blockmap;
    if (blockmap == null) {
      for (int i = 0; i < map.linedefs.length; i++) {
        yield i;
      }
      return;
    }
    if (blockmap.columns <= 0 ||
        blockmap.rows <= 0 ||
        blockmap.cells.length != blockmap.columns * blockmap.rows) {
      for (int i = 0; i < map.linedefs.length; i++) {
        yield i;
      }
      return;
    }
    final int minX = fixedToInt(x - radius);
    final int maxX = fixedToInt(x + radius);
    final int minY = fixedToInt(y - radius);
    final int maxY = fixedToInt(y + radius);
    final Set<int> seen = <int>{};
    for (
      int cy = _floorDiv(minY - blockmap.originY, Blockmap.blockSize);
      cy <= _floorDiv(maxY - blockmap.originY, Blockmap.blockSize);
      cy++
    ) {
      for (
        int cx = _floorDiv(minX - blockmap.originX, Blockmap.blockSize);
        cx <= _floorDiv(maxX - blockmap.originX, Blockmap.blockSize);
        cx++
      ) {
        final cells = blockmap.cellAt(cx, cy);
        if (cells == null) continue;
        for (final int line in cells) {
          if (line < 0 || line >= map.linedefs.length) continue;
          if (seen.add(line)) {
            yield line;
          }
        }
      }
    }
    // A non-null BLOCKMAP is advisory ordering, never collision authority.
    // It cannot prove that an omitted line is irrelevant: a syntactically
    // valid cell may still contain one unrelated line while omitting a wall.
    // Union with the loader-bounded canonical list for fail-closed correctness.
    // A future canonical spatial index may replace this O(n) safety union.
    for (int i = 0; i < map.linedefs.length; i++) {
      if (seen.add(i)) yield i;
    }
  }

  bool blocksAt(
    int lineIndex,
    int x,
    int y,
    int radius,
    int actorBottom,
    int actorHeight,
  ) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    if (!_circleTouchesSegment(
      x,
      y,
      toFixed(a.x),
      toFixed(a.y),
      toFixed(b.x),
      toFixed(b.y),
      radius,
    )) {
      return false;
    }
    return _lineBlocksActor(lineIndex, actorBottom, actorHeight);
  }

  /// Whether the actor circle's entire center path touches a blocking line.
  ///
  /// Destination-only collision can miss a chord through the rounded capsule
  /// at a linedef endpoint: both endpoints are legal while the path between
  /// them penetrates the actor radius. This uses a conservative 8.8 segment
  /// distance so the same result is exact on the Dart VM and Wasm.
  bool blocksAlongMove(
    int lineIndex,
    int fromX,
    int fromY,
    int toX,
    int toY,
    int radius,
    int actorBottom,
    int actorHeight,
  ) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    final int ax = toFixed(a.x);
    final int ay = toFixed(a.y);
    final int bx = toFixed(b.x);
    final int by = toFixed(b.y);
    final int moveMinX = (fromX < toX ? fromX : toX) - radius;
    final int moveMaxX = (fromX > toX ? fromX : toX) + radius;
    final int moveMinY = (fromY < toY ? fromY : toY) - radius;
    final int moveMaxY = (fromY > toY ? fromY : toY) + radius;
    if (moveMaxX < (ax < bx ? ax : bx) ||
        moveMinX > (ax > bx ? ax : bx) ||
        moveMaxY < (ay < by ? ay : by) ||
        moveMinY > (ay > by ? ay : by) ||
        !_lineBlocksActor(lineIndex, actorBottom, actorHeight)) {
      return false;
    }
    const int quantum = 1 << 8;
    final int scaledRadius = ((radius + quantum - 1) ~/ quantum) + 2;
    return _minimumSegmentDistanceQuantized(
          fromX,
          fromY,
          toX,
          toY,
          ax,
          ay,
          bx,
          by,
        ) <=
        scaledRadius;
  }

  /// Minimum center-path to linedef distance in 1/256 map-unit quanta.
  int minimumDistanceToLineAlongMoveQuantized(
    int lineIndex,
    int fromX,
    int fromY,
    int toX,
    int toY,
  ) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    return _minimumSegmentDistanceQuantized(
      fromX,
      fromY,
      toX,
      toY,
      toFixed(a.x),
      toFixed(a.y),
      toFixed(b.x),
      toFixed(b.y),
    );
  }

  bool _lineBlocksActor(int lineIndex, int actorBottom, int actorHeight) {
    final Linedef line = map.linedefs[lineIndex];
    if (line.blocksMovement || !line.isTwoSided) return true;
    final int front = frontSector(line);
    final int? back = backSector(line);
    if (back == null) return true;
    final SectorRuntime aSector = sectors[front];
    final SectorRuntime bSector = sectors[back];
    final int bottom = aSector.floorHeight > bSector.floorHeight
        ? aSector.floorHeight
        : bSector.floorHeight;
    final int top = aSector.ceilingHeight < bSector.ceilingHeight
        ? aSector.ceilingHeight
        : bSector.ceilingHeight;
    return top - bottom < actorHeight ||
        actorBottom < bottom - toFixed(24) ||
        actorBottom + actorHeight > top;
  }

  /// Point-to-linedef distance in 1/256 map-unit quanta.
  ///
  /// Movement uses this only to distinguish penetration from motion that is
  /// parallel to, or away from, a blocker the actor already touches. The
  /// quantized implementation shares the Wasm-safe arithmetic used by the
  /// conservative overlap predicate.
  int distanceToLineQuantized(int lineIndex, int x, int y) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    return _distanceToSegmentQuantized(
      x,
      y,
      toFixed(a.x),
      toFixed(a.y),
      toFixed(b.x),
      toFixed(b.y),
    );
  }

  /// Whether [x], [y] lies on the front/right side of a linedef.
  ///
  /// Doom one-sided walls own only a right sidedef, so a tangent slide may be
  /// relaxed only from this legal side. Quantizing before the cross product
  /// keeps the sign test below the exact-integer limit of Wasm numbers.
  bool isOnFrontSide(int lineIndex, int x, int y) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    const int quantum = 1 << 8;
    // Keep the line delta in map units. Shifting a possible 16-bit endpoint
    // delta through 16.16 would wrap at 32768 units before it is reduced to
    // 8.8, reversing the side on long valid WAD linedefs.
    final int lineX = b.x - a.x;
    final int lineY = b.y - a.y;
    final int pointX = (x - toFixed(a.x)) ~/ quantum;
    final int pointY = (y - toFixed(a.y)) ~/ quantum;
    return lineX * pointY - lineY * pointX <= 0;
  }

  ({int bottom, int top})? openingFor(int lineIndex) {
    final Linedef line = map.linedefs[lineIndex];
    final int? back = backSector(line);
    if (!line.isTwoSided || back == null) return null;
    final SectorRuntime front = sectors[frontSector(line)];
    final SectorRuntime rear = sectors[back];
    return (
      bottom: front.floorHeight > rear.floorHeight
          ? front.floorHeight
          : rear.floorHeight,
      top: front.ceilingHeight < rear.ceilingHeight
          ? front.ceilingHeight
          : rear.ceilingHeight,
    );
  }

  static int _floorDiv(int value, int divisor) {
    final int quotient = value ~/ divisor;
    return value < 0 && value % divisor != 0 ? quotient - 1 : quotient;
  }

  /// Approximate point/segment distance in 8.8 quanta for nearest-line
  /// ordering. Unlike the previous 16.16 projection, no numerator is shifted
  /// back into fixed point, so long fallback-map linedefs cannot overflow.
  static int _distanceToSegmentQuantized(
    int px,
    int py,
    int ax,
    int ay,
    int bx,
    int by,
  ) {
    const int quantum = 1 << 8;
    final int abx = (bx - ax) ~/ quantum;
    final int aby = (by - ay) ~/ quantum;
    final int apx = (px - ax) ~/ quantum;
    final int apy = (py - ay) ~/ quantum;
    final int bpx = (px - bx) ~/ quantum;
    final int bpy = (py - by) ~/ quantum;
    final int lengthSquared = abx * abx + aby * aby;
    if (lengthSquared == 0) {
      return _integerSqrtCeil(apx * apx + apy * apy);
    }
    final int projection = apx * abx + apy * aby;
    if (projection <= 0) {
      return _integerSqrtCeil(apx * apx + apy * apy);
    }
    if (projection >= lengthSquared) {
      return _integerSqrtCeil(bpx * bpx + bpy * bpy);
    }
    final int cross = (abx * apy - aby * apx).abs();
    final int length = _integerSqrtCeil(lengthSquared);
    return (cross + length - 1) ~/ length;
  }

  static int _minimumSegmentDistanceQuantized(
    int ax,
    int ay,
    int bx,
    int by,
    int cx,
    int cy,
    int dx,
    int dy,
  ) {
    if (_segmentsIntersectQuantized(ax, ay, bx, by, cx, cy, dx, dy)) {
      return 0;
    }
    int best = _distanceToSegmentQuantized(ax, ay, cx, cy, dx, dy);
    int distance = _distanceToSegmentQuantized(bx, by, cx, cy, dx, dy);
    if (distance < best) best = distance;
    distance = _distanceToSegmentQuantized(cx, cy, ax, ay, bx, by);
    if (distance < best) best = distance;
    distance = _distanceToSegmentQuantized(dx, dy, ax, ay, bx, by);
    return distance < best ? distance : best;
  }

  static bool _segmentsIntersectQuantized(
    int ax,
    int ay,
    int bx,
    int by,
    int cx,
    int cy,
    int dx,
    int dy,
  ) {
    const int quantum = 1 << 8;
    final int qax = ax ~/ quantum;
    final int qay = ay ~/ quantum;
    final int qbx = bx ~/ quantum;
    final int qby = by ~/ quantum;
    final int qcx = cx ~/ quantum;
    final int qcy = cy ~/ quantum;
    final int qdx = dx ~/ quantum;
    final int qdy = dy ~/ quantum;

    int side(int x1, int y1, int x2, int y2, int px, int py) =>
        (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1);
    bool between(int value, int first, int second) =>
        value >= (first < second ? first : second) &&
        value <= (first > second ? first : second);
    bool onSegment(int x1, int y1, int x2, int y2, int px, int py) =>
        between(px, x1, x2) && between(py, y1, y2);

    final int abC = side(qax, qay, qbx, qby, qcx, qcy);
    final int abD = side(qax, qay, qbx, qby, qdx, qdy);
    final int cdA = side(qcx, qcy, qdx, qdy, qax, qay);
    final int cdB = side(qcx, qcy, qdx, qdy, qbx, qby);
    if (abC == 0 && onSegment(qax, qay, qbx, qby, qcx, qcy)) return true;
    if (abD == 0 && onSegment(qax, qay, qbx, qby, qdx, qdy)) return true;
    if (cdA == 0 && onSegment(qcx, qcy, qdx, qdy, qax, qay)) return true;
    if (cdB == 0 && onSegment(qcx, qcy, qdx, qdy, qbx, qby)) return true;
    return ((abC < 0 && abD > 0) || (abC > 0 && abD < 0)) &&
        ((cdA < 0 && cdB > 0) || (cdA > 0 && cdB < 0));
  }

  /// Conservative circle/segment overlap without overflowing 16.16 products.
  ///
  /// A direct fixed-point projection needs `(dot << 16)` and overflows on
  /// ordinary long Doom linedefs. Collision only needs an overlap predicate,
  /// so coordinates are reduced to 8.8 precision and the perpendicular test
  /// compares `abs(cross)` with `radius * length`. Every intermediate stays
  /// below 2^53 even at the signed 16-bit map-coordinate limits, keeping the
  /// result identical on the Dart VM and Wasm.
  static bool _circleTouchesSegment(
    int px,
    int py,
    int ax,
    int ay,
    int bx,
    int by,
    int radius,
  ) {
    if (px + radius < (ax < bx ? ax : bx) ||
        px - radius > (ax > bx ? ax : bx) ||
        py + radius < (ay < by ? ay : by) ||
        py - radius > (ay > by ? ay : by)) {
      return false;
    }

    const int shift = 8;
    const int quantum = 1 << shift;
    final int abx = (bx - ax) ~/ quantum;
    final int aby = (by - ay) ~/ quantum;
    final int apx = (px - ax) ~/ quantum;
    final int apy = (py - ay) ~/ quantum;
    final int bpx = (px - bx) ~/ quantum;
    final int bpy = (py - by) ~/ quantum;
    // Two 8.8 quanta add an explicit ~0.008 map-unit safety margin. The
    // coordinate and radius reductions are conservative independently.
    final int scaledRadius = ((radius + quantum - 1) ~/ quantum) + 2;
    final int radiusSquared = scaledRadius * scaledRadius;
    final int lengthSquared = abx * abx + aby * aby;
    if (lengthSquared == 0) {
      return apx * apx + apy * apy <= radiusSquared;
    }
    final int projection = apx * abx + apy * aby;
    if (projection <= 0) {
      return apx * apx + apy * apy <= radiusSquared;
    }
    if (projection >= lengthSquared) {
      return bpx * bpx + bpy * bpy <= radiusSquared;
    }
    final int cross = abx * apy - aby * apx;
    return cross.abs() <= scaledRadius * _integerSqrtCeil(lengthSquared);
  }

  static int _integerSqrtCeil(int value) {
    if (value <= 1) return value;
    int root = 1 << ((value.bitLength + 1) >> 1);
    while (true) {
      final int next = (root + value ~/ root) >> 1;
      if (next >= root) {
        return root * root == value ? root : root + 1;
      }
      root = next;
    }
  }
}
