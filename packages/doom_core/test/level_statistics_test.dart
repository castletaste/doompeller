import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show testMap, twoSectors;

const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

const Thing _player = Thing(x: 32, y: 64, angle: 0, type: 1, flags: _allSkills);

void main() {
  group('level statistics', () {
    test('totalKills follows the selected skill population', () {
      final MapData map = testMap(
        things: const <Thing>[
          _player,
          Thing(x: 80, y: 64, angle: 180, type: 3004, flags: ThingFlags.easy),
          Thing(x: 96, y: 64, angle: 180, type: 3001, flags: ThingFlags.hard),
          Thing(
            x: 112,
            y: 64,
            angle: 180,
            type: 9,
            flags: ThingFlags.easy | ThingFlags.hard,
          ),
          Thing(x: 48, y: 64, angle: 0, type: 2035, flags: _allSkills),
        ],
      );

      final GameState easy = GameState.start(
        map,
        const GameConfig(skill: Skill.easy, monsters: false),
      );
      final GameState medium = GameState.start(
        map,
        const GameConfig(skill: Skill.medium, monsters: false),
      );
      final GameState hard = GameState.start(
        map,
        const GameConfig(skill: Skill.hard, monsters: false),
      );

      expect(easy.totalKills, 2);
      expect(medium.totalKills, 0);
      expect(hard.totalKills, 2);
    });

    test('killCount grows once for countKill actors, never for a barrel', () {
      final GameState barrel = GameState.start(
        testMap(
          things: const <Thing>[
            _player,
            Thing(x: 48, y: 64, angle: 0, type: 2035, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
        seed: 3,
      );
      for (int i = 0; i < 80; i++) {
        barrel.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(barrel.player.health, 0);
      expect(barrel.totalKills, 0);
      expect(barrel.killCount, 0);

      final GameState monster = GameState.start(
        testMap(
          things: const <Thing>[
            _player,
            Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
        seed: 3,
      );
      for (int i = 0; i < 80; i++) {
        monster.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(monster.player.health, greaterThan(0));
      expect(monster.killCount, 1);
      for (int i = 0; i < 3; i++) {
        monster.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(monster.killCount, 1);
    });

    test('only vanilla count-item pickups contribute to item tally', () {
      final GameState game = GameState.start(
        testMap(
          things: const <Thing>[
            Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2014, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2015, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2013, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 83, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 8, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2022, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2023, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2024, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2025, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2026, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2045, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2011, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2012, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2018, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2007, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2001, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 5, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
      );

      // Vanilla 1.9 counts these nine bonuses/powerups, but neither the
      // backpack nor the radiation suit contributes to the item percentage.
      expect(game.totalItems, 9);
      expect(game.itemCount, 0);
      game.runTic(TicCmd.empty);
      expect(game.itemCount, 9);
    });

    test('totalSecrets ignores an unreachable secret in the replay hash', () {
      // Sector 1 has no sidedef and is unreachable, so changing only its
      // static secret classification cannot affect any future tic.
      final GameState ordinary = GameState.start(
        testMap(sectors: twoSectors()),
        const GameConfig(monsters: false),
      );
      final GameState secret = GameState.start(
        testMap(sectors: twoSectors(backSpecial: 9)),
        const GameConfig(monsters: false),
      );

      expect(ordinary.totalSecrets, 0);
      expect(secret.totalSecrets, 1);
      expect(ordinary.hashState(), secret.hashState());
    });

    test('item counters do not affect otherwise equivalent replay hashes', () {
      List<Thing> pickups(int type) => <Thing>[
        const Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
        for (int i = 0; i < 100; i++)
          const Thing(x: 64, y: 64, angle: 0, type: 2014, flags: _allSkills),
        const Thing(x: 64, y: 64, angle: 0, type: 5, flags: _allSkills),
        Thing(x: 64, y: 64, angle: 0, type: type, flags: _allSkills),
      ];

      final GameState countItem = GameState.start(
        testMap(things: pickups(2014)),
        const GameConfig(monsters: false),
      );
      final GameState normalItem = GameState.start(
        testMap(things: pickups(5)),
        const GameConfig(monsters: false),
      );
      countItem.runTic(TicCmd.empty);
      normalItem.runTic(TicCmd.empty);

      expect(countItem.player.health, normalItem.player.health);
      expect(countItem.player.keys, normalItem.player.keys);
      expect(countItem.mobjs.length, normalItem.mobjs.length);
      expect(countItem.itemCount, normalItem.itemCount + 1);
      expect(countItem.totalItems, normalItem.totalItems + 1);
      expect(countItem.hashState(), normalItem.hashState());
      expect(countItem.levelTime, countItem.tic);
    });
  });
}
