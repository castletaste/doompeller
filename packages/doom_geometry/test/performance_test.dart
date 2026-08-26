import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/synthetic_map.dart';

/// Bounded-time evidence for M2.
///
/// The acceptance criterion is "compiles in bounded time", and the thing that
/// makes geometry compilation unbounded is quadratic work: ear clipping that
/// rescans, validation that compares every triangle to every other, T-junction
/// searches that sweep every vertex against every edge. All of it is charged to
/// one [CheckBudget], so asserting on that counter measures the algorithm
/// rather than the machine, and the assertion cannot go green just because CI
/// happened to be fast.
///
/// A wall-clock bound is asserted too, but deliberately loosely: it is there to
/// catch a catastrophic regression, not to police milliseconds.
void main() {
  test('a large synthetic map compiles within a bounded number of checks', () {
    final MapData map = _largeMap(rooms: 100);

    expect(map.sectors.length, 100);
    expect(map.linedefs.length, greaterThan(400));
    expect(
      map.subsectors.length,
      greaterThan(50),
      reason: 'the node builder must actually partition this map',
    );

    final Stopwatch clock = Stopwatch()..start();
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      map,
      testTextures(),
    );
    clock.stop();

    final GeometryReport report = level.report;
    expect(
      report.budgetExhausted,
      isFalse,
      reason: 'a normal map must not exhaust the budget',
    );

    // Scale check: work must stay near-linear in map size. A quadratic
    // validator on 100 sectors and ~3000 triangles would be in the millions;
    // this bound is comfortably above the real figure and far below quadratic.
    final int checksPerSector = report.intersectionChecks ~/ map.sectors.length;
    expect(
      checksPerSector,
      lessThan(2000),
      reason:
          'checks per sector must not grow with map size: '
          '${report.intersectionChecks} total',
    );
    expect(report.intersectionChecks, lessThan(200000));

    // Loose wall-clock guard against a catastrophic regression.
    expect(clock.elapsedMilliseconds, lessThan(5000));
  });

  test('check count grows sub-quadratically with map size', () {
    final int small = _checksFor(_largeMap(rooms: 25));
    final int large = _checksFor(_largeMap(rooms: 100));

    // Four times the map must cost far less than sixteen times the work.
    // Allowing 8x leaves room for the node tree deepening while still failing
    // loudly on genuinely quadratic behaviour.
    expect(
      large,
      lessThan(small * 8),
      reason: '$small -> $large for a 4x larger map',
    );
  });

  test('the budget is a real ceiling, not a suggestion', () {
    final MapData map = _largeMap(rooms: 100);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      map,
      testTextures(),
      options: const GeometryOptions(
        limits: DoomLimits(maxIntersectionChecks: 500),
      ),
    );
    expect(level.report.budgetExhausted, isTrue);
    expect(
      level.report.intersectionChecks,
      lessThan(500 + map.sectors.length * 4),
      reason: 'work must stop promptly once the budget is gone',
    );
  });

  test('a large map still agrees with the oracle', () {
    final MapData map = _largeMap(rooms: 60);
    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      map,
      testTextures(),
    );
    final GeometryReport report = level.report;

    // Relative, because 60 rooms of area accumulate rounding.
    var totalArea = 0.0;
    for (final SectorFinding f in report.findings) {
      totalArea += f.loopArea;
    }
    expect(
      report.totalAreaDelta / totalArea,
      lessThan(1e-6),
      reason: report.summary(),
    );
    expect(report.tJunctionCount, 0);
    expect(report.degenerateTriangleCount, 0);
    expect(report.fallbackSectors, isEmpty);
  });

  test('WAD-loaded scale fixture grows sub-quadratically', () {
    final GeometryReport small = _scaleReport(
      const ScaleFixtureConfig(columns: 6, rows: 5),
    );
    final GeometryReport medium = _scaleReport(
      const ScaleFixtureConfig(columns: 10, rows: 6),
    );
    final GeometryReport large = _scaleReport(ScaleFixtureConfig.e1m1Scale);

    for (final GeometryReport report in <GeometryReport>[
      small,
      medium,
      large,
    ]) {
      expect(report.bspFirst, isTrue);
      expect(report.validated, isTrue);
      expect(report.budgetExhausted, isFalse, reason: report.summary());
      expect(
        report.intersectionChecks,
        lessThanOrEqualTo(report.intersectionBudget),
      );
    }

    // 30 -> 120 sectors is 4x input. Eight times the check count leaves room
    // for deeper BSPs but decisively rejects an O(n^2) validation pass.
    expect(
      large.intersectionChecks,
      lessThan(small.intersectionChecks * 8),
      reason:
          '${small.intersectionChecks} -> ${medium.intersectionChecks} '
          '-> ${large.intersectionChecks}',
    );
    expect(
      medium.intersectionChecks,
      lessThan(small.intersectionChecks * 3),
      reason: '${small.intersectionChecks} -> ${medium.intersectionChecks}',
    );
  });
}

int _checksFor(MapData map) => DoomGeometryCompiler.compileWithTextures(
  map,
  testTextures(),
).report.intersectionChecks;

GeometryReport _scaleReport(ScaleFixtureConfig config) {
  final WadSet set = DoomScaleFixture.wadSet(config);
  return DoomGeometryCompiler.compile(
    MapData.load(set, DoomScaleFixture.mapName),
    WadResources.load(set),
  ).report;
}

/// A grid of synthetic rooms used only as a scale fixture.
///
/// Rooms alternate floor and ceiling heights so upper and lower wall bands both
/// exist, and every room is concave so the node builder has real work to do.
MapData _largeMap({required int rooms}) {
  final MapBuilder b = MapBuilder('LARGE');
  const int pitch = 320;
  final int columns = _isqrt(rooms);

  for (var i = 0; i < rooms; i++) {
    final int gx = i % columns;
    final int gy = i ~/ columns;
    final int x = gx * pitch;
    final int y = gy * pitch;
    final int s = b.sector(
      floorHeight: (i % 4) * 16,
      ceilingHeight: 128 + (i % 3) * 32,
      floorFlat: i.isEven ? 'FLOOR0_1' : 'FLOOR4_8',
      ceilingFlat: i % 7 == 0 ? kSkyFlatName : 'CEIL1_1',
      lightLevel: 128 + (i % 5) * 16,
    );
    // Concave L so every room forces a partition.
    b.solidLoop(<int>[
      x, y, //
      x + 256, y,
      x + 256, y + 128,
      x + 128, y + 128,
      x + 128, y + 256,
      x, y + 256,
    ], s);
  }
  return b.build();
}

int _isqrt(int value) {
  var root = 1;
  while ((root + 1) * (root + 1) <= value) {
    root++;
  }
  return root;
}
