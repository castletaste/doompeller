import 'package:doom_core/doom_core.dart';
import 'package:doom_core/src/mobj_info.dart';
import 'package:doom_core/src/mobj_states.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'combat_test.dart' show arena;
import 'specials_test.dart' show portal, testMap, twoSectors, twoSides;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MobjView _actor(GameState game, String sprite) =>
    game.mobjs.firstWhere((MobjView actor) => actor.sprite == sprite);

void main() {
  group('actor state table', () {
    test('former-human walk chain cycles A A B B C C D D', () {
      final int first = MobjStateTable.start(
        MobjType.possessed,
        MobjState.see,
      )!;
      final List<int> frames = <int>[];
      int state = first;
      for (var index = 0; index < 8; index++) {
        final MobjFrameState record = MobjStateTable.state(state)!;
        frames.add(record.frame);
        expect(record.tics, 4);
        state = record.next!;
      }
      expect(frames, <int>[0, 0, 1, 1, 2, 2, 3, 3]);
      expect(state, first);
    });

    test('death and gib chains terminate in permanent corpse frames', () {
      for (final MobjState phase in <MobjState>[
        MobjState.death,
        MobjState.gibbedDeath,
      ]) {
        int state = MobjStateTable.start(MobjType.possessed, phase)!;
        final List<int> frames = <int>[];
        while (true) {
          final MobjFrameState record = MobjStateTable.state(state)!;
          frames.add(record.frame);
          if (record.tics < 0) {
            expect(record.phase, MobjState.dead);
            expect(record.next, isNull);
            break;
          }
          state = record.next!;
        }
        expect(frames.length, phase == MobjState.death ? 5 : 9);
      }
    });

    test('effect chains carry deterministic brightness and removal', () {
      final int puff = MobjStateTable.start(MobjType.puff, MobjState.spawn)!;
      expect(MobjStateTable.state(puff)!.fullBright, isTrue);
      expect(MobjStateTable.state(puff + 1)!.fullBright, isFalse);
      expect(MobjStateTable.state(puff + 2)!.fullBright, isFalse);
      expect(MobjStateTable.state(puff + 3)!.removeOnExpiry, isTrue);
      final int blood = MobjStateTable.start(MobjType.blood, MobjState.spawn)!;
      expect(
        <int>[
          for (var offset = 0; offset < 3; offset++)
            MobjStateTable.state(blood + offset)!.frame,
        ],
        <int>[2, 1, 0],
      );
      expect(
        MobjStateTable.state(MobjStateTable.bloodImpactStart(5))!.frame,
        0,
      );
      expect(
        MobjStateTable.state(MobjStateTable.bloodImpactStart(10))!.frame,
        1,
      );
      expect(
        MobjStateTable.state(MobjStateTable.bloodImpactStart(20))!.frame,
        2,
      );
    });

    test('attack and barrel actions are attached to their exact frames', () {
      int actionFrame(MobjType type, MobjState phase) {
        var state = MobjStateTable.start(type, phase)!;
        while (true) {
          final MobjFrameState record = MobjStateTable.state(state)!;
          if (record.action != null) return record.frame;
          state = record.next!;
        }
      }

      expect(actionFrame(MobjType.possessed, MobjState.missile), 5);
      expect(actionFrame(MobjType.shotguy, MobjState.missile), 5);
      expect(actionFrame(MobjType.troop, MobjState.melee), 6);
      expect(actionFrame(MobjType.troop, MobjState.missile), 6);
      expect(actionFrame(MobjType.barrel, MobjState.death), 3);
    });
  });

  group('actor state integration', () {
    test('wake-up enters the timed walk chain and changes the view frame', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 200, y: 64, angle: 180, type: 3004, flags: _skills),
        ]),
        const GameConfig(),
        seed: 9,
      );
      expect(_actor(game, 'POSS').frame, 0);
      for (var tic = 0; tic < 12; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(_actor(game, 'POSS').frame, 1);
    });

    test('pain chance enters a deterministic timed pain state', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _skills),
        ]),
        const GameConfig(monsters: false),
        seed: 0,
      );
      for (var tic = 0; tic < 5; tic++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(_actor(game, 'POSS').frame, 6);
      for (var tic = 0; tic < 6; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(_actor(game, 'POSS').frame, 0);
    });

    test('ordinary death plays every frame then remains a corpse forever', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _skills),
        ]),
        const GameConfig(monsters: false),
        seed: 3,
      );
      while (_actor(game, 'POSS').health > 0) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(_actor(game, 'POSS').frame, 7);
      for (final int expected in <int>[8, 9, 10, 11]) {
        for (var tic = 0; tic < 5; tic++) {
          game.runTic(TicCmd.empty);
        }
        expect(_actor(game, 'POSS').frame, expected);
      }
      for (var tic = 0; tic < 100; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(_actor(game, 'POSS').frame, 11);
    });

    test('overkill from a barrel selects the gibbed-death chain', () {
      final GameState game = GameState.start(
        arena(const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 80, y: 64, angle: 0, type: 2035, flags: _skills),
          Thing(x: 100, y: 64, angle: 180, type: 3004, flags: _skills),
        ]),
        const GameConfig(monsters: false),
        seed: 3,
      );
      final int barrelId = _actor(game, 'BAR1').id;
      while (game.mobjs
              .firstWhere((MobjView actor) => actor.id == barrelId)
              .health >
          0) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(_actor(game, 'POSS').health, 20);
      expect(_actor(game, 'BEXP').frame, 0);
      while (_actor(game, 'BEXP').frame != 3) {
        game.runTic(TicCmd.empty);
      }
      expect(_actor(game, 'POSS').health, 0);
      expect(_actor(game, 'POSS').frame, 12);
    });

    test('monster attacks execute only when their action frame is entered', () {
      final GameState zombie = GameState.start(
        testMap(
          sectors: twoSectors(),
          sides: twoSides(),
          lines: <Linedef>[portal()],
          things: const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 200, y: 64, angle: 180, type: 3004, flags: _skills),
          ],
        ),
        const GameConfig(),
        seed: 2,
      );
      for (var tic = 0; tic < 20; tic++) {
        zombie.runTic(TicCmd.empty);
      }
      expect(_actor(zombie, 'POSS').frame, 4);
      expect(zombie.player.health, 100);
      for (var tic = 0; tic < 9; tic++) {
        zombie.runTic(TicCmd.empty);
      }
      expect(zombie.player.health, 100);
      zombie.runTic(TicCmd.empty);
      expect(_actor(zombie, 'POSS').frame, 5);
      expect(zombie.player.health, lessThan(100));

      final GameState imp = GameState.start(
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
      for (var tic = 0; tic < 35; tic++) {
        imp.runTic(TicCmd.empty);
      }
      expect(
        imp.mobjs.where((MobjView actor) => actor.sprite == 'BAL1'),
        isEmpty,
      );
      imp.runTic(TicCmd.empty);
      expect(_actor(imp, 'TROO').frame, 6);
      expect(
        imp.mobjs.where((MobjView actor) => actor.sprite == 'BAL1'),
        isNotEmpty,
      );
    });
  });
}
