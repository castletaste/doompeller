import 'package:doom_core/doom_core.dart';
import 'package:doom_core/src/mobj_states.dart';
import 'package:doom_core/src/replay_identity.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'combat_test.dart' show arena;
import 'specials_test.dart' show portal, testMap, twoSectors, twoSides;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MobjView _actor(GameState game, String sprite) =>
    game.mobjs.firstWhere((MobjView actor) => actor.sprite == sprite);

void main() {
  group('actor state table', () {
    test('semantic actor type identities ignore enum layout', () {
      final List<String> shiftedNames = <String>[
        'unusedActorType',
        ...MobjType.values.map((MobjType type) => type.name),
      ];
      for (var index = 0; index < MobjType.values.length; index++) {
        expect(
          stableReplayIdentity(shiftedNames[index + 1]),
          MobjType.values[index].replayIdentity,
        );
      }
    });

    test('different actor frame records have different replay identities', () {
      final int first = MobjStateTable.start(
        MobjType.possessed,
        MobjState.spawn,
      )!;
      expect(
        MobjStateTable.state(first)!.replayIdentity,
        isNot(MobjStateTable.state(first + 1)!.replayIdentity),
      );
      expect(
        MobjStateTable.state(
          MobjStateTable.start(MobjType.misc62, MobjState.spawn)!,
        )!.replayIdentity,
        isNot(
          MobjStateTable.state(
            MobjStateTable.start(MobjType.misc68, MobjState.spawn)!,
          )!.replayIdentity,
        ),
      );
    });

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
      expect(actionFrame(MobjType.sergeant, MobjState.melee), 6);
      expect(actionFrame(MobjType.spectre, MobjState.melee), 6);
      expect(actionFrame(MobjType.barrel, MobjState.death), 3);
    });

    test('demon and spectre share the complete SARG state graph', () {
      for (final MobjType type in <MobjType>[
        MobjType.sergeant,
        MobjType.spectre,
      ]) {
        for (final MobjState phase in <MobjState>[
          MobjState.spawn,
          MobjState.see,
          MobjState.melee,
          MobjState.pain,
          MobjState.death,
          MobjState.raise,
        ]) {
          expect(
            MobjStateTable.start(type, phase),
            isNotNull,
            reason: '$type $phase',
          );
        }
        expect(MobjStateTable.start(type, MobjState.missile), isNull);
        expect(MobjStateTable.start(type, MobjState.gibbedDeath), isNull);
      }
      final int attack = MobjStateTable.start(
        MobjType.sergeant,
        MobjState.melee,
      )!;
      expect(
        MobjStateTable.state(attack + 2)!.action,
        MobjStateAction.demonMelee,
      );
    });

    test('map decorations use their exact permanent lamps', () {
      const List<(int, MobjType, String, int, bool)> cases =
          <(int, MobjType, String, int, bool)>[
            (2028, MobjType.misc31, 'COLU', 0, true),
            (48, MobjType.misc48, 'ELEC', 0, false),
            (34, MobjType.misc49, 'CAND', 0, true),
            (35, MobjType.misc50, 'CBRA', 0, true),
            (15, MobjType.misc62, 'PLAY', 12, false),
            (18, MobjType.misc63, 'POSS', 11, false),
            (21, MobjType.misc64, 'SARG', 13, false),
            (20, MobjType.misc66, 'TROO', 12, false),
            (19, MobjType.misc67, 'SPOS', 11, false),
            (10, MobjType.misc68, 'PLAY', 21, false),
            (12, MobjType.misc69, 'PLAY', 21, false),
          ];
      for (final (
            int edNum,
            MobjType type,
            String sprite,
            int frame,
            bool fullBright,
          )
          in cases) {
        final int stateId = MobjStateTable.start(type, MobjState.spawn)!;
        final MobjFrameState state = MobjStateTable.state(stateId)!;
        expect(state.sprite, sprite, reason: 'thing $edNum sprite');
        expect(state.frame, frame, reason: 'thing $edNum frame');
        expect(state.fullBright, fullBright, reason: 'thing $edNum lighting');
        expect(state.tics, -1, reason: 'thing $edNum must remain forever');
        expect(state.next, isNull, reason: 'thing $edNum must be static');
      }
    });
  });

  group('E1 actor catalog', () {
    test('every added ed-num spawns with the published tuning and flags', () {
      const List<(int, String, int, int, int)> cases =
          <(int, String, int, int, int)>[
            (
              3002,
              'SARG',
              30,
              56,
              MobjFlags.solid | MobjFlags.shootable | MobjFlags.countKill,
            ),
            (
              58,
              'SARG',
              30,
              56,
              MobjFlags.solid |
                  MobjFlags.shootable |
                  MobjFlags.shadow |
                  MobjFlags.countKill,
            ),
            (2028, 'COLU', 16, 16, MobjFlags.solid),
            (48, 'ELEC', 16, 16, MobjFlags.solid),
            (34, 'CAND', 20, 16, 0),
            (35, 'CBRA', 16, 16, MobjFlags.solid),
            (15, 'PLAY', 20, 16, 0),
            (18, 'POSS', 20, 16, 0),
            (21, 'SARG', 20, 16, 0),
            (20, 'TROO', 20, 16, 0),
            (19, 'SPOS', 20, 16, 0),
            (10, 'PLAY', 20, 16, 0),
            (12, 'PLAY', 20, 16, 0),
            (24, 'POB1', 20, 16, 0),
            (2003, 'LAUN', 20, 16, MobjFlags.special),
            (2019, 'ARM2', 20, 16, MobjFlags.special),
            (2046, 'BROK', 20, 16, MobjFlags.special),
            (2048, 'AMMO', 20, 16, MobjFlags.special),
            (2049, 'SBOX', 20, 16, MobjFlags.special),
          ];
      for (final (int edNum, String sprite, int radius, int height, int flags)
          in cases) {
        final MobjInfo info = DoomCoreCatalog.infoForEdNum(edNum)!;
        expect(info.doomEdNum, edNum);
        expect(info.spriteName, sprite, reason: 'thing $edNum sprite');
        expect(info.radius, radius, reason: 'thing $edNum radius');
        expect(info.height, height, reason: 'thing $edNum height');
        expect(info.flags, flags, reason: 'thing $edNum flags');
        final GameState game = GameState.start(
          arena(<Thing>[
            const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 160, y: 64, angle: 0, type: edNum, flags: _skills),
          ]),
          const GameConfig(monsters: false),
        );
        expect(
          game.mobjs.where((MobjView actor) => actor.sprite == sprite),
          isNotEmpty,
          reason: 'thing $edNum spawn',
        );
      }
    });

    test('solid decorations block movement and non-solid corpses do not', () {
      const List<(int, bool)> cases = <(int, bool)>[
        (2028, true),
        (48, true),
        (34, false),
        (35, true),
        (15, false),
        (18, false),
        (21, false),
        (20, false),
        (19, false),
        (10, false),
        (12, false),
        (24, false),
      ];
      for (final (int edNum, bool blocks) in cases) {
        final GameState game = GameState.start(
          arena(<Thing>[
            const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 72, y: 64, angle: 0, type: edNum, flags: _skills),
          ]),
          const GameConfig(monsters: false),
        );
        for (var tic = 0; tic < 10; tic++) {
          game.runTic(const TicCmd(forwardMove: 8));
        }
        expect(
          game.player.x > toFixed(72),
          !blocks,
          reason: 'thing $edNum movement blocking',
        );
      }
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
      for (var tic = 0; tic < 100 && _actor(zombie, 'POSS').frame != 4; tic++) {
        zombie.runTic(TicCmd.empty);
      }
      expect(_actor(zombie, 'POSS').frame, 4);
      expect(zombie.player.health, 100);
      while (_actor(zombie, 'POSS').frame == 4) {
        final int before = zombie.player.health;
        zombie.runTic(TicCmd.empty);
        if (_actor(zombie, 'POSS').frame == 4) {
          expect(zombie.player.health, before);
        }
      }
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
      for (var tic = 0; tic < 100 && _actor(imp, 'TROO').frame != 6; tic++) {
        expect(
          imp.mobjs.where((MobjView actor) => actor.sprite == 'BAL1'),
          isEmpty,
        );
        imp.runTic(TicCmd.empty);
      }
      expect(_actor(imp, 'TROO').frame, 6);
      expect(
        imp.mobjs.where((MobjView actor) => actor.sprite == 'BAL1'),
        isNotEmpty,
      );
    });

    test('demon melee uses the dedicated close-range damage action', () {
      for (final int edNum in <int>[3002, 58]) {
        final GameState game = GameState.start(
          arena(<Thing>[
            const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 80, y: 64, angle: 180, type: edNum, flags: _skills),
          ]),
          const GameConfig(),
          seed: 2,
        );
        for (var tic = 0; tic < 100 && game.player.health == 100; tic++) {
          game.runTic(TicCmd.empty);
        }
        final int damage = 100 - game.player.health;
        expect(damage, inInclusiveRange(4, 40), reason: 'thing $edNum damage');
        expect(damage % 4, 0, reason: 'thing $edNum damage quantum');
        expect(
          game.soundJournal.map((SoundEvent event) => event.soundId),
          contains('DSSGTATK'),
          reason: 'thing $edNum attack sound',
        );
      }
    });
  });
}
