import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show testMap;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

void main() {
  for (final _DropCase dropCase in <_DropCase>[
    const _DropCase(
      enemyType: 3004,
      enemySprite: 'POSS',
      pickupSprite: 'CLIP',
      ammoGain: 5,
    ),
    const _DropCase(
      enemyType: 9,
      enemySprite: 'SPOS',
      pickupSprite: 'SHOT',
      ammoGain: 4,
    ),
  ]) {
    test(
      '${dropCase.enemySprite} drops one ${dropCase.pickupSprite} at its exact death position',
      () {
        final MapData map = testMap(
          things: <Thing>[
            const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(
              x: 96,
              y: 64,
              angle: 180,
              type: dropCase.enemyType,
              flags: _skills,
            ),
          ],
        );
        final GameState game = GameState.start(
          map,
          const GameConfig(monsters: false),
          seed: 7,
        );

        _killWithPistol(game, dropCase.enemySprite);

        final List<MobjView> drops = game.mobjs
            .where((MobjView actor) => actor.sprite == dropCase.pickupSprite)
            .toList();
        expect(drops, hasLength(1));
        expect(drops.single.x, toFixed(96));
        expect(drops.single.y, toFixed(64));
        expect(drops.single.z, 0);
        expect(drops.single.flags & MobjFlags.dropped, isNot(0));

        // Further weapon fire cannot run the death transition a second time.
        for (var tic = 0; tic < 70; tic++) {
          game.runTic(const TicCmd(buttons: Buttons.attack));
        }
        expect(
          game.mobjs.where(
            (MobjView actor) => actor.sprite == dropCase.pickupSprite,
          ),
          hasLength(1),
        );

        final int ammoBefore = dropCase.pickupSprite == 'CLIP'
            ? game.player.ammo.bullets
            : game.player.ammo.shells;
        for (var tic = 0; tic < 80; tic++) {
          game.runTic(const TicCmd(forwardMove: 25));
          if (!game.mobjs.any(
            (MobjView actor) => actor.sprite == dropCase.pickupSprite,
          )) {
            break;
          }
        }
        expect(
          game.mobjs.any(
            (MobjView actor) => actor.sprite == dropCase.pickupSprite,
          ),
          isFalse,
        );
        final int ammoAfter = dropCase.pickupSprite == 'CLIP'
            ? game.player.ammo.bullets
            : game.player.ammo.shells;
        expect(ammoAfter - ammoBefore, dropCase.ammoGain);
      },
    );
  }

  test(
    'default AI drop preserves fractional death coordinates and raised floor',
    () {
      const int floorHeight = 24;
      final MapData map = testMap(
        vertices: const <MapVertex>[
          MapVertex(0, 0),
          MapVertex(512, 0),
          MapVertex(512, 512),
          MapVertex(0, 512),
        ],
        sectors: const <Sector>[
          Sector(
            floorHeight: floorHeight,
            ceilingHeight: 160,
            floorFlat: 'F',
            ceilingFlat: 'C',
            lightLevel: 160,
            special: 0,
            tag: 0,
          ),
        ],
        things: const <Thing>[
          Thing(x: 64, y: 64, angle: 45, type: 1, flags: _skills),
          Thing(x: 400, y: 400, angle: 225, type: 3004, flags: _skills),
        ],
      );
      final GameState game = GameState.start(map, const GameConfig(), seed: 7);

      for (var tic = 0; tic < 10; tic++) {
        game.runTic(TicCmd.empty);
      }
      _killWithPistol(game, 'POSS');

      final MobjView corpse = game.mobjs.singleWhere(
        (MobjView actor) => actor.sprite == 'POSS',
      );
      final MobjView drop = game.mobjs.singleWhere(
        (MobjView actor) => actor.sprite == 'CLIP',
      );
      expect(
        corpse.x % kFracUnit != 0 || corpse.y % kFracUnit != 0,
        isTrue,
        reason: 'the default AI must move off the integer spawn coordinates',
      );
      expect((drop.x, drop.y, drop.z), (corpse.x, corpse.y, corpse.z));
      expect(drop.z, toFixed(floorHeight));
      expect(drop.flags & MobjFlags.dropped, isNot(0));
      expect((game.killCount, game.totalKills), (1, 1));
      expect((game.itemCount, game.totalItems), (0, 0));

      for (var tic = 0; tic < 70; tic++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(
        game.mobjs.where((MobjView actor) => actor.sprite == 'CLIP'),
        hasLength(1),
      );
      expect(game.killCount, 1);
      expect(game.totalItems, 0);
    },
  );
}

void _killWithPistol(GameState game, String enemySprite) {
  for (var tic = 0; tic < 350; tic++) {
    final MobjView enemy = game.mobjs.firstWhere(
      (MobjView actor) => actor.sprite == enemySprite,
    );
    if (enemy.health <= 0) return;
    game.runTic(const TicCmd(buttons: Buttons.attack));
  }
  fail('$enemySprite survived the deterministic pistol budget');
}

class _DropCase {
  const _DropCase({
    required this.enemyType,
    required this.enemySprite,
    required this.pickupSprite,
    required this.ammoGain,
  });

  final int enemyType;
  final String enemySprite;
  final String pickupSprite;
  final int ammoGain;
}
