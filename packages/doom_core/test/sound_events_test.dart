import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show portal, testMap, twoSectors, twoSides;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

void main() {
  test(
    'journal retains skipped tics, snapshots immutably, and consumption does not hash',
    () {
      final GameState pending = GameState.start(
        testMap(),
        const GameConfig(monsters: false),
      );
      final GameState consumed = GameState.start(
        testMap(),
        const GameConfig(monsters: false),
      );
      for (final GameState game in <GameState>[pending, consumed]) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(pending.soundJournal.map((SoundEvent e) => e.soundId), <String>[
        'DSPISTOL',
        'DSPISTOL',
      ]);
      final List<SoundEvent> snapshot = consumed.consumeSoundJournal();
      expect(() => snapshot.add(snapshot.first), throwsUnsupportedError);
      expect(consumed.soundJournal, isEmpty);
      expect(pending.hashState(), consumed.hashState());
    },
  );

  test('player fire and weapon change emit player-origin events', () {
    final GameState game = GameState.start(
      testMap(
        things: const <Thing>[
          Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 64, y: 64, angle: 0, type: 2001, flags: _skills),
        ],
      ),
      const GameConfig(monsters: false),
    );
    game.runTic(TicCmd.empty);
    game.consumeSoundJournal();
    game.runTic(
      const TicCmd(buttons: Buttons.changeWeapon | (1 << Buttons.weaponShift)),
    );
    game.runTic(const TicCmd(buttons: Buttons.attack));
    expect(
      game.soundJournal.map((SoundEvent e) => e.soundId),
      containsAllInOrder(<String>['DSWPNUP', 'DSPISTOL']),
    );
    expect(game.soundJournal.every((SoundEvent e) => e.fromPlayer), isTrue);
    expect(
      game.soundJournal.every(
        (SoundEvent e) => e.sourceId == SoundEvent.playerSourceId && e.tic > 0,
      ),
      isTrue,
    );
  });

  test('door and lift transitions emit positioned start/close/stop events', () {
    final GameState door = GameState.start(
      testMap(
        sectors: twoSectors(backCeiling: 32),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.doorOpenWaitClose)],
      ),
      const GameConfig(monsters: false),
    );
    door.runTic(const TicCmd(buttons: Buttons.use));
    for (var i = 0; i < 190; i++) {
      door.runTic(TicCmd.empty);
    }
    expect(
      door.soundJournal.map((SoundEvent e) => e.soundId),
      containsAllInOrder(<String>['DSDOROPN', 'DSDORCLS']),
    );
    expect(door.soundJournal.every((SoundEvent e) => e.isPositional), isTrue);

    final GameState lift = GameState.start(
      testMap(
        sectors: twoSectors(backFloor: 32),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.liftDownWaitUpSwitch)],
      ),
      const GameConfig(monsters: false),
    );
    lift.runTic(const TicCmd(buttons: Buttons.use));
    for (var i = 0; i < 55; i++) {
      lift.runTic(TicCmd.empty);
    }
    expect(
      lift.soundJournal.map((SoundEvent e) => e.soundId),
      containsAll(<String>['DSPSTART', 'DSPSTOP']),
    );
  });

  test('pickup, player pain, mob death, switch, and exit emit events', () {
    final GameState combat = GameState.start(
      testMap(
        things: const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 32, y: 64, angle: 0, type: 2007, flags: _skills),
          Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _skills),
        ],
      ),
      const GameConfig(monsters: true),
      seed: 3,
    );
    combat.runTic(TicCmd.empty);
    for (var i = 0; i < 20; i++) {
      combat.runTic(const TicCmd(buttons: Buttons.attack));
    }
    final Set<String> ids = combat.soundJournal
        .map((SoundEvent e) => e.soundId)
        .toSet();
    expect(ids, containsAll(<String>['DSITEMUP', 'DSPODTH1']));

    final GameState hurt = GameState.start(
      testMap(
        things: const <Thing>[
          Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 80, y: 64, angle: 180, type: 3004, flags: _skills),
        ],
      ),
      const GameConfig(),
    );
    hurt.runTic(TicCmd.empty);
    expect(
      hurt.soundJournal.map((SoundEvent e) => e.soundId),
      contains('DSPLPAIN'),
    );

    final GameState exit = GameState.start(
      testMap(
        sectors: twoSectors(),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.exitSwitchOnce)],
      ),
      const GameConfig(monsters: false),
    );
    exit.runTic(const TicCmd(buttons: Buttons.use));
    expect(exit.soundJournal.single.soundId, 'DSSWTCHX');
    expect(exit.soundJournal.single.origin, SoundOrigin.nonPositional);
  });

  test('shoot-activated switch emits its activation sound', () {
    final GameState game = GameState.start(
      testMap(
        sectors: <Sector>[
          twoSectors().first,
          const Sector(
            floorHeight: 0,
            ceilingHeight: 128,
            floorFlat: 'F',
            ceilingFlat: 'C',
            lightLevel: 160,
            special: 0,
            tag: 7,
          ),
        ],
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.floorRaise24, tag: 7)],
      ),
      const GameConfig(monsters: false),
    );
    game.runTic(const TicCmd(buttons: Buttons.attack));
    expect(
      game.soundJournal.map((SoundEvent e) => e.soundId),
      containsAllInOrder(<String>['DSPISTOL', 'DSSWTCHN']),
    );
  });

  test('journal is bounded, reports drops, and stays output-only', () {
    final GameState pending = GameState.start(
      testMap(),
      const GameConfig(monsters: false),
    );
    final GameState consumed = GameState.start(
      testMap(),
      const GameConfig(monsters: false),
    );
    for (var i = 0; i < 10000; i++) {
      pending.runTic(const TicCmd(buttons: Buttons.attack));
      consumed.runTic(const TicCmd(buttons: Buttons.attack));
      consumed.consumeSoundJournal();
    }

    expect(pending.soundJournal, hasLength(GameState.maxSoundJournalLength));
    expect(
      pending.droppedSoundEventCount,
      10000 - GameState.maxSoundJournalLength,
    );
    expect(pending.hashState(), consumed.hashState());
  });

  test('overflow discards an old expendable event before a critical cue', () {
    final GameState game = GameState.start(
      testMap(
        sectors: twoSectors(backCeiling: 32),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.doorOpenWaitClose)],
      ),
      const GameConfig(monsters: false),
    );
    game.runTic(const TicCmd(buttons: Buttons.use));
    for (var i = 0; i < GameState.maxSoundJournalLength; i++) {
      game.runTic(const TicCmd(buttons: Buttons.attack));
    }

    expect(game.soundJournal, hasLength(GameState.maxSoundJournalLength));
    expect(
      game.soundJournal.map((SoundEvent event) => event.soundId),
      contains('DSDOROPN'),
    );
    expect(game.droppedSoundEventCount, 2);
  });
}
