import 'dart:math' as math;
import 'dart:typed_data';

/// Shared 2D geometry kernel.
///
/// Everything here works on flat [Float64List] coordinate runs (x, y, x, y ...)
/// rather than point objects: the compiler triangulates thousands of polygons
/// per level and allocating a Point per vertex dominates the profile. No
/// closures are taken per triangle or per edge in any routine below.

/// Mutable, growable polygon in flat xy storage.
///
/// Reused across clip passes so a full BSP descent allocates two buffers total
/// instead of one per partition plane.
class PolyBuffer {
  PolyBuffer([int capacity = 16])
    : _xy = Float64List(capacity < 4 ? 8 : capacity * 2),
      _length = 0;

  Float64List _xy;
  int _length;

  /// Number of vertices currently held.
  int get length => _length;

  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length != 0;

  double x(int i) => _xy[i * 2];
  double y(int i) => _xy[i * 2 + 1];

  void clear() => _length = 0;

  void add(double px, double py) {
    if ((_length + 1) * 2 > _xy.length) {
      final Float64List grown = Float64List(_xy.length * 2);
      grown.setRange(0, _length * 2, _xy);
      _xy = grown;
    }
    _xy[_length * 2] = px;
    _xy[_length * 2 + 1] = py;
    _length++;
  }

  void setFrom(PolyBuffer other) {
    if (other._length * 2 > _xy.length) {
      _xy = Float64List(other._length * 2);
    }
    _xy.setRange(0, other._length * 2, other._xy);
    _length = other._length;
  }

  /// Copies out a tight snapshot.
  ///
  /// This must be a copy, not a view: the buffers are pooled and reused across
  /// the whole BSP descent, so a view would alias storage that the next leaf
  /// immediately overwrites.
  Float64List toFloat64List() {
    final Float64List out = Float64List(_length * 2);
    out.setRange(0, _length * 2, _xy);
    return out;
  }
}

/// Snaps [value] to a 1/[grid] lattice.
///
/// Two subsectors clipping the same partition plane must land on identical
/// coordinates or their shared edge cracks. Rounding both to a common lattice
/// makes that exact rather than approximate.
double snapCoord(double value, double grid) {
  final double scaled = value * grid;
  // roundToDouble keeps the result finite for huge inputs, where toInt() would
  // overflow, and is the same halfway rule on every platform.
  return scaled.roundToDouble() / grid;
}

/// Twice the signed area of the polygon in [xy] over [count] vertices.
///
/// Positive means counter-clockwise in a y-up frame. Working in doubled area
/// avoids a division and keeps integer inputs exact.
double signedArea2(Float64List xy, int count) {
  if (count < 3) {
    return 0;
  }
  var sum = 0.0;
  var jx = xy[(count - 1) * 2];
  var jy = xy[(count - 1) * 2 + 1];
  for (var i = 0; i < count; i++) {
    final double ix = xy[i * 2];
    final double iy = xy[i * 2 + 1];
    sum += (jx - ix) * (jy + iy);
    jx = ix;
    jy = iy;
  }
  return sum;
}

/// Absolute polygon area.
double polygonArea(Float64List xy, int count) =>
    signedArea2(xy, count).abs() * 0.5;

/// Signed distance from (px, py) to the line through (ax, ay) with direction
/// (dx, dy), scaled by the direction's length.
///
/// Sign convention, used identically for BSP nodes and for segs: POSITIVE is
/// the RIGHT (front) side of the directed line. Walking a boundary that keeps
/// its interior on the positive side therefore traverses clockwise, which is
/// the order Doom stores a subsector's segs in.
double sideOf(
  double px,
  double py,
  double ax,
  double ay,
  double dx,
  double dy,
) => (px - ax) * dy - (py - ay) * dx;

/// Clips [input] to the half-plane on one side of a line, Sutherland-Hodgman.
///
/// The line passes through (ax, ay) along (dx, dy). When [keepPositive] is true
/// the right/front half-plane survives, otherwise the left/back one does.
/// Points within [epsilon] of the plane are treated as lying on it and pass
/// through unmoved, which is what stops coincident subsector edges from
/// drifting apart into a crack.
///
/// Emitted intersection points are snapped to the 1/[grid] lattice. Writes into
/// [output], which is cleared first; [input] and [output] must differ.
void clipHalfPlane(
  PolyBuffer input,
  PolyBuffer output, {
  required double ax,
  required double ay,
  required double dx,
  required double dy,
  required bool keepPositive,
  required double epsilon,
  required double grid,
}) {
  output.clear();
  final int n = input.length;
  if (n == 0) {
    return;
  }
  // Normalise the plane so epsilon is a real distance rather than a distance
  // times an arbitrary direction length.
  final double len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) {
    // Degenerate partition: it selects no half-plane, so pass the polygon
    // through untouched instead of erasing it.
    output.setFrom(input);
    return;
  }
  final double invLen = 1.0 / len;
  final double ndx = dx * invLen;
  final double ndy = dy * invLen;
  final double sign = keepPositive ? 1.0 : -1.0;

  var px = input.x(n - 1);
  var py = input.y(n - 1);
  var pd = sideOf(px, py, ax, ay, ndx, ndy) * sign;
  if (pd.abs() <= epsilon) {
    pd = 0;
  }
  for (var i = 0; i < n; i++) {
    final double cx = input.x(i);
    final double cy = input.y(i);
    var cd = sideOf(cx, cy, ax, ay, ndx, ndy) * sign;
    if (cd.abs() <= epsilon) {
      cd = 0;
    }
    if (cd >= 0) {
      if (pd < 0) {
        final double t = pd / (pd - cd);
        output.add(
          snapCoord(px + (cx - px) * t, grid),
          snapCoord(py + (cy - py) * t, grid),
        );
      }
      output.add(cx, cy);
    } else if (pd > 0) {
      final double t = pd / (pd - cd);
      output.add(
        snapCoord(px + (cx - px) * t, grid),
        snapCoord(py + (cy - py) * t, grid),
      );
    }
    px = cx;
    py = cy;
    pd = cd;
  }
}

/// Drops consecutive duplicates and collinear spikes from [poly] in place.
///
/// Clipping a convex region against many planes leaves slivers: vertices that
/// coincide, and vertices whose neighbours are collinear through them. Both
/// become zero-area triangles downstream, so they are removed here rather than
/// filtered per triangle later.
void cleanPolygon(PolyBuffer poly, double epsilon, [PolyBuffer? scratch]) {
  final PolyBuffer work = scratch ?? PolyBuffer(poly.length);
  // Pass 1: coincident vertices.
  work.clear();
  for (var i = 0; i < poly.length; i++) {
    final double cx = poly.x(i);
    final double cy = poly.y(i);
    if (work.isNotEmpty) {
      final double lx = work.x(work.length - 1);
      final double ly = work.y(work.length - 1);
      if ((cx - lx).abs() <= epsilon && (cy - ly).abs() <= epsilon) {
        continue;
      }
    }
    work.add(cx, cy);
  }
  while (work.length > 1) {
    final double fx = work.x(0);
    final double fy = work.y(0);
    final double lx = work.x(work.length - 1);
    final double ly = work.y(work.length - 1);
    if ((fx - lx).abs() <= epsilon && (fy - ly).abs() <= epsilon) {
      work._length--;
    } else {
      break;
    }
  }
  if (work.length < 3) {
    poly.setFrom(work);
    return;
  }
  // Pass 2: collinear vertices. Uses the unnormalised cross product against a
  // length-scaled tolerance so long thin wedges are not mistaken for spikes.
  poly.clear();
  final int n = work.length;
  for (var i = 0; i < n; i++) {
    final double ax = work.x((i - 1 + n) % n);
    final double ay = work.y((i - 1 + n) % n);
    final double bx = work.x(i);
    final double by = work.y(i);
    final double cx = work.x((i + 1) % n);
    final double cy = work.y((i + 1) % n);
    final double cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    final double scale =
        math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) +
        math.sqrt((cx - bx) * (cx - bx) + (cy - by) * (cy - by));
    if (cross.abs() <= epsilon * (scale + epsilon)) {
      continue;
    }
    poly.add(bx, by);
  }
  if (poly.length < 3) {
    poly.clear();
  }
}

/// Winding-number containment test for a point against a closed loop.
///
/// Winding rather than even-odd because Doom sectors legitimately nest, and a
/// crossing count misclassifies a hole inside a hole.
bool pointInLoop(Float64List xy, int count, double px, double py) {
  if (count < 3) {
    return false;
  }
  var winding = 0;
  var ax = xy[(count - 1) * 2];
  var ay = xy[(count - 1) * 2 + 1];
  for (var i = 0; i < count; i++) {
    final double bx = xy[i * 2];
    final double by = xy[i * 2 + 1];
    if (ay <= py) {
      if (by > py && (bx - ax) * (py - ay) - (px - ax) * (by - ay) > 0) {
        winding++;
      }
    } else {
      if (by <= py && (bx - ax) * (py - ay) - (px - ax) * (by - ay) < 0) {
        winding--;
      }
    }
    ax = bx;
    ay = by;
  }
  return winding != 0;
}

/// Squared distance from (px, py) to segment (ax, ay)-(bx, by), plus the
/// parametric position of the closest point in [outT] slot 0.
double distanceToSegmentSquared(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
  Float64List outT,
) {
  final double vx = bx - ax;
  final double vy = by - ay;
  final double lenSq = vx * vx + vy * vy;
  var t = 0.0;
  if (lenSq > 0) {
    t = ((px - ax) * vx + (py - ay) * vy) / lenSq;
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }
  }
  outT[0] = t;
  final double cx = ax + vx * t - px;
  final double cy = ay + vy * t - py;
  return cx * cx + cy * cy;
}
