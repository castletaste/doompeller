import 'dart:typed_data';

import 'bsp_regions.dart';
import 'geometry_options.dart';
import 'polygon.dart';
import 'triangulate.dart';

/// T-junction repair over reconstructed BSP regions.
///
/// ## The problem
///
/// A BSP partition can end where a wall ends, so one subsector's edge runs the
/// full length of a partition while its neighbour across that partition is
/// split into two cells by a second partition. The long edge then has a
/// neighbour's corner sitting in its interior with no matching vertex of its
/// own. The two polygons share the same geometric boundary, but the rasteriser
/// interpolates the long edge as a single straight span and the short pair as
/// two, and floating-point rounding leaves a hairline of background showing
/// between them. That is a T-junction crack, and it is the specific failure
/// mode BSP-first geometry was flagged as risky for.
///
/// ## The repair
///
/// For every region edge, find the vertices of OTHER regions that lie strictly
/// inside it and insert them. The polygon keeps exactly the same shape and area
/// (inserted points are collinear by definition), it stays convex, so fan
/// triangulation is still exact, and now both sides of every shared boundary
/// have vertices at the same positions. Rounding then moves both sides
/// identically and the crack cannot open.
///
/// ## Cost
///
/// Candidate vertices come from a uniform spatial hash rather than a scan of
/// every vertex, so the pass is near-linear in practice, and every inner step
/// is charged to the [CheckBudget] so hostile input stays bounded.

/// Outcome of a repair pass.
class TJunctionRepairResult {
  const TJunctionRepairResult({
    required this.regions,
    required this.insertedVertices,
    required this.repairedRegions,
    required this.budgetExhausted,
  });

  /// Regions with the missing vertices inserted.
  final List<BspRegion> regions;

  /// Total vertices added across the level.
  final int insertedVertices;

  /// Number of regions that needed at least one insertion.
  final int repairedRegions;

  final bool budgetExhausted;
}

/// Cell size of the vertex hash, in map units.
///
/// Doom rooms are tens to hundreds of units across, so 64 keeps buckets small
/// without making a long edge sweep an unreasonable number of cells.
const double _cellSize = 64.0;

/// Inserts missing collinear vertices so shared edges match on both sides.
///
/// Repeats until no edge gains a vertex. One pass is not always enough: a
/// vertex inserted into a long edge can itself lie on a THIRD region's edge
/// that previously had no reason to know about it, so closing one crack can
/// expose another. The cascade is short (each pass strictly increases the
/// vertex count of a bounded polygon set, and real maps settle in one or two)
/// but it has to run to a fixed point or a seam survives. [maxPasses] bounds
/// it regardless, and the budget bounds it further.
TJunctionRepairResult repairTJunctions(
  List<BspRegion> regions,
  GeometryOptions options,
  CheckBudget budget, {
  int maxPasses = 4,
}) {
  var current = regions;
  var totalInserted = 0;
  var totalRepaired = 0;
  var exhausted = false;
  for (var pass = 0; pass < maxPasses; pass++) {
    final TJunctionRepairResult result = _repairOnce(current, options, budget);
    current = result.regions;
    totalInserted += result.insertedVertices;
    if (result.repairedRegions > totalRepaired) {
      totalRepaired = result.repairedRegions;
    }
    exhausted = exhausted || result.budgetExhausted;
    if (result.insertedVertices == 0 || exhausted) {
      break;
    }
  }
  return TJunctionRepairResult(
    regions: current,
    insertedVertices: totalInserted,
    repairedRegions: totalRepaired,
    budgetExhausted: exhausted,
  );
}

TJunctionRepairResult _repairOnce(
  List<BspRegion> regions,
  GeometryOptions options,
  CheckBudget budget,
) {
  if (regions.isEmpty) {
    return TJunctionRepairResult(
      regions: regions,
      insertedVertices: 0,
      repairedRegions: 0,
      budgetExhausted: false,
    );
  }

  // 1. Unique vertex positions, hashed by cell AND sector.
  //
  // Candidates are kept per sector. A floor only ever cracks against another
  // part of the SAME floor: two subsectors of one sector are one continuous
  // surface and must share a triangulation, while two different sectors are
  // separate surfaces at different heights with a wall between them. Mixing
  // them would insert a neighbour's corner into this sector's outer boundary,
  // which changes nothing visually and makes the validator report a crack that
  // does not exist.
  final Map<int, int> unique = <int, int>{};
  final List<double> px = <double>[];
  final List<double> py = <double>[];
  final Map<int, List<int>> grid = <int, List<int>>{};

  for (var r = 0; r < regions.length; r++) {
    final BspRegion region = regions[r];
    for (var i = 0; i < region.vertexCount; i++) {
      final double x = region.xy[i * 2];
      final double y = region.xy[i * 2 + 1];
      final int key = _positionKey(x, y) * 65536 + (region.sector & 0xFFFF);
      final int existing = unique.putIfAbsent(key, () => px.length);
      if (existing == px.length) {
        px.add(x);
        py.add(y);
        (grid[_cellKey(x, y, region.sector)] ??= <int>[]).add(existing);
      }
    }
  }

  // 2. Walk every edge and insert any vertex lying in its interior.
  final List<BspRegion> out = <BspRegion>[];
  final double eps = options.epsilon;
  final double epsSq = eps * eps;
  final Float64List tSlot = Float64List(1);
  final List<double> rebuilt = <double>[];
  final List<int> hits = <int>[];
  final List<double> hitT = <double>[];
  var inserted = 0;
  var repaired = 0;
  var exhausted = false;

  for (var r = 0; r < regions.length; r++) {
    final BspRegion region = regions[r];
    final int n = region.vertexCount;
    if (n < 3 || exhausted) {
      out.add(region);
      continue;
    }
    rebuilt.clear();
    var added = 0;

    for (var i = 0; i < n; i++) {
      final int j = (i + 1) % n;
      final double ax = region.xy[i * 2];
      final double ay = region.xy[i * 2 + 1];
      final double bx = region.xy[j * 2];
      final double by = region.xy[j * 2 + 1];
      rebuilt
        ..add(ax)
        ..add(ay);

      hits.clear();
      hitT.clear();
      final int cx0 = ((ax < bx ? ax : bx) - eps) ~/ _cellSize - 1;
      final int cx1 = ((ax > bx ? ax : bx) + eps) ~/ _cellSize + 1;
      final int cy0 = ((ay < by ? ay : by) - eps) ~/ _cellSize - 1;
      final int cy1 = ((ay > by ? ay : by) + eps) ~/ _cellSize + 1;

      for (var cx = cx0; cx <= cx1 && !exhausted; cx++) {
        for (var cy = cy0; cy <= cy1; cy++) {
          final List<int>? bucket = grid[_rawCellKey(cx, cy, region.sector)];
          if (bucket == null) {
            continue;
          }
          for (var k = 0; k < bucket.length; k++) {
            if (!budget.spend()) {
              exhausted = true;
              break;
            }
            final int p = bucket[k];
            final double vx = px[p];
            final double vy = py[p];
            if ((vx - ax).abs() <= eps && (vy - ay).abs() <= eps) {
              continue;
            }
            if ((vx - bx).abs() <= eps && (vy - by).abs() <= eps) {
              continue;
            }
            final double distSq = distanceToSegmentSquared(
              vx,
              vy,
              ax,
              ay,
              bx,
              by,
              tSlot,
            );
            final double t = tSlot[0];
            if (distSq <= epsSq && t > 0 && t < 1) {
              hits.add(p);
              hitT.add(t);
            }
          }
        }
      }
      if (hits.isEmpty) {
        continue;
      }
      // Insert in order along the edge so winding is preserved.
      _sortByT(hits, hitT);
      for (var h = 0; h < hits.length; h++) {
        final int p = hits[h];
        rebuilt
          ..add(px[p])
          ..add(py[p]);
        added++;
      }
    }

    if (added == 0) {
      out.add(region);
      continue;
    }
    inserted += added;
    repaired++;
    out.add(
      BspRegion(
        subsector: region.subsector,
        sector: region.sector,
        xy: Float64List.fromList(rebuilt),
        depth: region.depth,
        clippedToEmpty: false,
        segCount: region.segCount,
      ),
    );
  }

  return TJunctionRepairResult(
    regions: out,
    insertedVertices: inserted,
    repairedRegions: repaired,
    budgetExhausted: exhausted,
  );
}

/// Insertion sort on the parallel hit arrays; runs are one or two entries in
/// practice, so this beats allocating index objects to hand to a comparator.
void _sortByT(List<int> hits, List<double> hitT) {
  for (var i = 1; i < hits.length; i++) {
    final int hv = hits[i];
    final double tv = hitT[i];
    var j = i - 1;
    while (j >= 0 && hitT[j] > tv) {
      hits[j + 1] = hits[j];
      hitT[j + 1] = hitT[j];
      j--;
    }
    hits[j + 1] = hv;
    hitT[j + 1] = tv;
  }
}

/// Exact-position key; clipped coordinates are already snapped, so coincident
/// points are bit-identical and a 1/1024 lattice never merges distinct ones.
int _positionKey(double x, double y) {
  final int ix = (x * 1024.0).round() + (1 << 27);
  final int iy = (y * 1024.0).round() + (1 << 27);
  return ix * (1 << 28) + iy;
}

int _cellKey(double x, double y, int sector) =>
    _rawCellKey(x ~/ _cellSize, y ~/ _cellSize, sector);

int _rawCellKey(int cx, int cy, int sector) =>
    (cx * 1048576 + cy) * 65536 + (sector & 0xFFFF);
