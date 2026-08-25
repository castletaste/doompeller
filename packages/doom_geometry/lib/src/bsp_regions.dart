import 'dart:typed_data';

import 'geometry_options.dart';
import 'polygon.dart';
import 'triangulate.dart';
import 'wad_types.dart';

/// Recovers each subsector's convex region by descending the BSP.
///
/// ## Why this is needed at all
///
/// Vanilla SEGS only contains segments that lie on real linedefs. The implicit
/// cuts the node builder made through open space (minisegs) are not stored, so
/// a subsector's segs are an OPEN chain, not a closed polygon. Floors and
/// ceilings need a closed region.
///
/// ## Method
///
/// A subsector is by construction the intersection of half-planes: one per BSP
/// node on the path from the root, taking the side the subsector was reached
/// through. So:
///
///   1. Start from a quad bounding the whole map.
///   2. Descend from the root. At each node, clip the running polygon to the
///      child side being entered, then recurse.
///   3. At a leaf, clip once more against each of the subsector's own segs.
///
/// Step 3 matters. Partition planes alone reproduce the convex cell, but the
/// node builder's segs can be shorter than the cell edge where a linedef ends
/// mid-cell, and clipping against the segs pins the polygon to the actual
/// linedef geometry so a floor never bleeds through a wall.
///
/// ## Cracks
///
/// Two subsectors sharing a partition plane must produce bit-identical points
/// along it. Guaranteed here by (a) clipping both with the same normalised
/// plane, and (b) snapping every emitted intersection to a common lattice. Two
/// clips of one plane are then the same arithmetic on the same inputs, so the
/// shared edge is exact rather than approximately equal.

/// One subsector's reconstructed convex polygon.
class BspRegion {
  const BspRegion({
    required this.subsector,
    required this.sector,
    required this.xy,
    required this.depth,
    required this.clippedToEmpty,
    required this.segCount,
  });

  final int subsector;

  /// Sector this subsector belongs to, taken from its first seg's sidedef.
  /// -1 when the subsector has no usable segs.
  final int sector;

  /// Flat x, y pairs, convex, counter-clockwise. Empty when degenerate.
  final Float64List xy;

  /// BSP depth this leaf sits at; reported so a pathological tree is visible.
  final int depth;

  /// True when half-plane clipping removed everything.
  final bool clippedToEmpty;

  final int segCount;

  int get vertexCount => xy.length >> 1;
  bool get isEmpty => xy.length < 6;
  double get area => polygonArea(xy, vertexCount);
}

/// Outcome of a whole-map BSP region pass.
class BspRegionSet {
  const BspRegionSet({
    required this.regions,
    required this.emptyRegions,
    required this.maxDepth,
    required this.depthExceeded,
    required this.budgetExhausted,
    required this.visitedNodes,
    required this.duplicateLeaves,
  });

  /// One entry per subsector, index-aligned with MapData.subsectors.
  final List<BspRegion> regions;

  /// Subsectors that clipped to nothing; reported, never a crash.
  final int emptyRegions;

  final int maxDepth;

  /// True when the tree was deeper than the configured cap, so some branch was
  /// abandoned rather than followed.
  final bool depthExceeded;

  final bool budgetExhausted;

  final int visitedNodes;

  /// Subsectors reached through more than one leaf pointer. Non-zero means the
  /// tree is malformed; the last region reached wins.
  final int duplicateLeaves;

  bool get isUsable => !budgetExhausted && !depthExceeded;
}

/// Builds convex regions for every subsector of a map.
class BspRegionBuilder {
  BspRegionBuilder(this.map, this.options);

  final MapData map;
  final GeometryOptions options;

  /// One clip buffer per depth. The descent is depth-first and a node only
  /// needs its parent's polygon plus the child currently being built, so
  /// depth-indexed buffers make the traversal allocation-free once each depth
  /// has been reached one time.
  final List<PolyBuffer> _pool = <PolyBuffer>[];

  /// Ping-pong partners for per-leaf seg clipping.
  final PolyBuffer _leafA = PolyBuffer(64);
  final PolyBuffer _leafB = PolyBuffer(64);
  final PolyBuffer _scratch = PolyBuffer(64);

  List<BspRegion?> _regions = <BspRegion?>[];
  Int32List _sectorOfSubsector = Int32List(0);
  var _emptyCount = 0;
  var _maxDepth = 0;
  var _depthExceeded = false;
  var _visited = 0;
  var _duplicateLeaves = 0;

  PolyBuffer _bufferAt(int depth) {
    while (_pool.length <= depth) {
      _pool.add(PolyBuffer(64));
    }
    return _pool[depth];
  }

  BspRegionSet build(CheckBudget budget) {
    final int subsectorCount = map.subsectors.length;
    _regions = List<BspRegion?>.filled(subsectorCount, null);
    _sectorOfSubsector = Int32List(subsectorCount)..fillRange(0, subsectorCount, -1);
    for (var i = 0; i < subsectorCount; i++) {
      _sectorOfSubsector[i] = _resolveSector(i);
    }
    _emptyCount = 0;
    _maxDepth = 0;
    _depthExceeded = false;
    _visited = 0;
    _duplicateLeaves = 0;

    final Float64List bounds = _mapBounds();
    final PolyBuffer root = _bufferAt(0)..clear();
    root
      ..add(bounds[0], bounds[1])
      ..add(bounds[2], bounds[1])
      ..add(bounds[2], bounds[3])
      ..add(bounds[0], bounds[3]);

    var exhausted = false;
    if (map.nodes.isEmpty) {
      // A single-leaf map has no partitions; the whole bounding quad is the
      // one subsector's region, still clipped by its own segs.
      if (subsectorCount > 0) {
        exhausted = !_emitLeaf(0, root, 0, budget);
      }
    } else {
      exhausted = !_descend(map.bspRoot, root, 0, budget);
    }

    final List<BspRegion> out = <BspRegion>[];
    for (var i = 0; i < subsectorCount; i++) {
      out.add(
        _regions[i] ??
            BspRegion(
              subsector: i,
              sector: _sectorOfSubsector[i],
              xy: Float64List(0),
              depth: 0,
              clippedToEmpty: true,
              segCount: map.subsectors[i].segCount,
            ),
      );
    }
    // Unreached subsectors count as empty too: an unreferenced leaf means the
    // tree does not actually cover the level.
    var empties = 0;
    for (var i = 0; i < out.length; i++) {
      if (out[i].isEmpty) {
        empties++;
      }
    }
    _emptyCount = empties;
    return BspRegionSet(
      regions: out,
      emptyRegions: _emptyCount,
      maxDepth: _maxDepth,
      depthExceeded: _depthExceeded,
      budgetExhausted: exhausted,
      visitedNodes: _visited,
      duplicateLeaves: _duplicateLeaves,
    );
  }

  int _resolveSector(int subsectorIndex) {
    final Subsector ss = map.subsectors[subsectorIndex];
    for (var i = 0; i < ss.segCount; i++) {
      final int segIndex = ss.firstSeg + i;
      if (segIndex < 0 || segIndex >= map.segs.length) {
        continue;
      }
      final Seg seg = map.segs[segIndex];
      if (seg.linedef < 0 || seg.linedef >= map.linedefs.length) {
        continue;
      }
      final Linedef line = map.linedefs[seg.linedef];
      final int sideIndex = seg.side == 0 ? line.rightSidedef : line.leftSidedef;
      if (sideIndex == kNoSidedef || sideIndex < 0 || sideIndex >= map.sidedefs.length) {
        continue;
      }
      return map.sidedefs[sideIndex].sector;
    }
    return kNoSector;
  }

  /// Bounding quad, padded so a partition through the extreme edge still has
  /// polygon on both sides.
  Float64List _mapBounds() {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (var i = 0; i < map.vertices.length; i++) {
      final MapVertex v = map.vertices[i];
      final double x = v.x.toDouble();
      final double y = v.y.toDouble();
      if (x < minX) {
        minX = x;
      }
      if (x > maxX) {
        maxX = x;
      }
      if (y < minY) {
        minY = y;
      }
      if (y > maxY) {
        maxY = y;
      }
    }
    if (minX > maxX) {
      minX = maxX = minY = maxY = 0;
    }
    const double pad = 256.0;
    final Float64List out = Float64List(4);
    out[0] = minX - pad;
    out[1] = minY - pad;
    out[2] = maxX + pad;
    out[3] = maxY + pad;
    return out;
  }

  /// Recursive descent. [poly] is the region of the node being entered and is
  /// consumed; children get their own clipped copies.
  bool _descend(int nodeIndex, PolyBuffer poly, int depth, CheckBudget budget) {
    if (depth > _maxDepth) {
      _maxDepth = depth;
    }
    if (depth >= options.maxBspDepth) {
      _depthExceeded = true;
      return true;
    }
    if (nodeIndex < 0 || nodeIndex >= map.nodes.length) {
      return true;
    }
    if (!budget.spend()) {
      return false;
    }
    _visited++;
    final BspNode node = map.nodes[nodeIndex];
    final double ax = node.x.toDouble();
    final double ay = node.y.toDouble();
    final double dx = node.dx.toDouble();
    final double dy = node.dy.toDouble();

    // Right child first, matching the order vanilla stores and traverses.
    // Both children reuse the same depth slot: the right subtree is finished
    // before the left polygon is built into it.
    final PolyBuffer right = _bufferAt(depth + 1);
    clipHalfPlane(
      poly,
      right,
      ax: ax,
      ay: ay,
      dx: dx,
      dy: dy,
      keepPositive: true,
      epsilon: options.epsilon,
      grid: options.weldGrid,
    );
    cleanPolygon(right, options.epsilon, _scratch);
    if (!_enterChild(node.rightChild, right, depth + 1, budget)) {
      return false;
    }

    final PolyBuffer left = _bufferAt(depth + 1);
    clipHalfPlane(
      poly,
      left,
      ax: ax,
      ay: ay,
      dx: dx,
      dy: dy,
      keepPositive: false,
      epsilon: options.epsilon,
      grid: options.weldGrid,
    );
    cleanPolygon(left, options.epsilon, _scratch);
    return _enterChild(node.leftChild, left, depth + 1, budget);
  }

  bool _enterChild(int child, PolyBuffer poly, int depth, CheckBudget budget) {
    if ((child & kSubsectorBit) != 0) {
      return _emitLeaf(child & ~kSubsectorBit, poly, depth, budget);
    }
    return _descend(child, poly, depth, budget);
  }

  /// Finishes a leaf: clips by the subsector's own segs and records the region.
  bool _emitLeaf(int subsector, PolyBuffer poly, int depth, CheckBudget budget) {
    if (subsector < 0 || subsector >= map.subsectors.length) {
      return true;
    }
    if (depth > _maxDepth) {
      _maxDepth = depth;
    }
    final Subsector ss = map.subsectors[subsector];
    if (_regions[subsector] != null) {
      _duplicateLeaves++;
    }
    // Copy out of the depth-pooled buffer before clipping: the leaf ping-pong
    // must not scribble over the polygon the parent still needs for its other
    // child.
    PolyBuffer current = _leafA..setFrom(poly);
    PolyBuffer other = _leafB;

    for (var i = 0; i < ss.segCount; i++) {
      if (current.isEmpty) {
        break;
      }
      if (!budget.spend()) {
        return false;
      }
      final int segIndex = ss.firstSeg + i;
      if (segIndex < 0 || segIndex >= map.segs.length) {
        continue;
      }
      final Seg seg = map.segs[segIndex];
      // Clip against the seg's parent LINEDEF, not the seg's own endpoints.
      //
      // This matters and is not a micro-optimisation. A node builder splits a
      // linedef wherever a partition crosses it and stores the split point
      // rounded to integer map units, because VERTEXES is an integer lump. The
      // rounded endpoint is up to half a unit off the true line, so the line
      // through a split seg's endpoints is very slightly rotated away from the
      // wall it represents. Clipping a convex cell by that rotated line shaves
      // a sliver off the cell, and every such sliver is a visible crack that
      // the validator would then have to report as a gap.
      //
      // The linedef's own vertices are exact by construction, and a seg is by
      // definition collinear with its linedef, so using the linedef's line
      // selects the identical half-plane with none of the rounding error.
      final _ClipLine? line = _clipLineFor(seg);
      if (line == null) {
        continue;
      }
      final double sx = line.x;
      final double sy = line.y;
      final double sdx = line.dx;
      final double sdy = line.dy;
      if (sdx == 0 && sdy == 0) {
        continue; // zero-length seg: no half-plane to select
      }
      // A subsector lies on the front (positive) side of each of its own segs.
      clipHalfPlane(
        current,
        other,
        ax: sx,
        ay: sy,
        dx: sdx,
        dy: sdy,
        keepPositive: true,
        epsilon: options.epsilon,
        grid: options.weldGrid,
      );
      final PolyBuffer swap = current;
      current = other;
      other = swap;
    }
    cleanPolygon(current, options.epsilon, _scratch);

    final bool empty = current.length < 3;
    if (empty) {
      _regions[subsector] = BspRegion(
        subsector: subsector,
        sector: _sectorOfSubsector[subsector],
        xy: Float64List(0),
        depth: depth,
        clippedToEmpty: true,
        segCount: ss.segCount,
      );
      return true;
    }
    // Normalise to counter-clockwise so downstream code never has to branch on
    // winding when emitting floors versus ceilings.
    Float64List xy = current.toFloat64List();
    if (signedArea2(xy, current.length) < 0) {
      xy = _reverse(xy);
    }
    _regions[subsector] = BspRegion(
      subsector: subsector,
      sector: _sectorOfSubsector[subsector],
      xy: xy,
      depth: depth,
      clippedToEmpty: false,
      segCount: ss.segCount,
    );
    return true;
  }

  /// Half-plane for one seg, preferring its linedef's exact geometry.
  _ClipLine? _clipLineFor(Seg seg) {
    if (seg.linedef >= 0 && seg.linedef < map.linedefs.length) {
      final Linedef line = map.linedefs[seg.linedef];
      if (line.v1 >= 0 &&
          line.v2 >= 0 &&
          line.v1 < map.vertices.length &&
          line.v2 < map.vertices.length) {
        // side 1 means the seg runs against the linedef's direction, so the
        // half-plane to keep is the other one.
        final MapVertex a =
            map.vertices[seg.side == 0 ? line.v1 : line.v2];
        final MapVertex b =
            map.vertices[seg.side == 0 ? line.v2 : line.v1];
        if (a.x != b.x || a.y != b.y) {
          return _ClipLine(
            a.x.toDouble(),
            a.y.toDouble(),
            (b.x - a.x).toDouble(),
            (b.y - a.y).toDouble(),
          );
        }
      }
    }
    // No usable linedef: fall back to the seg's stored endpoints.
    if (seg.v1 < 0 ||
        seg.v2 < 0 ||
        seg.v1 >= map.vertices.length ||
        seg.v2 >= map.vertices.length) {
      return null;
    }
    final MapVertex a = map.vertices[seg.v1];
    final MapVertex b = map.vertices[seg.v2];
    return _ClipLine(
      a.x.toDouble(),
      a.y.toDouble(),
      (b.x - a.x).toDouble(),
      (b.y - a.y).toDouble(),
    );
  }

  static Float64List _reverse(Float64List xy) {
    final int n = xy.length >> 1;
    final Float64List out = Float64List(xy.length);
    for (var i = 0; i < n; i++) {
      final int src = (n - 1 - i) * 2;
      out[i * 2] = xy[src];
      out[i * 2 + 1] = xy[src + 1];
    }
    return out;
  }
}

/// A directed line selecting a half-plane.
class _ClipLine {
  const _ClipLine(this.x, this.y, this.dx, this.dy);

  final double x;
  final double y;
  final double dx;
  final double dy;
}
