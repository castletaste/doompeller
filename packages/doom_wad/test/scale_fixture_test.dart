import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

void main() {
  test('E1M1-scale fixture is deterministic, WAD-shaped, and BSP-backed', () {
    final ScaleFixtureConfig config = ScaleFixtureConfig.e1m1Scale;
    final WadFile wad = DoomScaleFixture.wad(config);
    final MapData map = DoomScaleFixture.map(config);
    final WadResources resources = WadResources.load(
      DoomScaleFixture.wadSet(config),
    );

    expect(wad.kind, WadKind.pwad);
    expect(map.name, DoomScaleFixture.mapName);
    expect(map.sectors.length, config.sectorCount);
    expect(map.linedefs.length, greaterThanOrEqualTo(470));
    expect(map.vertices.length, greaterThanOrEqualTo(600));
    expect(map.hasBsp, isTrue);
    expect(map.segs, isNotEmpty);
    expect(map.subsectors, isNotEmpty);
    expect(map.nodes, isNotEmpty);
    expect(map.blockmap, isNotNull);
    expect(map.linedefs.where((Linedef line) => line.isTwoSided), isNotEmpty);
    expect(map.linedefs.where((Linedef line) => !line.isTwoSided), isNotEmpty);
    expect(
      map.sidedefs.where((Sidedef side) => side.middleTexture != '-'),
      isNotEmpty,
    );
    expect(
      map.sectors.map((Sector sector) => sector.floorHeight).toSet().length,
      greaterThan(1),
    );
    expect(
      map.sectors.map((Sector sector) => sector.floorFlat).toSet().length,
      greaterThanOrEqualTo(20),
    );
    expect(
      map.sidedefs
          .map((Sidedef side) => side.middleTexture)
          .where((String name) => name != '-')
          .toSet()
          .length,
      greaterThanOrEqualTo(config.textureCount),
    );
    expect(resources.textureNames.length, config.textureCount);
    expect(resources.flatNames.length, config.flatCount);
    final ScaleFixtureConfig regenerated = ScaleFixtureConfig();
    final bytes = DoomScaleFixture.pwadBytes(regenerated);
    expect(bytes, orderedEquals(DoomScaleFixture.pwadBytes(regenerated)));
    expect(fnv1a64(bytes), 2322756372708573354);
  });
}
