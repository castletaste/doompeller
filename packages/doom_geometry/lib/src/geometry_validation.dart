import 'dart:typed_data';

import 'geometry_options.dart';
import 'geometry_report.dart';
import 'polygon.dart';
import 'triangulate.dart';

/// Compares BSP geometry against the loop oracle and decides what to emit.
///
/// The comparison is deliberately several independent checks rather than one.
/// Equal area does not mean equal shape: a sector can lose a wedge in one place
/// and gain it in another and still balance. So area is checked alongside edge
/// adjacency, T-junctions and overlap, and any one of them can fail a sector.
///
/// Cost is bounded. Every quadratic step is charged to a [CheckBudget] and the
/// candidate sets are narrowed by a uniform spatial grid first, so a large map
/// does not turn the validator into the slowest part of the compile.
class GeometryValidator {
  GeometryValidator(this.options);

  final GeometryOptions options;

  /// Validates one sector's BSP triangles against the oracle's.
  SectorFinding validateSector({
    required int sector,
    required SectorMesh2D bsp,
    required SectorMesh2D loop,
    required int emptyRegions,
    required bool loopComplete,
    required bool loopClosed,
    required CheckBudget budget,
  }) {
    final Set<GeometryIssue> issues = <GeometryIssue>{};
    final double bspArea = bsp.area;
    final double loopArea = loop.area;

    if (!loopClosed) {
      issues.add(GeometryIssue.openLoop);
    }
    if (!loopComplete) {
      issues.add(GeometryIssue.incompleteTriangulation);
    }
    if (emptyRegions > 0) {
      issues.add(GeometryIssue.emptyRegion);
    }

    final double tolerance = _areaTolerance(loopArea);
    if ((bspArea - loopArea).abs() > tolerance) {
      issues.add(GeometryIssue.areaMismatch);
    }

    final int degenerate = _countDegenerate(bsp);
    if (degenerate > 0) {
      issues.add(GeometryIssue.degenerateTriangle);
    }

    final _EdgeAudit audit = _auditEdges(bsp, budget);
    if (audit.unmatched > 0) {
      issues.add(GeometryIssue.unmatchedEdge);
    }

    final int tJunctions = _countTJunctions(bsp, audit, budget);
    if (tJunctions > 0) {
      issues.add(GeometryIssue.tJunction);
    }

    final int overlaps = _countOverlaps(bsp, budget);
    if (overlaps > 0) {
      issues.add(GeometryIssue.overlap);
    }

    if (budget.exhausted) {
      issues.add(GeometryIssue.budgetExhausted);
    }

    return SectorFinding(
      sector: sector,
      issues: issues,
      bspArea: bspArea,
      loopArea: loopArea,
      bspTriangles: bsp.triangleCount,
      loopTriangles: loop.triangleCount,
      degenerateTriangles: degenerate,
      tJunctions: tJunctions,
      unmatchedEdges: audit.unmatched,
      overlaps: overlaps,
      emptyRegions: emptyRegions,
      usedFallback: false,
    );
  }

  /// Whether a finding is bad enough to prefer the oracle's geometry.
  ///
  /// Open loops and an incomplete oracle triangulation deliberately do NOT
  /// trigger a fallback: they say the oracle itself is unreliable there, so
  /// falling back would swap good geometry for worse.
  bool shouldFallBack(SectorFinding finding) {
    if (finding.issues.contains(GeometryIssue.openLoop) ||
        finding.issues.contains(GeometryIssue.incompleteTriangulation)) {
      return false;
    }
    return finding.issues.contains(GeometryIssue.areaMismatch) ||
        finding.issues.contains(GeometryIssue.tJunction) ||
        finding.issues.contains(GeometryIssue.overlap) ||
        finding.issues.contains(GeometryIssue.emptyRegion) ||
        finding.issues.contains(GeometryIssue.unmatchedEdge);
  }

  double _areaTolerance(double loopArea) {
    final double relative = loopArea * options.areaToleranceFraction;
    return relative > options.areaToleranceFloor
        ? relative
        : options.areaToleranceFloor;
  }

  int _countDegenerate(SectorMesh2D mesh) {
    var count = 0;
    final Float64List xy = mesh.xy;
    final Uint32List idx = mesh.indices;
    final double epsSq = options.epsilon * options.epsilon;
    for (var t = 0; t < idx.length; t += 3) {
      final int a = idx[t] * 2;
      final int b = idx[t + 1] * 2;
      final int c = idx[t + 2] * 2;
      final double cross = (xy[b] - xy[a]) * (xy[c + 1] - xy[a + 1]) -
          (xy[c] - xy[a]) * (xy[b + 1] - xy[a + 1]);
      if (cross.abs() <= epsSq) {
        count++;
      }
    }
    return count;
  }

  /// Counts directed edges and reports how many lack an opposing partner.
  ///
  /// In a watertight triangulation every interior edge is traversed once in
  /// each direction; boundary edges are traversed once. An interior edge with
  /// no partner is a hole, and a duplicated direction is an overlap. Vertices
  /// are keyed on their snapped coordinates, so two triangles meeting at the
  /// "same" point agree exactly.
  _EdgeAudit _auditEdges(SectorMesh2D mesh, CheckBudget budget) {
    final Uint32List idx = mesh.indices;
    final Float64List xy = mesh.xy;
    if (idx.isEmpty) {
      return const _EdgeAudit(0, <int>[], <int>[]);
    }
    final Map<int, int> vertexKey = <int, int>{};
    final Map<int, int> canonical = <int, int>{};
    final int vertexCount = mesh.vertexCount;
    for (var v = 0; v < vertexCount; v++) {
      final int key = _pointKey(xy[v * 2], xy[v * 2 + 1]);
      vertexKey[v] = canonical.putIfAbsent(key, () => canonical.length);
    }
    // Directed edge multiset keyed by (from, to).
    final Map<int, int> directed = <int, int>{};
    for (var t = 0; t < idx.length; t += 3) {
      if (!budget.spend()) {
        break;
      }
      for (var e = 0; e < 3; e++) {
        final int from = vertexKey[idx[t + e]]!;
        final int to = vertexKey[idx[t + (e + 1) % 3]]!;
        if (from == to) {
          continue;
        }
        final int key = from * 1048576 + to;
        directed[key] = (directed[key] ?? 0) + 1;
      }
    }
    // Boundary edges: those with no reverse partner. They are the only place a
    // T-junction can hide, so they are collected for the next check.
    final List<int> boundaryFrom = <int>[];
    final List<int> boundaryTo = <int>[];
    var unmatched = 0;
    directed.forEach((int key, int count) {
      final int from = key ~/ 1048576;
      final int to = key % 1048576;
      final int reverse = directed[to * 1048576 + from] ?? 0;
      if (count > 1) {
        unmatched += count - 1;
      }
      if (reverse == 0) {
        boundaryFrom.add(from);
        boundaryTo.add(to);
      }
    });
    return _EdgeAudit(unmatched, boundaryFrom, boundaryTo);
  }

  /// Detects vertices lying strictly inside another edge.
  ///
  /// Only boundary edges are tested: an interior edge already has a matching
  /// partner, so no vertex can sit in its interior without also breaking the
  /// edge audit. That reduces the search from every-edge-by-every-vertex to a
  /// small perimeter set.
  ///
  /// Candidate vertices come from THIS sector only. A neighbouring sector's
  /// corner touching this sector's outer boundary is not a crack: the two
  /// sectors are different surfaces at different heights, they are not
  /// expected to share a triangulation, and treating every such contact as a
  /// defect would flag every wall in the level. Cracks that matter are the
  /// ones inside a single continuous surface, and those are exactly what a
  /// per-sector search finds.
  int _countTJunctions(
    SectorMesh2D mesh,
    _EdgeAudit audit,
    CheckBudget budget,
  ) {
    if (audit.boundaryFrom.isEmpty) {
      return 0;
    }
    final Float64List xy = mesh.xy;
    final int vertexCount = mesh.vertexCount;
    // Canonical positions, deduplicated, so a vertex shared by six triangles is
    // tested once.
    final Map<int, int> unique = <int, int>{};
    final List<double> px = <double>[];
    final List<double> py = <double>[];
    for (var v = 0; v < vertexCount; v++) {
      final double x = xy[v * 2];
      final double y = xy[v * 2 + 1];
      final int key = _pointKey(x, y);
      if (unique.putIfAbsent(key, () => px.length) == px.length) {
        px.add(x);
        py.add(y);
      }
    }
    // The canonical ids assigned here and by the edge audit agree: both number
    // distinct lattice positions in first-seen vertex order over one mesh.
    final Float64List scratch = Float64List(1);
    final double eps = options.epsilon;
    final double epsSq = eps * eps;
    var count = 0;
    for (var e = 0; e < audit.boundaryFrom.length; e++) {
      final int fromId = audit.boundaryFrom[e];
      final int toId = audit.boundaryTo[e];
      if (fromId >= px.length || toId >= px.length) {
        continue;
      }
      final double ax = px[fromId];
      final double ay = py[fromId];
      final double bx = px[toId];
      final double by = py[toId];
      for (var p = 0; p < px.length; p++) {
        if (!budget.spend()) {
          return count;
        }
        if (p == fromId || p == toId) {
          continue;
        }
        final double vx = px[p];
        final double vy = py[p];
        // Cheap reject: outside the edge's bounding box, padded by epsilon.
        if (vx < (ax < bx ? ax : bx) - eps ||
            vx > (ax > bx ? ax : bx) + eps ||
            vy < (ay < by ? ay : by) - eps ||
            vy > (ay > by ? ay : by) + eps) {
          continue;
        }
        final double distSq =
            distanceToSegmentSquared(vx, vy, ax, ay, bx, by, scratch);
        final double t = scratch[0];
        if (distSq <= epsSq && t > 0 && t < 1) {
          count++;
        }
      }
    }
    return count;
  }

  /// Counts overlapping triangle pairs.
  ///
  /// Pairs are narrowed by a uniform grid keyed on triangle bounding boxes, so
  /// this is near-linear on real maps while still charging the budget for the
  /// pathological case. Overlap is decided by testing centroids, which catches
  /// full and partial containment without needing exact polygon intersection.
  int _countOverlaps(SectorMesh2D mesh, CheckBudget budget) {
    final Uint32List idx = mesh.indices;
    final Float64List xy = mesh.xy;
    final int triangles = mesh.triangleCount;
    if (triangles < 2) {
      return 0;
    }
    const double cell = 128.0;
    final Map<int, List<int>> grid = <int, List<int>>{};
    for (var t = 0; t < triangles; t++) {
      final int a = idx[t * 3] * 2;
      final int b = idx[t * 3 + 1] * 2;
      final int c = idx[t * 3 + 2] * 2;
      final double minX = _min3(xy[a], xy[b], xy[c]);
      final double maxX = _max3(xy[a], xy[b], xy[c]);
      final double minY = _min3(xy[a + 1], xy[b + 1], xy[c + 1]);
      final double maxY = _max3(xy[a + 1], xy[b + 1], xy[c + 1]);
      final int gx0 = (minX / cell).floor();
      final int gx1 = (maxX / cell).floor();
      final int gy0 = (minY / cell).floor();
      final int gy1 = (maxY / cell).floor();
      for (var gx = gx0; gx <= gx1; gx++) {
        for (var gy = gy0; gy <= gy1; gy++) {
          if (!budget.spend()) {
            return 0;
          }
          (grid[gx * 65536 + gy] ??= <int>[]).add(t);
        }
      }
    }
    final Set<int> reported = <int>{};
    var overlaps = 0;
    for (final List<int> bucket in grid.values) {
      if (bucket.length < 2) {
        continue;
      }
      for (var i = 0; i < bucket.length; i++) {
        for (var j = i + 1; j < bucket.length; j++) {
          if (!budget.spend()) {
            return overlaps;
          }
          final int ti = bucket[i];
          final int tj = bucket[j];
          final int pairKey = ti < tj ? ti * 1048576 + tj : tj * 1048576 + ti;
          if (!reported.add(pairKey)) {
            continue;
          }
          if (_trianglesOverlap(xy, idx, ti, tj)) {
            overlaps++;
          }
        }
      }
    }
    return overlaps;
  }

  bool _trianglesOverlap(
    Float64List xy,
    Uint32List idx,
    int ti,
    int tj,
  ) {
    // Centroid-in-other is a conservative proxy: two triangles that merely
    // share an edge or a vertex never contain each other's centroid, while any
    // real area overlap of a convex pair does for at least one of the six
    // centroid/sub-centroid probes below.
    if (_centroidInside(xy, idx, ti, tj) || _centroidInside(xy, idx, tj, ti)) {
      return true;
    }
    return false;
  }

  bool _centroidInside(Float64List xy, Uint32List idx, int inner, int outer) {
    final int a = idx[inner * 3] * 2;
    final int b = idx[inner * 3 + 1] * 2;
    final int c = idx[inner * 3 + 2] * 2;
    final double cx = (xy[a] + xy[b] + xy[c]) / 3.0;
    final double cy = (xy[a + 1] + xy[b + 1] + xy[c + 1]) / 3.0;
    final int oa = idx[outer * 3] * 2;
    final int ob = idx[outer * 3 + 1] * 2;
    final int oc = idx[outer * 3 + 2] * 2;
    return _strictlyInsideTriangle(
      cx,
      cy,
      xy[oa],
      xy[oa + 1],
      xy[ob],
      xy[ob + 1],
      xy[oc],
      xy[oc + 1],
    );
  }

  static bool _strictlyInsideTriangle(
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
    final bool negative = d1 < 0 || d2 < 0 || d3 < 0;
    final bool positive = d1 > 0 || d2 > 0 || d3 > 0;
    return !(negative && positive);
  }

  /// Position key: two points share a key exactly when they are the same point.
  ///
  /// Packed into one int rather than a string because this runs once per vertex
  /// per sector and string keys dominated the profile.
  ///
  /// The keying lattice is deliberately NOT [GeometryOptions.weldGrid]. The
  /// weld grid is tuned to be barely coarser than floating-point noise, which
  /// makes it far too fine to pack two coordinates into one integer without
  /// overflowing: at 1/65536, a coordinate of 384 already needs 25 bits, and
  /// masking it back down silently aliases distinct points onto the same key,
  /// which makes the edge audit invent duplicate edges out of nothing.
  ///
  /// [_keyScale] is fixed instead. Doom coordinates span +-32768, so a 1/1024
  /// lattice needs 27 bits signed per axis and both axes fit in 56 bits with
  /// room to spare. Coincident points are bit-identical by construction (the
  /// clipper snaps them), so they always agree, and 1/1024 of a map unit is
  /// finer than any geometry Doom can express.
  static const double _keyScale = 1024.0;
  static const int _keyBias = 1 << 27;
  static const int _keyStride = 1 << 28;

  int _pointKey(double x, double y) {
    final int ix = (x * _keyScale).round() + _keyBias;
    final int iy = (y * _keyScale).round() + _keyBias;
    return ix * _keyStride + iy;
  }

  static double _min3(double a, double b, double c) =>
      a < b ? (a < c ? a : c) : (b < c ? b : c);

  static double _max3(double a, double b, double c) =>
      a > b ? (a > c ? a : c) : (b > c ? b : c);
}

class _EdgeAudit {
  const _EdgeAudit(this.unmatched, this.boundaryFrom, this.boundaryTo);

  final int unmatched;
  final List<int> boundaryFrom;
  final List<int> boundaryTo;
}
