import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

/// Compiles the real synthetic fixture PWAD from doom_wad end to end.
///
/// This is the closest thing to an E1M1 rehearsal available without a
/// commercial IWAD: the fixture ships a genuine NODES/SEGS/SSECTORS tree built
/// by the same node builder, and contains a convex room, a concave L, a sector
/// with an island hole, mismatched two-sided heights and a sky ceiling.
void main() {
  test('fixture PWAD compiles with no gaps against the oracle', () {
    final WadSet set = DoomFixtures.wadSet();
    final WadResources res = WadResources.load(set);
    final MapData map = MapData.load(set, DoomFixtures.mapName);

    final CompiledLevel level = DoomGeometryCompiler.compile(map, res);
    final GeometryReport report = level.report;
    print(report.summary());

    expect(report.budgetExhausted, isFalse);
    expect(map.hasBsp, isTrue, reason: 'fixture must ship a real BSP tree');
    expect(level.meshes, isNotEmpty);
    expect(report.totalTriangles, 120);

    // The headline M2 number: total area disagreement across the level.
    expect(
      report.totalAreaDelta,
      lessThan(1.0),
      reason: 'BSP and oracle must agree on covered area',
    );
    expect(report.tJunctionCount, 0);
    expect(report.degenerateTriangleCount, 0);
    expect(
      report.fallbackSectors,
      isEmpty,
      reason: 'no sector should need the loop fallback',
    );
    expect(report.geometryHash, 0x73e94bc3);

    final int doorLine = map.linedefs.indexWhere(
      (Linedef line) => line.special == 1 && line.tag == 0,
    );
    expect(doorLine, greaterThanOrEqualTo(0));
    final List<WallBandRef> doorBands = level.wallBands
        .where((WallBandRef band) => band.linedef == doorLine)
        .toList();
    expect(doorBands, isNotEmpty);
    expect(
      doorBands.any((WallBandRef band) => band.top == band.bottom),
      isTrue,
      reason: 'manual door must pre-create collapsed dynamic bands',
    );
  });

  test('fixture compile is deterministic', () {
    final WadSet set = DoomFixtures.wadSet();
    final WadResources res = WadResources.load(set);
    final MapData map = MapData.load(set, DoomFixtures.mapName);
    final int a = DoomGeometryCompiler.compile(map, res).report.geometryHash;
    final int b = DoomGeometryCompiler.compile(map, res).report.geometryHash;
    expect(a, b);
  });
}
