import 'package:doom_geometry/src/bsp_regions.dart';
import 'package:doom_geometry/src/geometry_options.dart';
import 'package:doom_geometry/src/sector_loops.dart';
import 'package:doom_geometry/src/triangulate.dart';
import 'package:doom_geometry/src/wad_types.dart';
import 'package:test/test.dart';

import 'support/synthetic_map.dart';

/// Early proof that BSP-first is viable: does clipping down the tree recover
/// the same covered area the linedef oracle computes, on a map whose SEGS
/// genuinely omit minisegs?
void main() {
  test('L-shaped room: BSP regions tile the sector without gaps', () {
    final MapBuilder b = MapBuilder('SPIKE1');
    final int s = b.sector(floorHeight: 0, ceilingHeight: 128);
    // Concave L; the node builder must cut it, and the cut edge is a miniseg
    // that never reaches SEGS.
    b.solidLoop(<int>[0, 0, 256, 0, 256, 128, 128, 128, 128, 256, 0, 256], s);
    final MapData map = b.build();

    expect(map.hasBsp, isTrue, reason: 'node builder must produce a tree');
    expect(map.subsectors.length, greaterThan(1),
        reason: 'a concave room must split into several subsectors');

    final GeometryOptions options = GeometryOptions.defaults;
    final CheckBudget budget = CheckBudget(1000000);
    final BspRegionSet regions = BspRegionBuilder(map, options).build(budget);

    expect(regions.budgetExhausted, isFalse);
    expect(regions.depthExceeded, isFalse);
    expect(regions.emptyRegions, 0, reason: 'no subsector should clip to empty');

    var bspArea = 0.0;
    for (final BspRegion r in regions.regions) {
      bspArea += r.area;
    }

    final CheckBudget loopBudget = CheckBudget(1000000);
    final List<SectorLoopResult> loops =
        SectorLoopBuilder(map, options).buildAll(loopBudget);
    expect(loops[s].isWellFormed, isTrue);

    // The L is 256x256 minus the 128x128 notch.
    expect(loops[s].area, closeTo(256 * 256 - 128 * 128, 1e-6));
    expect(bspArea, closeTo(loops[s].area, 1e-6));
  });

  test('subsector polygons cannot be closed from segs alone', () {
    // Guards the premise of the whole milestone: if the fixture ever started
    // emitting minisegs, the BSP clipper would be tested against a much easier
    // problem than the real one.
    final MapBuilder b = MapBuilder('SPIKE2');
    final int s = b.sector();
    b.solidLoop(<int>[0, 0, 256, 0, 256, 128, 128, 128, 128, 256, 0, 256], s);
    final MapData map = b.build();

    var openChains = 0;
    for (final Subsector ss in map.subsectors) {
      final Set<int> starts = <int>{};
      final Set<int> ends = <int>{};
      for (var i = 0; i < ss.segCount; i++) {
        final Seg seg = map.segs[ss.firstSeg + i];
        starts.add(seg.v1);
        ends.add(seg.v2);
      }
      if (!_setsMatch(starts, ends)) {
        openChains++;
      }
    }
    expect(openChains, greaterThan(0),
        reason: 'vanilla-shaped SEGS must leave at least one open chain');
  });

  test('a sector with a hole matches between BSP and oracle', () {
    final MapBuilder b = MapBuilder('SPIKE3');
    final int outer = b.sector(floorHeight: 0, ceilingHeight: 128);
    final int pillar = b.sector(floorHeight: 128, ceilingHeight: 128);
    b.solidLoop(<int>[0, 0, 512, 0, 512, 512, 0, 512], outer);
    // Clockwise inner ring: the pillar is the back sector, so the hole is
    // subtracted from the room.
    b.twoSidedLoop(
      <int>[192, 192, 192, 320, 320, 320, 320, 192],
      outer,
      pillar,
    );
    final MapData map = b.build();

    final GeometryOptions options = GeometryOptions.defaults;
    final BspRegionSet regions =
        BspRegionBuilder(map, options).build(CheckBudget(2000000));
    final List<SectorLoopResult> loops =
        SectorLoopBuilder(map, options).buildAll(CheckBudget(2000000));

    var bspOuter = 0.0;
    for (final BspRegion r in regions.regions) {
      if (r.sector == outer) {
        bspOuter += r.area;
      }
    }
    expect(loops[outer].area, closeTo(512 * 512 - 128 * 128, 1e-6));
    expect(bspOuter, closeTo(loops[outer].area, 1e-6));
  });
}

bool _setsMatch(Set<int> a, Set<int> b) =>
    a.length == b.length && a.containsAll(b);
