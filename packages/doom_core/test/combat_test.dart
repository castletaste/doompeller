import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show portal, testMap, twoSectors, twoSides;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MapData arena(List<Thing> things) => testMap(things: things);

void main() {
  group('things and combat', () {
    test('health, armor, ammo, weapons and keys are deterministic pickups', () {
      final GameState game = GameState.start(
        arena(<Thing>[
          const Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
          const Thing(x: 64, y: 64, angle: 0, type: 2007, flags: _skills),
          const Thing(x: 64, y: 64, angle: 0, type: 2001, flags: _skills),
          const Thing(x: 64, y: 64, angle: 0, type: 2018, flags: _skills),
          const Thing(x: 64, y: 64, angle: 0, type: 5, flags: _skills),
        ]),
        const GameConfig(monsters: false),
      );
      game.runTic(TicCmd.empty);
      expect(game.player.ammo.bullets, 60);
      expect(game.player.ammo.shells, 8);
      expect(game.player.armor, 100);
      expect(game.player.keys, contains(Key.blue));
      expect(game.player.weapon, Weapon.shotgun);
    });

    test('skill flags spawn only the selected difficulty population', () {
      final GameState easy = GameState.start(
        arena(const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 80, y: 64, angle: 0, type: 3004, flags: ThingFlags.easy),
          Thing(x: 100, y: 64, angle: 0, type: 3001, flags: ThingFlags.hard),
        ]),
        const GameConfig(skill: Skill.easy, monsters: false),
      );
      expect(easy.mobjs.where((MobjView m) => m.sprite == 'POSS').length, 1);
      expect(easy.mobjs.where((MobjView m) => m.sprite == 'TROO'), isEmpty);
    });

    test(
      'unknown things are ignored without changing known spawn identity',
      () {
        final List<Thing> base = const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 96, y: 64, angle: 0, type: 3004, flags: _skills),
        ];
        final GameState a = GameState.start(arena(base), const GameConfig());
        final GameState b = GameState.start(
          arena(<Thing>[
            base.first,
            const Thing(x: 0, y: 0, angle: 0, type: 9999, flags: _skills),
            base.last,
          ]),
          const GameConfig(),
        );
        expect(a.hashState(), b.hashState());
      },
    );

    test('map thing order is intentionally replay-significant', () {
      const Thing player = Thing(
        x: 32,
        y: 64,
        angle: 0,
        type: 1,
        flags: _skills,
      );
      const Thing zombie = Thing(
        x: 96,
        y: 64,
        angle: 0,
        type: 3004,
        flags: _skills,
      );
      const Thing imp = Thing(
        x: 112,
        y: 64,
        angle: 0,
        type: 3001,
        flags: _skills,
      );
      final GameState a = GameState.start(
        arena(const <Thing>[player, zombie, imp]),
        const GameConfig(monsters: false),
      );
      final GameState b = GameState.start(
        arena(const <Thing>[player, imp, zombie]),
        const GameConfig(monsters: false),
      );
      expect(a.hashState(), isNot(b.hashState()));
    });

    test('bonus, medikit and shell pickups use their own caps and amounts', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2014, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2015, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2012, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2008, flags: _skills),
        ]),
        const GameConfig(monsters: false),
      );
      game.runTic(TicCmd.empty);
      expect(game.player.health, 100);
      expect(game.player.armor, 1);
      expect(game.player.ammo.shells, 4);
    });

    test('weapon cannot be selected before it is owned', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
        ]),
        const GameConfig(monsters: false),
      );
      game.runTic(
        const TicCmd(
          buttons: Buttons.changeWeapon | (2 << Buttons.weaponShift),
        ),
      );
      expect(game.player.weapon, Weapon.pistol);
    });

    test('pistol hitscan damages and kills former human', () {
      final GameState game = GameState.start(
        arena(<Thing>[
          const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          const Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _skills),
        ]),
        const GameConfig(monsters: false),
        seed: 3,
      );
      final int before = game.mobjs
          .firstWhere((MobjView m) => m.sprite == 'POSS')
          .health;
      game.runTic(const TicCmd(buttons: Buttons.attack));
      final int after = game.mobjs
          .firstWhere((MobjView m) => m.sprite == 'POSS')
          .health;
      expect(after, lessThan(before));
      for (int i = 0; i < 15; i++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(
        game.mobjs.firstWhere((MobjView m) => m.sprite == 'POSS').health,
        0,
      );
      final MobjView corpse = game.mobjs.firstWhere(
        (MobjView m) => m.sprite == 'POSS',
      );
      expect(corpse.flags & 0x100000, isNot(0)); // corpse flag
      expect(corpse.frame, 2);
      // Pins the observable corpse flags/frame together with its stable id.
      expect(game.hashState(), 0x44a9e574);
    });

    test('hitscan is occluded by a one-sided wall', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 160, y: 64, angle: 180, type: 3004, flags: _skills),
        ]),
        const GameConfig(monsters: false),
        seed: 3,
      );
      final int before = game.mobjs
          .firstWhere((MobjView m) => m.sprite == 'POSS')
          .health;
      game.runTic(const TicCmd(buttons: Buttons.attack));
      final int after = game.mobjs
          .firstWhere((MobjView m) => m.sprite == 'POSS')
          .health;
      expect(after, before);
    });

    test('hitscan sees a blocker after linedef index 256', () {
      final List<Linedef> lines = <Linedef>[
        for (int i = 0; i < 257; i++)
          const Linedef(
            v1: 0,
            v2: 1,
            flags: 0,
            special: 0,
            tag: 0,
            rightSidedef: 0,
            leftSidedef: kNoSidedef,
          ),
        const Linedef(
          v1: 1,
          v2: 2,
          flags: LinedefFlags.blocking,
          special: 0,
          tag: 0,
          rightSidedef: 0,
          leftSidedef: kNoSidedef,
        ),
      ];
      final GameState game = GameState.start(
        testMap(
          lines: lines,
          things: const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 160, y: 64, angle: 180, type: 3004, flags: _skills),
          ],
        ),
        const GameConfig(monsters: false),
        seed: 3,
      );
      game.runTic(const TicCmd(buttons: Buttons.attack));
      expect(
        game.mobjs.firstWhere((MobjView m) => m.sprite == 'POSS').health,
        20,
      );
    });

    test('line of sight follows a changing door opening', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backCeiling: 32),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.doorOpenStay)],
          things: const <Thing>[
            Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 180, y: 64, angle: 180, type: 3004, flags: _skills),
          ],
        ),
        const GameConfig(monsters: false),
        seed: 3,
      );
      int zombieHealth() =>
          game.mobjs.firstWhere((MobjView m) => m.sprite == 'POSS').health;
      game.runTic(const TicCmd(buttons: Buttons.attack));
      expect(zombieHealth(), 20);
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 25; i++) {
        game.runTic(TicCmd.empty);
      }
      game.runTic(const TicCmd(buttons: Buttons.attack));
      expect(zombieHealth(), lessThan(20));
    });

    test('imp projectile is spawned without mutating actor iteration', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(),
          sides: twoSides(),
          lines: <Linedef>[portal()],
          things: const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 200, y: 64, angle: 180, type: 3001, flags: _skills),
          ],
        ),
        const GameConfig(),
        seed: 2,
      );
      for (int i = 0; i < 20; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.mobjs.where((MobjView m) => m.sprite == 'BAL1'), isNotEmpty);
      expect(
        game.mobjs.firstWhere((MobjView m) => m.sprite == 'TROO').health,
        60,
      );
    });

    test(
      'monster wakes/chases and imp projectile is removed on player hit',
      () {
        final GameState game = GameState.start(
          arena(<Thing>[
            const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            const Thing(x: 96, y: 64, angle: 180, type: 3001, flags: _skills),
          ]),
          const GameConfig(),
          seed: 2,
        );
        final int startHealth = game.player.health;
        for (int i = 0; i < 80; i++) {
          game.runTic(TicCmd.empty);
        }
        final MobjView imp = game.mobjs.firstWhere(
          (MobjView m) => m.sprite == 'TROO',
        );
        expect(imp.health, greaterThan(0));
        expect(game.player.health, lessThan(startHealth));
      },
    );
  });
}
