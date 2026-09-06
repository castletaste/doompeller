import 'package:doom_core/doom_core.dart';
import 'package:test/test.dart';

void main() {
  test('normal episode and secret detour terminate at E1M8', () {
    final List<String> maps = <String>['E1M1'];
    while (true) {
      final String? next = DoomEpisode.nextMap(maps.last, secret: false);
      if (next == null) break;
      maps.add(next);
      expect(maps.length, lessThanOrEqualTo(8));
    }
    expect(maps, List<String>.generate(8, (i) => 'E1M${i + 1}'));
    expect(DoomEpisode.nextMap('E1M3', secret: true), 'E1M9');
    expect(DoomEpisode.nextMap('E1M9', secret: false), 'E1M4');
    expect(DoomEpisode.nextMap('E1M8', secret: true), isNull);
    expect(DoomEpisode.nextMap('MAP01', secret: false), isNull);
    expect(DoomEpisode.nextMap('E2M1', secret: false), isNull);
  });

  test('loadout snapshots ownership and rejects a dead entry', () {
    final Set<Weapon> weapons = <Weapon>{Weapon.fist, Weapon.pistol};
    final PlayerLoadout loadout = PlayerLoadout(
      health: 70,
      armor: 20,
      ammo: const Ammo(),
      weapon: Weapon.pistol,
      ownedWeapons: weapons,
    );
    weapons.add(Weapon.shotgun);
    expect(loadout.ownedWeapons, isNot(contains(Weapon.shotgun)));
    expect(() => loadout.ownedWeapons.clear(), throwsUnsupportedError);
    expect(
      () => PlayerLoadout(
        health: 0,
        armor: 20,
        ammo: const Ammo(),
        weapon: Weapon.pistol,
        ownedWeapons: weapons,
      ),
      throwsArgumentError,
    );
  });
}
