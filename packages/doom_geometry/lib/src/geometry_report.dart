import 'dart:typed_data';

/// Structured findings from comparing the BSP result to the loop oracle.
///
/// The report is the deliverable, not a debug aid: M2's acceptance is "zero
/// gaps versus the oracle, with the report proving it", so every check that
/// could hide a gap has to surface a number here.

/// What went wrong in one sector.
enum GeometryIssue {
  /// BSP and oracle disagree on how much area the sector covers.
  areaMismatch,

  /// A triangle with no usable area was produced and dropped.
  degenerateTriangle,

  /// A vertex lies in the interior of another triangle's edge. This is the
  /// crack case: the two triangles look adjacent but rasterise with a seam.
  tJunction,

  /// Two triangles in the same sector overlap.
  overlap,

  /// An edge appears once where it should appear twice, or vice versa.
  unmatchedEdge,

  /// The sector's boundary never closed into loops.
  openLoop,

  /// A subsector's half-plane clip removed everything.
  emptyRegion,

  /// Work was cut short by the intersection-check budget.
  budgetExhausted,

  /// Ear clipping stalled, leaving part of the polygon untriangulated.
  incompleteTriangulation,
}

/// Per-sector comparison result.
class SectorFinding {
  const SectorFinding({
    required this.sector,
    required this.issues,
    required this.bspArea,
    required this.loopArea,
    required this.bspTriangles,
    required this.loopTriangles,
    required this.degenerateTriangles,
    required this.tJunctions,
    required this.unmatchedEdges,
    required this.overlaps,
    required this.emptyRegions,
    required this.usedFallback,
    this.bspEvaluated = true,
  });

  final int sector;

  /// Empty when the sector passed every check.
  final Set<GeometryIssue> issues;

  final double bspArea;
  final double loopArea;
  final int bspTriangles;
  final int loopTriangles;
  final int degenerateTriangles;
  final int tJunctions;
  final int unmatchedEdges;
  final int overlaps;
  final int emptyRegions;

  /// True when the loop oracle's geometry was emitted instead of the BSP's.
  final bool usedFallback;

  /// False when the BSP path did not run for this sector at all, either because
  /// the map has no node tree or because bspFirst was off. Without this an
  /// unrun sector would report its entire area as a gap.
  final bool bspEvaluated;

  /// Area disagreement between the two paths. Zero when only one path ran,
  /// because there is then nothing to disagree with.
  double get areaDelta => bspEvaluated ? (bspArea - loopArea).abs() : 0;

  /// Area difference relative to the oracle; 0 when the oracle found no area.
  double get relativeAreaDelta => loopArea > 0 ? areaDelta / loopArea : 0;

  bool get isClean => issues.isEmpty;

  @override
  String toString() => 'sector $sector: '
      '${issues.isEmpty ? "clean" : issues.map((GeometryIssue i) => i.name).join(",")} '
      'bsp=${bspArea.toStringAsFixed(2)} loop=${loopArea.toStringAsFixed(2)}'
      '${usedFallback ? " [fallback]" : ""}';
}

/// Whole-level geometry report.
class GeometryReport {
  const GeometryReport({
    required this.map,
    required this.findings,
    required this.fallbackSectors,
    required this.totalTriangles,
    required this.totalVertices,
    required this.meshCount,
    required this.atlasPages,
    required this.subsectorCount,
    required this.emptySubsectors,
    required this.maxBspDepth,
    required this.intersectionChecks,
    required this.intersectionBudget,
    required this.bspFirst,
    required this.validated,
    required this.budgetExhausted,
    required this.missingTextures,
    required this.geometryHash,
    required this.compileMicroseconds,
    this.repairedTJunctionVertices = 0,
    this.repairedRegions = 0,
  });

  final String map;

  /// One entry per sector, index-aligned with the map's sectors.
  final List<SectorFinding> findings;

  /// Sectors whose BSP geometry failed validation and were emitted from the
  /// loop oracle instead. Never silently dropped.
  final List<int> fallbackSectors;

  final int totalTriangles;
  final int totalVertices;
  final int meshCount;
  final int atlasPages;
  final int subsectorCount;
  final int emptySubsectors;
  final int maxBspDepth;

  /// Intersection checks actually spent, against the configured budget. This is
  /// the bounded-time evidence.
  final int intersectionChecks;
  final int intersectionBudget;

  final bool bspFirst;
  final bool validated;

  /// True when a budget ran out; results are usable but not proven complete.
  final bool budgetExhausted;

  /// Texture names referenced by the map but absent from the WAD set.
  final List<String> missingTextures;

  /// Order-independent hash over the emitted geometry, for regression pinning.
  final int geometryHash;

  final int compileMicroseconds;

  /// Vertices inserted to close T-junction cracks between subsectors.
  ///
  /// A non-zero count is healthy, not a warning: it is the number of latent
  /// seams that were found and welded shut before they could show up on screen.
  final int repairedTJunctionVertices;

  /// Subsector polygons that needed at least one such insertion.
  final int repairedRegions;

  /// True when every sector passed and nothing needed a fallback.
  bool get isClean {
    if (fallbackSectors.isNotEmpty || budgetExhausted) {
      return false;
    }
    for (var i = 0; i < findings.length; i++) {
      if (!findings[i].isClean) {
        return false;
      }
    }
    return true;
  }

  /// Total absolute area disagreement across the level: the headline "gaps"
  /// number M2 is judged on.
  double get totalAreaDelta {
    var sum = 0.0;
    for (var i = 0; i < findings.length; i++) {
      sum += findings[i].areaDelta;
    }
    return sum;
  }

  int get sectorsWithIssues {
    var count = 0;
    for (var i = 0; i < findings.length; i++) {
      if (!findings[i].isClean) {
        count++;
      }
    }
    return count;
  }

  int get tJunctionCount {
    var count = 0;
    for (var i = 0; i < findings.length; i++) {
      count += findings[i].tJunctions;
    }
    return count;
  }

  int get degenerateTriangleCount {
    var count = 0;
    for (var i = 0; i < findings.length; i++) {
      count += findings[i].degenerateTriangles;
    }
    return count;
  }

  /// Sectors that failed, worst area delta first, for triage.
  List<SectorFinding> worstSectors([int limit = 10]) {
    final List<SectorFinding> bad = <SectorFinding>[
      for (final SectorFinding f in findings)
        if (!f.isClean) f,
    ]..sort((SectorFinding a, SectorFinding b) =>
        b.areaDelta.compareTo(a.areaDelta));
    return bad.length <= limit ? bad : bad.sublist(0, limit);
  }

  String summary() {
    final StringBuffer sb = StringBuffer()
      ..writeln('GeometryReport $map')
      ..writeln('  mode            : ${bspFirst ? "bsp-first" : "loops-only"}'
          '${validated ? " (validated)" : " (unvalidated)"}')
      ..writeln('  meshes          : $meshCount over $atlasPages atlas page(s)')
      ..writeln('  triangles       : $totalTriangles')
      ..writeln('  vertices        : $totalVertices')
      ..writeln('  subsectors      : $subsectorCount ($emptySubsectors empty)')
      ..writeln('  max bsp depth   : $maxBspDepth')
      ..writeln('  area delta      : ${totalAreaDelta.toStringAsFixed(4)}')
      ..writeln('  t-junctions     : $tJunctionCount')
      ..writeln('  tjunc repaired  : $repairedTJunctionVertices vertices '
          'in $repairedRegions region(s)')
      ..writeln('  degenerate tris : $degenerateTriangleCount')
      ..writeln('  fallback sectors: ${fallbackSectors.length}')
      ..writeln('  checks          : $intersectionChecks / $intersectionBudget')
      ..writeln('  hash            : 0x${geometryHash.toRadixString(16)}')
      ..writeln('  compile         : $compileMicroseconds us');
    if (missingTextures.isNotEmpty) {
      sb.writeln('  missing textures: ${missingTextures.join(", ")}');
    }
    for (final SectorFinding f in worstSectors()) {
      sb.writeln('  ! $f');
    }
    return sb.toString();
  }

  @override
  String toString() => summary();
}

/// Triangle soup for one sector, in map space, as produced by either path.
///
/// Flat storage: [xy] holds vertex coordinates and [indices] triangles, so a
/// whole sector is two typed arrays rather than thousands of objects.
class SectorMesh2D {
  const SectorMesh2D(this.xy, this.indices);

  SectorMesh2D.empty()
      : xy = Float64List(0),
        indices = Uint32List(0);

  final Float64List xy;
  final Uint32List indices;

  int get vertexCount => xy.length >> 1;
  int get triangleCount => indices.length ~/ 3;

  double get area {
    var sum = 0.0;
    for (var t = 0; t < indices.length; t += 3) {
      final int a = indices[t] * 2;
      final int b = indices[t + 1] * 2;
      final int c = indices[t + 2] * 2;
      sum += ((xy[b] - xy[a]) * (xy[c + 1] - xy[a + 1]) -
              (xy[c] - xy[a]) * (xy[b + 1] - xy[a + 1]))
          .abs();
    }
    return sum * 0.5;
  }
}
