import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

void main() {
  test('playthrough fixture is isolated and carries the required route', () {
    final MapData map = DoomPlaythroughFixture.map();

    expect(map.name, 'MAP97');
    expect(map.sectors, hasLength(6));
    expect(map.things, hasLength(5));
    expect(
      map.sectors.where((Sector sector) => sector.special == 9),
      hasLength(1),
    );
    expect(
      map.linedefs.where((Linedef line) => line.special == 32),
      hasLength(1),
    );
    expect(
      map.linedefs.where((Linedef line) => line.special == 21),
      hasLength(1),
    );
    expect(
      map.linedefs.where((Linedef line) => line.special == 11),
      hasLength(1),
    );
    expect(map.blockmap, isNull);
    expect(map.hasBsp, isFalse);

    // Building MAP97 must not mutate the cached, byte-pinned MAP01 fixture.
    final int before = DoomFixtures.hash();
    DoomPlaythroughFixture.map();
    expect(DoomFixtures.hash(), before);
    expect(
      WadResources.load(DoomPlaythroughFixture.resourceWads()).spriteNames,
      contains('BKEYA0'),
    );
  });
}
