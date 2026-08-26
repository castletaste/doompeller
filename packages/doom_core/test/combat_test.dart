import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show portal, testMap, twoSectors, twoSides;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MapData arena(List<Thing> things) => testMap(things: things);

void main() {
  group('things and combat', () {
    test('fixture enemy roster advances combat deterministically', () {
      final MapData map = MapData.load(
        DoomFixtures.wadSet(),
        DoomFixtures.mapName,
      );
      final GameState a = GameState.start(map, const GameConfig(), seed: 17);
      final GameState b = GameState.start(map, const GameConfig(), seed: 17);
      expect(
        a.mobjs.map((MobjView mobj) => mobj.sprite).toSet(),
        containsAll(<String>{'POSS', 'TROO', 'SPOS'}),
      );
      expect(a.mobjs.length, 12);
      final int initialHash = a.hashState();
      for (var tic = 0; tic < 140; tic++) {
        a.runTic(TicCmd.empty);
        b.runTic(TicCmd.empty);
      }
      expect(a.tic, 140);
      expect(a.hashState(), b.hashState());
      expect(a.hashState(), isNot(initialHash));
      expect(a.player.health, lessThan(100));
    });

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
      expect(game.player.weapon, Weapon.pistol);
      expect(game.player.weaponAnimation.phase, WeaponPhase.lowering);
      for (var tic = 0; tic < 40; tic++) {
        game.runTic(TicCmd.empty);
      }
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

    test('weapon fire state gates refire and returns to ready', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
        ]),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.attack));
      expect(game.player.weaponAnimation.phase, WeaponPhase.firing);
      expect(game.player.weaponAnimation.frame, 0);
      expect(game.player.weaponAnimation.flashFrame, -1);
      expect(game.player.ammo.bullets, 50);
      for (int i = 0; i < 3; i++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(game.player.ammo.bullets, 50);
      game.runTic(const TicCmd(buttons: Buttons.attack));
      expect(game.player.weaponAnimation.frame, 1);
      expect(game.player.weaponAnimation.flashFrame, 0);
      expect(game.player.ammo.bullets, 49);
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(game.player.ammo.bullets, lessThan(49));
      for (int i = 0; i < 30; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.player.weaponAnimation.phase, WeaponPhase.ready);
      expect(game.player.weaponAnimation.frame, 0);
    });

    test('weapon fire chains expose the exact lamps and durations', () {
      GameState armed(Weapon weapon) {
        final int? pickupType = switch (weapon) {
          Weapon.shotgun => 2001,
          Weapon.chaingun => 2002,
          _ => null,
        };
        final GameState game = GameState.start(
          arena(<Thing>[
            const Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
            if (pickupType != null)
              Thing(x: 64, y: 64, angle: 0, type: pickupType, flags: _skills),
          ]),
          const GameConfig(monsters: false),
        );
        if (pickupType != null) {
          game.runTic(TicCmd.empty);
          for (var tic = 0; tic < 40; tic++) {
            game.runTic(TicCmd.empty);
          }
        } else if (weapon == Weapon.fist) {
          game.runTic(
            const TicCmd(
              buttons: Buttons.changeWeapon | (0 << Buttons.weaponShift),
            ),
          );
          for (var tic = 0; tic < 40; tic++) {
            game.runTic(TicCmd.empty);
          }
        }
        expect(game.player.weapon, weapon);
        expect(game.player.weaponAnimation.phase, WeaponPhase.ready);
        return game;
      }

      List<(int, int)> enteredStates(GameState game) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
        final List<(int, int)> result = <(int, int)>[
          (game.player.weaponAnimation.frame, game.player.weaponAnimation.tics),
        ];
        while (game.player.weaponAnimation.phase == WeaponPhase.firing) {
          final int previousTics = game.player.weaponAnimation.tics;
          final int previousFrame = game.player.weaponAnimation.frame;
          game.runTic(TicCmd.empty);
          final WeaponAnimation current = game.player.weaponAnimation;
          if (current.phase == WeaponPhase.firing &&
              (current.frame != previousFrame || current.tics > previousTics)) {
            result.add((current.frame, current.tics));
          }
        }
        return result;
      }

      expect(enteredStates(armed(Weapon.fist)), <(int, int)>[
        (1, 4),
        (2, 4),
        (3, 5),
        (2, 4),
        (1, 5),
      ]);
      expect(enteredStates(armed(Weapon.pistol)), <(int, int)>[
        (0, 4),
        (1, 6),
        (2, 4),
        (1, 5),
      ]);
      expect(enteredStates(armed(Weapon.shotgun)), <(int, int)>[
        (0, 3),
        (0, 7),
        (1, 5),
        (2, 5),
        (3, 4),
        (2, 5),
        (1, 5),
        (0, 3),
        (0, 7),
      ]);

      final GameState chaingun = armed(Weapon.chaingun);
      final int bullets = chaingun.player.ammo.bullets;
      chaingun.runTic(const TicCmd(buttons: Buttons.attack));
      expect(chaingun.player.weaponAnimation.frame, 0);
      expect(chaingun.player.ammo.bullets, bullets - 1);
      for (var tic = 0; tic < 3; tic++) {
        chaingun.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(chaingun.player.ammo.bullets, bullets - 1);
      chaingun.runTic(const TicCmd(buttons: Buttons.attack));
      expect(chaingun.player.weaponAnimation.frame, 1);
      expect(chaingun.player.ammo.bullets, bullets - 2);
    });

    test('muzzle flash lamps retain their full classic lifetimes', () {
      final GameState pistol = GameState.start(
        arena(const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
        ]),
        const GameConfig(monsters: false),
      );
      for (var tic = 0; tic < 5; tic++) {
        pistol.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(pistol.player.weaponAnimation.flashFrame, 0);
      for (var tic = 0; tic < 6; tic++) {
        pistol.runTic(TicCmd.empty);
        expect(pistol.player.weaponAnimation.flashFrame, 0);
      }
      pistol.runTic(TicCmd.empty);
      expect(pistol.player.weaponAnimation.flashFrame, -1);

      final GameState shotgun = GameState.start(
        arena(const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2001, flags: _skills),
        ]),
        const GameConfig(monsters: false),
      );
      shotgun.runTic(TicCmd.empty);
      for (var tic = 0; tic < 40; tic++) {
        shotgun.runTic(TicCmd.empty);
      }
      for (var tic = 0; tic < 4; tic++) {
        shotgun.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(shotgun.player.weaponAnimation.flashFrame, 0);
      for (var tic = 0; tic < 3; tic++) {
        shotgun.runTic(TicCmd.empty);
        expect(shotgun.player.weaponAnimation.flashFrame, 0);
      }
      shotgun.runTic(TicCmd.empty);
      expect(shotgun.player.weaponAnimation.flashFrame, 1);
      for (var tic = 0; tic < 2; tic++) {
        shotgun.runTic(TicCmd.empty);
        expect(shotgun.player.weaponAnimation.flashFrame, 1);
      }
      shotgun.runTic(TicCmd.empty);
      expect(shotgun.player.weaponAnimation.flashFrame, -1);
    });

    test('weapon change lowers then raises before the new weapon is ready', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2001, flags: _skills),
        ]),
        const GameConfig(monsters: false),
      );
      game.runTic(TicCmd.empty);
      expect(game.player.weapon, Weapon.pistol);
      expect(game.player.weaponAnimation.phase, WeaponPhase.lowering);
      for (int i = 0; i < 40; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.player.weapon, Weapon.shotgun);
      game.runTic(
        const TicCmd(
          buttons: Buttons.changeWeapon | (1 << Buttons.weaponShift),
        ),
      );
      expect(game.player.weaponAnimation.phase, WeaponPhase.lowering);
      expect(game.player.weapon, Weapon.shotgun);
      for (int i = 0; i < 40; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.player.weapon, Weapon.pistol);
      expect(game.player.weaponAnimation.phase, WeaponPhase.ready);
    });

    test(
      'hitscan spawns finite puff on wall and blood on a shootable actor',
      () {
        final GameState wall = GameState.start(
          arena(const <Thing>[
            Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
          ]),
          const GameConfig(monsters: false),
        );
        for (var tic = 0; tic < 5; tic++) {
          wall.runTic(const TicCmd(buttons: Buttons.attack));
        }
        expect(
          wall.mobjs.where((MobjView m) => m.sprite == 'PUFF'),
          isNotEmpty,
        );
        for (int i = 0; i < 20; i++) {
          wall.runTic(TicCmd.empty);
        }
        expect(wall.mobjs.where((MobjView m) => m.sprite == 'PUFF'), isEmpty);

        final GameState target = GameState.start(
          arena(const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _skills),
          ]),
          const GameConfig(monsters: false),
          seed: 3,
        );
        for (var tic = 0; tic < 5; tic++) {
          target.runTic(const TicCmd(buttons: Buttons.attack));
        }
        expect(
          target.mobjs.where((MobjView m) => m.sprite == 'BLUD'),
          isNotEmpty,
        );
        for (int i = 0; i < 30; i++) {
          target.runTic(TicCmd.empty);
        }
        expect(target.mobjs.where((MobjView m) => m.sprite == 'BLUD'), isEmpty);
      },
    );

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
      for (var tic = 0; tic < 5; tic++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      final int after = game.mobjs
          .firstWhere((MobjView m) => m.sprite == 'POSS')
          .health;
      expect(after, lessThan(before));
      for (int i = 0; i < 80; i++) {
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
      expect(corpse.flags & 0x0400, isNot(0)); // drop-off flag
      expect(corpse.flags & 0x0002, 0); // solid flag
      expect(corpse.height, toFixed(14));
      expect(corpse.frame, greaterThanOrEqualTo(7));
      // Monsters are disabled in this scenario. The pistol alert still stores
      // its persistent sector target, but AI direction/attack RNG is never
      // consumed, so the chase-order correction deliberately leaves this pin
      // unchanged.
      expect(game.hashState(), 0x8a4407a8);
      for (var tic = 0; tic < 10; tic++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, greaterThan(toFixed(80)));
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
      // The camera would be clamped below this opening. Keeping the attack
      // blocked proves sight still uses each actor's unbobbed Mobj eye height.
      expect(zombieHealth(), 20);
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 25; i++) {
        game.runTic(TicCmd.empty);
      }
      game.runTic(const TicCmd(buttons: Buttons.attack));
      expect(zombieHealth(), lessThan(20));
    });

    test('monster sight keeps the unbobbed eye across a low door', () {
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
        const GameConfig(),
        seed: 3,
      );
      int zombieX() =>
          game.mobjs.firstWhere((MobjView m) => m.sprite == 'POSS').x;

      for (int i = 0; i < 40; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(zombieX(), toFixed(180));
      expect(game.player.health, 100);

      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 120; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(
        zombieX() < toFixed(180) || game.player.health < 100,
        isTrue,
        reason: 'the opened sightline must cause chase movement or an attack',
      );
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
      for (int i = 0; i < 36; i++) {
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
