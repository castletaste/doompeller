import 'dart:typed_data';

import 'polygon.dart';
// Second view of the same library: the Loop.signedArea2 field would otherwise
// shadow the free function of the same name.
import 'polygon.dart' as geom;

/// Bounded counter for the quadratic parts of triangulation and validation.
///
/// A crafted sector can make ear clipping or edge matching run effectively
/// forever; every inner loop charges this budget and the caller decides what an
/// exhausted budget means (typed failure, or degrade to the fallback path).
class CheckBudget {
  CheckBudget(this.limit);

  final int limit;
  int _used = 0;

  int get used => _used;
  bool get exhausted => _used >= limit;

  /// Charges [amount]; returns false once the budget is gone.
  bool spend([int amount = 1]) {
    _used += amount;
    return _used < limit;
  }
}

/// A closed ring of vertices in flat xy storage.
class Loop {
  Loop(this.xy) : signedArea2 = signedArea2Of(xy);

  factory Loop.fromBuffer(PolyBuffer buffer) => Loop(buffer.toFloat64List());

  static double signedArea2Of(Float64List xy) =>
      geom.signedArea2(xy, xy.length >> 1);

  /// Flat x, y pairs. Not closed: the last vertex implicitly joins the first.
  final Float64List xy;

  /// Twice the signed area; positive is counter-clockwise.
  final double signedArea2;

  int get length => xy.length >> 1;
  double get area => signedArea2.abs() * 0.5;
  bool get isCounterClockwise => signedArea2 > 0;

  double x(int i) => xy[i * 2];
  double y(int i) => xy[i * 2 + 1];

  /// Reversed copy, used to normalise winding before triangulation.
  Loop reversed() {
    final int n = length;
    final Float64List out = Float64List(n * 2);
    for (var i = 0; i < n; i++) {
      final int src = (n - 1 - i) * 2;
      out[i * 2] = xy[src];
      out[i * 2 + 1] = xy[src + 1];
    }
    return Loop(out);
  }

  bool containsPoint(double px, double py) => pointInLoop(xy, length, px, py);
}

/// Result of triangulating one polygon.
class TriangulationResult {
  const TriangulationResult({
    required this.vertices,
    required this.indices,
    required this.degenerateCount,
    required this.budgetExhausted,
    required this.unresolvedVertices,
  });

  /// Flat x, y pairs, including any bridge duplicates introduced for holes.
  final Float64List vertices;

  /// Triangle list into [vertices], counter-clockwise.
  final Uint16List indices;

  /// Corners snipped for having no usable area.
  final int degenerateCount;

  /// True when the check budget ran out mid-clip; output is partial.
  final bool budgetExhausted;

  /// Vertices left over when clipping stalled on a self-intersecting loop.
  final int unresolvedVertices;

  int get triangleCount => indices.length ~/ 3;

  bool get isComplete => !budgetExhausted && unresolvedVertices == 0;

  /// Total unsigned area of the emitted triangles.
  double get area {
    var sum = 0.0;
    for (var t = 0; t < indices.length; t += 3) {
      final int a = indices[t] * 2;
      final int b = indices[t + 1] * 2;
      final int c = indices[t + 2] * 2;
      sum += ((vertices[b] - vertices[a]) * (vertices[c + 1] - vertices[a + 1]) -
              (vertices[c] - vertices[a]) * (vertices[b + 1] - vertices[a + 1]))
          .abs();
    }
    return sum * 0.5;
  }

  static final TriangulationResult empty = TriangulationResult(
    vertices: Float64List(0),
    indices: Uint16List(0),
    degenerateCount: 0,
    budgetExhausted: false,
    unresolvedVertices: 0,
  );
}

/// Ear-clipping triangulator with hole bridging.
///
/// Holes are merged into the outer ring first: each hole is joined by a
/// zero-width bridge to a mutually visible outer vertex, producing one weakly
/// simple polygon that plain ear clipping then handles. Chosen over sweep-line
/// trapezoidation because Doom sectors are small and integer-quantised, and the
/// failure mode that matters ("wrong covered area") is checked directly by the
/// validator rather than assumed away.
///
/// Closure-free, and scratch arrays are reused between calls.
class EarClipper {
  EarClipper();

  final List<double> _work = <double>[];
  final List<int> _out = <int>[];

  /// Doubly linked ring over the working polygon, grown on demand. Typed
  /// arrays rather than growable lists so clipping never boxes an index.
  Int32List _prev = Int32List(0);
  Int32List _next = Int32List(0);

  /// Triangulates [outer] with optional [holes].
  ///
  /// Winding is normalised internally: [outer] becomes counter-clockwise and
  /// holes clockwise, so callers need not care what the map data said.
  /// [epsilon] sets the zero-area rejection threshold.
  TriangulationResult triangulate(
    Loop outer,
    List<Loop> holes,
    CheckBudget budget, {
    double epsilon = 1e-9,
  }) {
    if (outer.length < 3) {
      return TriangulationResult.empty;
    }
    // A ring with no net signed area has no orientation to normalise to, so
    // ear clipping cannot even decide which side is "inside". The classic case
    // is a figure-eight, whose two halves cancel exactly. Clipping it would
    // succeed on a ring that is not simple and quietly emit triangles covering
    // only half the outline, so it is refused up front and reported instead.
    if (outer.signedArea2.abs() <= epsilon) {
      return TriangulationResult(
        vertices: Float64List(0),
        indices: Uint16List(0),
        degenerateCount: 0,
        budgetExhausted: false,
        unresolvedVertices: outer.length,
      );
    }
    _work.clear();
    final Loop ccw = outer.isCounterClockwise ? outer : outer.reversed();
    for (var i = 0; i < ccw.length; i++) {
      _work.add(ccw.x(i));
      _work.add(ccw.y(i));
    }
    if (holes.isNotEmpty && !_bridgeHoles(holes, budget)) {
      return TriangulationResult.empty;
    }
    return _clip(budget, epsilon);
  }

  /// Joins each hole to the outer ring with a zero-width bridge.
  ///
  /// Holes are merged right-to-left by their rightmost vertex. That order is
  /// what makes the bridge target provably reachable: the rightmost remaining
  /// hole cannot be occluded by a hole that has not been merged yet.
  bool _bridgeHoles(List<Loop> holes, CheckBudget budget) {
    final List<Loop> ordered = List<Loop>.of(holes);
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].isCounterClockwise) {
        ordered[i] = ordered[i].reversed();
      }
    }
    ordered.sort(_compareByRightmostDescending);
    for (final Loop hole in ordered) {
      if (hole.length < 3) {
        continue;
      }
      if (!_bridgeOneHole(hole, budget)) {
        return false;
      }
    }
    return true;
  }

  static int _compareByRightmostDescending(Loop a, Loop b) =>
      _maxX(b).compareTo(_maxX(a));

  static double _maxX(Loop loop) {
    var best = double.negativeInfinity;
    for (var i = 0; i < loop.length; i++) {
      final double v = loop.x(i);
      if (v > best) {
        best = v;
      }
    }
    return best;
  }

  bool _bridgeOneHole(Loop hole, CheckBudget budget) {
    // Rightmost hole vertex: a ray from it towards +x leaves the hole at once.
    var holeStart = 0;
    var bestX = double.negativeInfinity;
    var bestY = double.infinity;
    for (var i = 0; i < hole.length; i++) {
      final double hx = hole.x(i);
      final double hy = hole.y(i);
      if (hx > bestX || (hx == bestX && hy < bestY)) {
        bestX = hx;
        bestY = hy;
        holeStart = i;
      }
    }
    final int bridge = _findVisibleOuterVertex(bestX, bestY, budget);
    if (bridge < 0) {
      return false;
    }
    final int outerCount = _work.length >> 1;
    final List<double> merged = <double>[];
    for (var i = 0; i <= bridge; i++) {
      merged.add(_work[i * 2]);
      merged.add(_work[i * 2 + 1]);
    }
    for (var k = 0; k < hole.length; k++) {
      final int hi = (holeStart + k) % hole.length;
      merged.add(hole.x(hi));
      merged.add(hole.y(hi));
    }
    // Close the bridge by repeating both endpoints.
    merged.add(hole.x(holeStart));
    merged.add(hole.y(holeStart));
    for (var i = bridge; i < outerCount; i++) {
      merged.add(_work[i * 2]);
      merged.add(_work[i * 2 + 1]);
    }
    _work
      ..clear()
      ..addAll(merged);
    return true;
  }

  /// Picks an outer vertex the hole's rightmost point can see.
  ///
  /// Casts a ray towards +x, takes the first edge hit, then verifies the bridge
  /// crosses no ring edge, walking outwards for an alternative if it does.
  int _findVisibleOuterVertex(double hx, double hy, CheckBudget budget) {
    final int n = _work.length >> 1;
    if (n == 0) {
      return -1;
    }
    var bestIndex = -1;
    var bestX = double.infinity;
    for (var i = 0; i < n; i++) {
      if (!budget.spend()) {
        return -1;
      }
      final int j = (i + 1) % n;
      final double ay = _work[i * 2 + 1];
      final double by = _work[j * 2 + 1];
      if ((ay > hy) == (by > hy)) {
        continue;
      }
      final double ax = _work[i * 2];
      final double bx = _work[j * 2];
      final double t = (hy - ay) / (by - ay);
      final double ix = ax + (bx - ax) * t;
      if (ix < hx) {
        continue;
      }
      if (ix < bestX) {
        bestX = ix;
        // Prefer the rightmost endpoint of the hit edge: it is nearest the hole
        // and least likely to produce a crossing bridge.
        bestIndex = ax > bx ? i : j;
      }
    }
    if (bestIndex >= 0) {
      final int refined = _refineVisibility(hx, hy, bestIndex, budget);
      return refined >= 0 ? refined : bestIndex;
    }
    var closest = 0;
    var closestDist = double.infinity;
    for (var i = 0; i < n; i++) {
      final double dx = _work[i * 2] - hx;
      final double dy = _work[i * 2 + 1] - hy;
      final double d = dx * dx + dy * dy;
      if (d < closestDist) {
        closestDist = d;
        closest = i;
      }
    }
    return closest;
  }

  int _refineVisibility(
    double hx,
    double hy,
    int candidate,
    CheckBudget budget,
  ) {
    final int n = _work.length >> 1;
    if (_bridgeIsClear(hx, hy, candidate, budget)) {
      return candidate;
    }
    for (var step = 1; step < n; step++) {
      final int forward = (candidate + step) % n;
      if (_bridgeIsClear(hx, hy, forward, budget)) {
        return forward;
      }
      final int backward = (candidate - step + n) % n;
      if (_bridgeIsClear(hx, hy, backward, budget)) {
        return backward;
      }
      if (budget.exhausted) {
        return -1;
      }
    }
    return -1;
  }

  bool _bridgeIsClear(double hx, double hy, int target, CheckBudget budget) {
    final int n = _work.length >> 1;
    final double tx = _work[target * 2];
    final double ty = _work[target * 2 + 1];
    for (var i = 0; i < n; i++) {
      if (!budget.spend()) {
        return false;
      }
      final int j = (i + 1) % n;
      if (i == target || j == target) {
        continue;
      }
      if (_segmentsProperlyCross(
        hx,
        hy,
        tx,
        ty,
        _work[i * 2],
        _work[i * 2 + 1],
        _work[j * 2],
        _work[j * 2 + 1],
      )) {
        return false;
      }
    }
    return true;
  }

  static bool _segmentsProperlyCross(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
    double dx,
    double dy,
  ) {
    final double d1 = _cross(cx, cy, dx, dy, ax, ay);
    final double d2 = _cross(cx, cy, dx, dy, bx, by);
    final double d3 = _cross(ax, ay, bx, by, cx, cy);
    final double d4 = _cross(ax, ay, bx, by, dx, dy);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }

  static double _cross(
    double ax,
    double ay,
    double bx,
    double by,
    double px,
    double py,
  ) =>
      (bx - ax) * (py - ay) - (by - ay) * (px - ax);

  TriangulationResult _clip(CheckBudget budget, double epsilon) {
    final int n = _work.length >> 1;
    if (n < 3) {
      return TriangulationResult.empty;
    }
    if (_prev.length < n) {
      _prev = Int32List(n);
      _next = Int32List(n);
    }
    for (var i = 0; i < n; i++) {
      _prev[i] = (i - 1 + n) % n;
      _next[i] = (i + 1) % n;
    }
    _out.clear();
    var remaining = n;
    var current = 0;
    var stall = 0;
    var degenerate = 0;
    var exhausted = false;
    var stalled = false;

    while (remaining > 3) {
      if (!budget.spend()) {
        exhausted = true;
        break;
      }
      final int prev = _prev[current];
      final int next = _next[current];
      if (_isEar(prev, current, next, budget, epsilon)) {
        _out
          ..add(prev)
          ..add(current)
          ..add(next);
        _next[prev] = next;
        _prev[next] = prev;
        remaining--;
        current = next;
        stall = 0;
        continue;
      }
      // Zero-area corner: snip without emitting so clipping continues instead
      // of stalling on a spike.
      if (_isDegenerateCorner(prev, current, next, epsilon)) {
        _next[prev] = next;
        _prev[next] = prev;
        remaining--;
        degenerate++;
        current = next;
        stall = 0;
        continue;
      }
      current = next;
      stall++;
      if (stall > remaining) {
        // No ear anywhere: the ring self-intersects. Stop and report rather
        // than loop; the caller treats a non-complete result as a failure.
        stalled = true;
        break;
      }
    }

    var unresolved = 0;
    if (!exhausted) {
      if (remaining == 3) {
        final int prev = _prev[current];
        final int next = _next[current];
        if (_isDegenerateCorner(prev, current, next, epsilon)) {
          degenerate++;
        } else if (stalled) {
          // Clipping stalled earlier, so the ring was never simple; the final
          // three vertices are whatever is left over rather than a real
          // triangle. Emit nothing and report it.
          unresolved = remaining;
        } else {
          _out
            ..add(prev)
            ..add(current)
            ..add(next);
        }
      } else if (remaining > 3) {
        unresolved = remaining;
        // Fan the remainder so area is approximately preserved; the result is
        // flagged incomplete so validation can prefer the other path.
        final int anchor = current;
        var b = _next[anchor];
        var c = _next[b];
        var guard = 0;
        while (c != anchor && guard++ <= remaining) {
          if (_isDegenerateCorner(anchor, b, c, epsilon)) {
            degenerate++;
          } else {
            _out
              ..add(anchor)
              ..add(b)
              ..add(c);
          }
          b = c;
          c = _next[c];
        }
      }
    }
    return _emit(degenerate, exhausted, unresolved);
  }

  bool _isDegenerateCorner(int a, int b, int c, double epsilon) {
    final double ax = _work[a * 2];
    final double ay = _work[a * 2 + 1];
    final double bx = _work[b * 2];
    final double by = _work[b * 2 + 1];
    final double cx = _work[c * 2];
    final double cy = _work[c * 2 + 1];
    final double cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    return cross.abs() <= epsilon;
  }

  bool _isEar(int a, int b, int c, CheckBudget budget, double epsilon) {
    final double ax = _work[a * 2];
    final double ay = _work[a * 2 + 1];
    final double bx = _work[b * 2];
    final double by = _work[b * 2 + 1];
    final double cx = _work[c * 2];
    final double cy = _work[c * 2 + 1];
    final double cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    if (cross <= epsilon) {
      return false;
    }
    final double minX = ax < bx ? (ax < cx ? ax : cx) : (bx < cx ? bx : cx);
    final double maxX = ax > bx ? (ax > cx ? ax : cx) : (bx > cx ? bx : cx);
    final double minY = ay < by ? (ay < cy ? ay : cy) : (by < cy ? by : cy);
    final double maxY = ay > by ? (ay > cy ? ay : cy) : (by > cy ? by : cy);
    var probe = _next[c];
    while (probe != a) {
      if (!budget.spend()) {
        return false;
      }
      final double px = _work[probe * 2];
      final double py = _work[probe * 2 + 1];
      if (px >= minX &&
          px <= maxX &&
          py >= minY &&
          py <= maxY &&
          !_samepoint(px, py, ax, ay) &&
          !_samepoint(px, py, bx, by) &&
          !_samepoint(px, py, cx, cy) &&
          _insideOrOn(px, py, ax, ay, bx, by, cx, cy)) {
        return false;
      }
      probe = _next[probe];
    }
    return true;
  }

  /// Containment test used to reject unsafe ears.
  ///
  /// Deliberately inclusive of the boundary. A vertex lying exactly ON an ear's
  /// edge is the dangerous case: clipping that ear pinches the ring into two
  /// pieces joined at a single point, and every later ear test then operates on
  /// a polygon that is no longer simple. That is precisely how a concave notch
  /// ends up filled in. Vertices coincident with the ear's own corners are
  /// excluded by the caller, which is what keeps hole bridges (whose endpoints
  /// are duplicated by construction) clippable.
  static bool _insideOrOn(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
  ) {
    final double d1 = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    final double d2 = (cx - bx) * (py - by) - (cy - by) * (px - bx);
    final double d3 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx);
    return d1 >= 0 && d2 >= 0 && d3 >= 0;
  }

  static bool _samepoint(double ax, double ay, double bx, double by) =>
      ax == bx && ay == by;

  TriangulationResult _emit(int degenerate, bool exhausted, int unresolved) {
    final int floats = _work.length;
    final Float64List verts = Float64List(floats);
    for (var i = 0; i < floats; i++) {
      verts[i] = _work[i];
    }
    final Uint16List idx = Uint16List(_out.length);
    for (var i = 0; i < _out.length; i++) {
      idx[i] = _out[i];
    }
    return TriangulationResult(
      vertices: verts,
      indices: idx,
      degenerateCount: degenerate,
      budgetExhausted: exhausted,
      unresolvedVertices: unresolved,
    );
  }
}
