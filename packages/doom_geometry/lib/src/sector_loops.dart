import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry_options.dart';
import 'triangulate.dart';
import 'wad_types.dart';

/// The ORACLE path: sector floor/ceiling polygons rebuilt from linedefs alone.
///
/// This never consults SEGS, SSECTORS or NODES, which is the whole point: it is
/// an independent second opinion on what area a sector covers, so a bug in the
/// BSP clipper cannot hide behind a matching bug here.
///
/// Method:
///  1. Collect every linedef edge that faces the sector, oriented so the sector
///     is consistently on one side.
///  2. Chain edges head-to-tail into closed loops.
///  3. Classify loops as outer or hole by signed area and containment.
///  4. Triangulate each outer loop with its holes bridged in.
///
/// Doom maps are not clean: a sector can have dangling edges, repeated
/// vertices, or loops that never close. Every one of those is recorded in
/// [SectorLoopResult] instead of throwing, because the compiler must still be
/// able to emit something for the rest of the level.

/// One sector's reconstructed boundary.
class SectorLoopResult {
  const SectorLoopResult({
    required this.sector,
    required this.outers,
    required this.holes,
    required this.triangulation,
    required this.openChains,
    required this.duplicateEdges,
    required this.area,
  });

  final int sector;

  /// Loops enclosing area, counter-clockwise normalised.
  final List<Loop> outers;

  /// Loops subtracted from an outer, keyed by their owning outer's index.
  final List<List<Loop>> holes;

  /// One triangulation per outer loop.
  final List<TriangulationResult> triangulation;

  /// Edge chains that never closed. Non-zero means the map is malformed here.
  final int openChains;

  /// Edges seen more than once with the same orientation.
  final int duplicateEdges;

  /// Total covered area in square map units.
  final double area;

  bool get isWellFormed => openChains == 0 && outers.isNotEmpty;

  int get triangleCount {
    var total = 0;
    for (var i = 0; i < triangulation.length; i++) {
      total += triangulation[i].triangleCount;
    }
    return total;
  }

  bool get isComplete {
    for (var i = 0; i < triangulation.length; i++) {
      if (!triangulation[i].isComplete) {
        return false;
      }
    }
    return true;
  }
}

/// Builds sector boundary loops for a whole map.
class SectorLoopBuilder {
  SectorLoopBuilder(this.map, this.options);

  final MapData map;
  final GeometryOptions options;

  final EarClipper _clipper = EarClipper();

  /// Reconstructs every sector. Index of the result equals the sector index.
  List<SectorLoopResult> buildAll(CheckBudget budget) {
    final int sectorCount = map.sectors.length;
    // Bucket linedef sides by sector in one pass so each sector's edge set is
    // a contiguous slice instead of a full linedef scan per sector.
    final List<List<int>> sidesBySector = List<List<int>>.generate(
      sectorCount,
      (int _) => <int>[],
      growable: false,
    );
    for (var i = 0; i < map.linedefs.length; i++) {
      final Linedef line = map.linedefs[i];
      final int front = _sectorOfSide(line.rightSidedef);
      final int back = _sectorOfSide(line.leftSidedef);
      // A self-referencing linedef separates a sector from itself. It may be
      // meaningful to collision or rendering, but it is not part of that
      // sector's floor boundary and must not create a dangling oracle edge.
      if (front != kNoSector && front == back) {
        continue;
      }
      if (front != kNoSector && front < sectorCount) {
        // Encode side in the low bit: even = front, odd = back.
        sidesBySector[front].add(i << 1);
      }
      if (back != kNoSector && back < sectorCount && back != front) {
        sidesBySector[back].add((i << 1) | 1);
      }
    }
    final List<SectorLoopResult> out = <SectorLoopResult>[];
    for (var s = 0; s < sectorCount; s++) {
      out.add(_buildSector(s, sidesBySector[s], budget));
    }
    return out;
  }

  int _sectorOfSide(int sidedefIndex) {
    if (sidedefIndex == kNoSidedef || sidedefIndex < 0) {
      return kNoSector;
    }
    if (sidedefIndex >= map.sidedefs.length) {
      return kNoSector;
    }
    return map.sidedefs[sidedefIndex].sector;
  }

  SectorLoopResult _buildSector(
    int sector,
    List<int> encodedSides,
    CheckBudget budget,
  ) {
    if (encodedSides.isEmpty) {
      return SectorLoopResult(
        sector: sector,
        outers: const <Loop>[],
        holes: const <List<Loop>>[],
        triangulation: const <TriangulationResult>[],
        openChains: 0,
        duplicateEdges: 0,
        area: 0,
      );
    }
    // Directed edges: for a front side the sector lies to the right of v1->v2,
    // so walking v1->v2 keeps the interior consistently oriented; a back side
    // is the same edge reversed.
    final Int32List edgeFrom = Int32List(encodedSides.length);
    final Int32List edgeTo = Int32List(encodedSides.length);
    var edgeCount = 0;
    var duplicates = 0;
    final Set<int> seen = <int>{};
    for (var i = 0; i < encodedSides.length; i++) {
      final int encoded = encodedSides[i];
      final Linedef line = map.linedefs[encoded >> 1];
      final bool back = (encoded & 1) == 1;
      final int a = back ? line.v2 : line.v1;
      final int b = back ? line.v1 : line.v2;
      if (a == b) {
        continue; // zero-length linedef
      }
      if (a < 0 ||
          b < 0 ||
          a >= map.vertices.length ||
          b >= map.vertices.length) {
        continue;
      }
      final int key = a * 65536 + b;
      if (!seen.add(key)) {
        duplicates++;
        continue;
      }
      edgeFrom[edgeCount] = a;
      edgeTo[edgeCount] = b;
      edgeCount++;
    }
    if (edgeCount < 3) {
      return SectorLoopResult(
        sector: sector,
        outers: const <Loop>[],
        holes: const <List<Loop>>[],
        triangulation: const <TriangulationResult>[],
        openChains: edgeCount > 0 ? 1 : 0,
        duplicateEdges: duplicates,
        area: 0,
      );
    }
    final List<Loop> rings = <Loop>[];
    final int openChains = _chainLoops(
      edgeFrom,
      edgeTo,
      edgeCount,
      rings,
      budget,
    );
    if (rings.isEmpty) {
      return SectorLoopResult(
        sector: sector,
        outers: const <Loop>[],
        holes: const <List<Loop>>[],
        triangulation: const <TriangulationResult>[],
        openChains: openChains,
        duplicateEdges: duplicates,
        area: 0,
      );
    }
    return _classifyAndTriangulate(
      sector,
      rings,
      openChains,
      duplicates,
      budget,
    );
  }

  /// Walks directed edges head-to-tail into closed rings.
  ///
  /// Where a vertex has several outgoing candidates (a pinch point, common in
  /// Doom), the most clockwise turn is taken. That is the standard rule for
  /// tracing the tightest face and keeps a figure-eight from collapsing into
  /// one self-intersecting ring.
  int _chainLoops(
    Int32List edgeFrom,
    Int32List edgeTo,
    int edgeCount,
    List<Loop> rings,
    CheckBudget budget,
  ) {
    final Map<int, List<int>> outgoing = <int, List<int>>{};
    for (var i = 0; i < edgeCount; i++) {
      (outgoing[edgeFrom[i]] ??= <int>[]).add(i);
    }
    final Uint8List used = Uint8List(edgeCount);
    final List<int> chain = <int>[];
    var open = 0;

    for (var start = 0; start < edgeCount; start++) {
      if (used[start] == 1) {
        continue;
      }
      chain.clear();
      var edge = start;
      var closed = false;
      while (true) {
        if (!budget.spend()) {
          return open + 1;
        }
        used[edge] = 1;
        chain.add(edge);
        final int tail = edgeTo[edge];
        if (tail == edgeFrom[start] && chain.length >= 3) {
          closed = true;
          break;
        }
        final List<int>? candidates = outgoing[tail];
        if (candidates == null) {
          break;
        }
        final int nextEdge = _pickNext(
          edge,
          candidates,
          used,
          edgeFrom,
          edgeTo,
          budget,
        );
        if (nextEdge < 0) {
          break;
        }
        edge = nextEdge;
      }
      if (!closed) {
        open++;
        continue;
      }
      final Float64List xy = Float64List(chain.length * 2);
      for (var i = 0; i < chain.length; i++) {
        final MapVertex v = map.vertices[edgeFrom[chain[i]]];
        xy[i * 2] = v.x.toDouble();
        xy[i * 2 + 1] = v.y.toDouble();
      }
      final Loop ring = Loop(xy);
      if (ring.area > 0) {
        rings.add(ring);
      }
    }
    return open;
  }

  /// Chooses the outgoing edge making the tightest clockwise turn.
  int _pickNext(
    int incoming,
    List<int> candidates,
    Uint8List used,
    Int32List edgeFrom,
    Int32List edgeTo,
    CheckBudget budget,
  ) {
    if (candidates.length == 1) {
      final int only = candidates[0];
      return used[only] == 1 ? -1 : only;
    }
    final MapVertex pivot = map.vertices[edgeTo[incoming]];
    final MapVertex tail = map.vertices[edgeFrom[incoming]];
    final double inDx = (pivot.x - tail.x).toDouble();
    final double inDy = (pivot.y - tail.y).toDouble();
    var best = -1;
    var bestAngle = double.infinity;
    for (var i = 0; i < candidates.length; i++) {
      if (!budget.spend()) {
        return -1;
      }
      final int cand = candidates[i];
      if (used[cand] == 1) {
        continue;
      }
      final MapVertex head = map.vertices[edgeTo[cand]];
      final double outDx = (head.x - pivot.x).toDouble();
      final double outDy = (head.y - pivot.y).toDouble();
      // Turn angle measured clockwise from the incoming direction, in [0, 2pi).
      final double cross = inDx * outDy - inDy * outDx;
      final double dot = inDx * outDx + inDy * outDy;
      var angle = _atan2Positive(-cross, -dot);
      if (angle <= 0) {
        angle += 6.283185307179586;
      }
      if (angle < bestAngle) {
        bestAngle = angle;
        best = cand;
      }
    }
    return best;
  }

  static double _atan2Positive(double y, double x) {
    final double a = math.atan2(y, x);
    return a < 0 ? a + 6.283185307179586 : a;
  }

  /// Sorts rings into outers and holes, then triangulates.
  ///
  /// Containment is decided by nesting depth: a ring inside an odd number of
  /// other rings is a hole. Ranking by descending area first means a ring is
  /// only ever tested against rings that could actually contain it.
  SectorLoopResult _classifyAndTriangulate(
    int sector,
    List<Loop> rings,
    int openChains,
    int duplicates,
    CheckBudget budget,
  ) {
    final List<Loop> ordered = List<Loop>.of(rings)
      ..sort((Loop a, Loop b) => b.area.compareTo(a.area));
    final int n = ordered.length;
    final Int32List parent = Int32List(n)..fillRange(0, n, -1);
    final Int32List depth = Int32List(n);
    for (var i = 0; i < n; i++) {
      final Loop inner = ordered[i];
      final double px = inner.x(0);
      final double py = inner.y(0);
      // Larger rings come first, so the nearest enclosing ring is the last
      // container found scanning forward.
      for (var j = 0; j < i; j++) {
        if (!budget.spend()) {
          break;
        }
        if (ordered[j].containsPoint(px, py)) {
          parent[i] = j;
        }
      }
      depth[i] = parent[i] < 0 ? 0 : depth[parent[i]] + 1;
    }
    final List<Loop> outers = <Loop>[];
    final List<List<Loop>> holes = <List<Loop>>[];
    final Int32List outerSlot = Int32List(n)..fillRange(0, n, -1);
    for (var i = 0; i < n; i++) {
      if (depth[i].isEven) {
        outerSlot[i] = outers.length;
        outers.add(
          ordered[i].isCounterClockwise ? ordered[i] : ordered[i].reversed(),
        );
        holes.add(<Loop>[]);
      }
    }
    for (var i = 0; i < n; i++) {
      if (depth[i].isOdd) {
        final int owner = parent[i];
        final int slot = owner >= 0 ? outerSlot[owner] : -1;
        if (slot >= 0) {
          holes[slot].add(
            ordered[i].isCounterClockwise ? ordered[i].reversed() : ordered[i],
          );
        }
      }
    }
    final List<TriangulationResult> tris = <TriangulationResult>[];
    var area = 0.0;
    for (var i = 0; i < outers.length; i++) {
      final TriangulationResult t = _clipper.triangulate(
        outers[i],
        holes[i],
        budget,
        epsilon: options.epsilon * options.epsilon,
      );
      tris.add(t);
      area += t.area;
    }
    return SectorLoopResult(
      sector: sector,
      outers: outers,
      holes: holes,
      triangulation: tris,
      openChains: openChains,
      duplicateEdges: duplicates,
      area: area,
    );
  }
}
