import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show testMap;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

void main() {
  test('rocket launcher, loose rocket, box, and chainsaw are real pickups', () {
    final GameState game = GameState.start(
      testMap(
        things: const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2003, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2010, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2046, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2005, flags: _skills),
        ],
      ),
      const GameConfig(monsters: false),
    );

    game.runTic(TicCmd.empty);

    expect(game.player.ammo.rockets, 8);
    expect(game.player.weaponAnimation.phase, WeaponPhase.lowering);
    expect(
      game.mobjs.map((MobjView actor) => actor.sprite).toSet().intersection(
        <String>{'LAUN', 'ROCK', 'BROK', 'CSAW'},
      ),
      isEmpty,
    );

    for (var tic = 0; tic < 40; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.weapon, Weapon.chainsaw);
    _select(game, Weapon.rocketLauncher);
    expect(game.player.weapon, Weapon.rocketLauncher);
  });

  test('chainsaw melee consumes no ammo and is replay deterministic', () {
    int run() {
      final GameState game = GameState.start(
        testMap(
          things: const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 32, y: 64, angle: 0, type: 2005, flags: _skills),
            Thing(x: 88, y: 64, angle: 180, type: 3004, flags: _skills),
          ],
        ),
        const GameConfig(monsters: false),
        seed: 9,
      );
      game.runTic(TicCmd.empty);
      for (var tic = 0; tic < 40; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.player.weapon, Weapon.chainsaw);
      final Ammo before = game.player.ammo;
      for (var tic = 0; tic < 120; tic++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(
        game.mobjs.where(
          (MobjView actor) =>
              actor.health > 0 && (actor.flags & MobjFlags.countKill) != 0,
        ),
        isEmpty,
      );
      expect(game.player.ammo.bullets, before.bullets);
      expect(game.player.ammo.shells, before.shells);
      expect(game.player.ammo.rockets, before.rockets);
      return game.hashState();
    }

    expect(run(), run());
  });

  test(
    'rocket spends ammo, flies, applies direct and sight-gated radius damage',
    () {
      ({int hash, int health, int living}) run() {
        final PlayerLoadout loadout = PlayerLoadout(
          health: 200,
          armor: 0,
          ammo: const Ammo(bullets: 50, rockets: 3),
          weapon: Weapon.rocketLauncher,
          ownedWeapons: const <Weapon>{
            Weapon.fist,
            Weapon.pistol,
            Weapon.rocketLauncher,
          },
        );
        final GameState game = GameState.start(
          testMap(
            things: const <Thing>[
              Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
              Thing(x: 96, y: 64, angle: 180, type: 3001, flags: _skills),
              Thing(x: 112, y: 88, angle: 180, type: 3004, flags: _skills),
            ],
          ),
          const GameConfig(monsters: false),
          seed: 3,
          loadout: loadout,
        );

        for (var tic = 0; tic < 9; tic++) {
          game.runTic(const TicCmd(buttons: Buttons.attack));
        }
        expect(game.player.ammo.rockets, 2);
        expect(
          game.mobjs.where((MobjView actor) => actor.sprite == 'MISL'),
          isNotEmpty,
        );
        for (var tic = 0; tic < 20; tic++) {
          game.runTic(TicCmd.empty);
        }

        final int living = game.mobjs
            .where(
              (MobjView actor) =>
                  actor.health > 0 && (actor.flags & MobjFlags.countKill) != 0,
            )
            .length;
        expect(living, lessThan(2));
        expect(game.player.health, lessThan(200), reason: 'rocket splash');
        expect(
          game.soundJournal.map((SoundEvent event) => event.soundId),
          containsAll(<String>['DSRLAUNC', 'DSBAREXP']),
        );
        return (
          hash: game.hashState(),
          health: game.player.health,
          living: living,
        );
      }

      expect(run(), run());
    },
  );
}

void _select(GameState game, Weapon weapon) {
  game.runTic(
    TicCmd(
      buttons: Buttons.changeWeapon | (weapon.index << Buttons.weaponShift),
    ),
  );
  for (var tic = 0; tic < 40; tic++) {
    game.runTic(TicCmd.empty);
  }
}
