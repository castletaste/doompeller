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
