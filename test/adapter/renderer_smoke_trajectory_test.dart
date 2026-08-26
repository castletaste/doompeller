import 'package:doom_geometry/doom_geometry.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/renderer_smoke_trajectory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final fixture in <({String name, WadSet set, String mapName})>[
    (
      name: 'fixture',
      set: DoomFixtures.wadSet(),
      mapName: DoomFixtures.mapName,
    ),
    (
      name: 'scale fixture',
      set: DoomScaleFixture.wadSet(),
      mapName: DoomScaleFixture.mapName,
    ),
  ]) {
    test('${fixture.name} trajectory stays on real floor triangles', () {
      final map = MapData.load(fixture.set, fixture.mapName);
      final resources = WadResources.load(fixture.set);
      final level = DoomGeometryCompiler.compile(map, resources);
      final floors = <double>[
        for (final sector in map.sectors) sector.floorHeight.toDouble(),
      ];
      final trajectory = RendererSmokeTrajectory.fromLevel(map, level);

      for (var legIndex = 0; legIndex < trajectory.legs.length; legIndex++) {
        final leg = trajectory.legs[legIndex];
        for (var step = 0; step <= 20; step++) {
          final double seconds =
              legIndex * RendererSmokeTrajectory.legSeconds + step / 20;
          final pose = trajectory.sample(seconds, floors);
          if (step == 20) continue; // This instant starts the next valid leg.
          expect(pose.sector, leg.sector);
          expect(leg.contains(pose.x, -pose.z), isTrue);
          expect(
            pose.y,
            floors[leg.sector] + RendererSmokeTrajectory.eyeHeight,
          );
          expect(
            pose.y + 15,
            lessThanOrEqualTo(map.sectors[leg.sector].ceilingHeight),
          );
        }
      }
    });
  }

  test('scale trajectory samples rooms across the whole map', () {
    final set = DoomScaleFixture.wadSet();
    final map = MapData.load(set, DoomScaleFixture.mapName);
    final level = DoomGeometryCompiler.compile(map, WadResources.load(set));
    final trajectory = RendererSmokeTrajectory.fromLevel(map, level);

    expect(trajectory.legs, hasLength(RendererSmokeTrajectory.maxLegs));
    final sectors = trajectory.legs.map((leg) => leg.sector).toList();
    expect(sectors.first, lessThan(12));
    expect(sectors.last, greaterThanOrEqualTo(108));
  });
}
