import 'package:doom_core/doom_core.dart';
import 'package:doom_core/src/game_state.dart' as game_state_internal;
import 'package:doom_core/src/mobj_states.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show portal, testMap, twoSectors, twoSides;

MapData fixture() => MapData.load(DoomFixtures.wadSet(), 'MAP01');

void main() {
  group('integer primitives', () {
    test('fixed overflow and divide guard are deterministic', () {
      expect(wrap32(0x100000001), 1);
      expect(fixedDiv(1, 0), 0x7fffffff);
      expect(fixedDiv(-1, 0), -0x7fffffff);
      expect(fixedDiv(0x40000000, 1), 0x7fffffff);
    });

    test('fixed division keeps result sign through saturation', () {
      expect(fixedDiv(-0x40000000, 1), -0x7fffffff);
      expect(fixedDiv(0x40000000, -1), -0x7fffffff);
      expect(fixedDiv(-0x40000000, -1), 0x7fffffff);
    });

    test('fixed absolute handles signed 32 bit minimum', () {
      expect(fixedAbs(-0x80000000), 0x80000000);
      expect(approxDistance(-0x80000000, 0), 0x80000000);
    });

    test('fixed multiply wraps signed 32 bit output', () {
      expect(fixedMul(0x7fffffff, toFixed(2)), -2);
    });

    test('fixed conversions retain arithmetic-shift semantics', () {
      expect(fixedToInt(-1), -1);
      expect(fixedToInt(toFixed(-3)), -3);
    });

    test('BAM wraps and has exact cardinal trig', () {
      expect(normalizeAngle(kAngMax + 3), 3);
      expect(Trig.cos(0), kFracUnit);
      expect(Trig.sin(kAng90), kFracUnit);
      expect(Trig.cos(kAng180), -kFracUnit);
      expect(Trig.sin(kAng270), -kFracUnit);
    });

    test('BAM atan2 has exact cardinals', () {
      expect(Trig.atan2(0, 1), 0);
      expect(Trig.atan2(1, 0), kAng90);
      expect(Trig.atan2(0, -1), kAng180);
      expect(Trig.atan2(-1, 0), kAng270);
    });

    test(
      'whole-degree import maps positive and negative cardinals exactly',
      () {
        expect(degreesToAngle(90), kAng90);
        expect(degreesToAngle(180), kAng180);
        expect(degreesToAngle(270), kAng270);
        expect(degreesToAngle(-90), kAng270);
      },
    );

    test('BAM atan2 selects all four quadrants', () {
      expect(Trig.atan2(1, 1), closeTo(kAng45, 0x10000));
      expect(Trig.atan2(1, -1), closeTo(kAng90 + kAng45, 0x10000));
      expect(Trig.atan2(-1, -1), closeTo(kAng180 + kAng45, 0x10000));
      expect(Trig.atan2(-1, 1), closeTo(kAng270 + kAng45, 0x10000));
    });

    test('BAM sine and cosine preserve quadrant signs', () {
      expect(Trig.sin(kAng45), greaterThan(0));
      expect(Trig.cos(kAng45), greaterThan(0));
      expect(Trig.sin(kAng180 + kAng45), lessThan(0));
      expect(Trig.cos(kAng180 + kAng45), lessThan(0));
    });

    test('BAM tangent clamps at both poles', () {
      expect(Trig.tan(kAng90), 0x7fffffff);
      expect(Trig.tan(kAng270), -0x7fffffff);
    });
  });

  test('fixed driver retains irregular-clock remainder and counts drops', () {
    final FixedTickDriver driver = FixedTickDriver(maxTicsPerFrame: 2);
    var count = 0;
    driver.advanceMicros(10000, (_) => count++, TicCmd.empty);
    driver.advanceMicros(20000, (_) => count++, TicCmd.empty);
    expect(count, 1);
    driver.advanceMicros(200000, (_) => count++, TicCmd.empty);
    expect(count, 3);
    expect(driver.droppedTics, greaterThan(0));
    expect(
      driver.interpolationNumerator,
      lessThan(driver.interpolationDenominator),
    );
  });

  test('fixed driver is exactly chunking invariant without drops', () {
    final FixedTickDriver one = FixedTickDriver(maxTicsPerFrame: 100);
    final FixedTickDriver many = FixedTickDriver(maxTicsPerFrame: 100);
    var oneCount = 0, manyCount = 0;
    one.advanceMicros(1000000, (_) => oneCount++, TicCmd.empty);
    for (int i = 0; i < 1000; i++) {
      many.advanceMicros(1000, (_) => manyCount++, TicCmd.empty);
    }
    expect((oneCount, one.interpolationNumerator), (35, 0));
    expect((manyCount, many.interpolationNumerator), (35, 0));
  });

  test('fixed driver drops excess without carrying a hidden backlog', () {
    final FixedTickDriver driver = FixedTickDriver(maxTicsPerFrame: 2);
    var count = 0;
    driver.advanceMicros(1000000, (_) => count++, TicCmd.empty);
    expect((count, driver.droppedTics, driver.executedTics), (2, 33, 2));
    driver.advanceMicros(0, (_) => count++, TicCmd.empty);
    expect(count, 2);
  });

  test(
    'fixed driver counts a terminating tic without dropping later due time',
    () {
      final FixedTickDriver driver = FixedTickDriver(maxTicsPerFrame: 4);
      var callbacks = 0;

      final int executed = driver.advanceMicrosWhile(1000000, (_) {
        callbacks++;
        return false;
      }, TicCmd.empty);

      expect(callbacks, 1);
      expect(executed, 1);
      expect(driver.executedTics, 1);
      expect(driver.droppedTics, 0);
      expect(driver.interpolationNumerator, 0);
    },
  );

  test('interpolation reads never execute simulation', () {
    final FixedTickDriver driver = FixedTickDriver();
    var count = 0;
    driver.advanceMicros(10000, (_) => count++, TicCmd.empty);
    final values = <Object>[
      driver.interpolationAlpha,
      driver.interpolationNumerator,
      driver.interpolationDenominator,
    ];
    expect(values, isNotEmpty);
    expect(count, 0);
  });

  test('walk and run input converge on fixed-point terminal speeds', () {
    int terminalDelta(int forwardMove) {
      final GameState game = GameState.start(
        testMap(vertices: const <MapVertex>[], lines: const <Linedef>[]),
        const GameConfig(monsters: false),
      );
      int previousX = game.player.x;
      int delta = 0;
      for (int i = 0; i < 1000; i++) {
        game.runTic(TicCmd(forwardMove: forwardMove));
        delta = game.player.x - previousX;
        previousX = game.player.x;
      }
      return delta;
    }

    final int walkDelta = terminalDelta(25);
    final int runDelta = terminalDelta(50);
    print(
      'terminal speeds: walkFixed=$walkDelta '
      'walk=${fixedToDouble(walkDelta).toStringAsFixed(6)} '
      'runFixed=$runDelta '
      'run=${fixedToDouble(runDelta).toStringAsFixed(6)} units/tic',
    );
    expect(walkDelta, 546123);
    expect(fixedToDouble(runDelta), closeTo(16.67, 0.01));
  });

  test('airborne player input does not add thrust', () {
    final GameState game = GameState.start(
      testMap(vertices: const <MapVertex>[], lines: const <Linedef>[]),
      const GameConfig(monsters: false),
    );
    final int startX = game.player.x;
    game_state_internal.setPlayerZForTesting(game, toFixed(1));

    game.runTic(const TicCmd(forwardMove: 50));

    expect(game.player.x, startX);
  });

  test('bob remains speed-dependent and bounded at vanilla movement scale', () {
    GameState movingGame() => GameState.start(
      testMap(vertices: const <MapVertex>[], lines: const <Linedef>[]),
      const GameConfig(monsters: false),
    );

    final GameState walk = movingGame();
    final GameState run = movingGame();
    int walkPeak = 0;
    int runPeak = 0;
    for (int i = 0; i < 200; i++) {
      walk.runTic(const TicCmd(forwardMove: 25));
      run.runTic(const TicCmd(forwardMove: 50));
      walkPeak = walkPeak < walk.player.bob.abs()
          ? walk.player.bob.abs()
          : walkPeak;
      runPeak = runPeak < run.player.bob.abs() ? run.player.bob.abs() : runPeak;
    }
    print(
      'bob peaks: walk=${fixedToDouble(walkPeak).toStringAsFixed(6)} '
      'run=${fixedToDouble(runPeak).toStringAsFixed(6)}',
    );
    expect(walkPeak, greaterThan(0));
    expect(walkPeak, lessThan(runPeak));
    expect(fixedToDouble(runPeak), closeTo(8.0, 0.001));
  });

  test('camera stays below the current moving sector ceiling', () {
    final MapData map = testMap(
      sectors: const <Sector>[
        Sector(
          floorHeight: 0,
          ceilingHeight: 32,
          floorFlat: 'F',
          ceilingFlat: 'C',
          lightLevel: 160,
          special: 0,
          tag: 7,
        ),
        Sector(
          floorHeight: 0,
          ceilingHeight: 128,
          floorFlat: 'F',
          ceilingFlat: 'C',
          lightLevel: 160,
          special: 0,
          tag: 0,
        ),
      ],
      sides: twoSides(),
      lines: <Linedef>[portal(special: LineSpecial.doorOpenWaitClose, tag: 7)],
    );
    final GameState game = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    expect(game.playerSectorIndex, 0);
    expect(game.player.viewZ, toFixed(28));

    game.runTic(const TicCmd(buttons: Buttons.use));
    game.runTic(TicCmd.empty);
    expect(map.sectors[0].ceilingHeight, 32);
    expect(game.sectors.elementAt(0).ceilingHeight, toFixed(36));
    expect(game.player.viewZ, toFixed(32));

    int previousCeiling = game.sectors.elementAt(0).ceilingHeight;
    bool observedDescendingCeiling = false;
    for (int i = 0; i < 220; i++) {
      game.runTic(TicCmd.empty);
      final int ceiling = game.sectors.elementAt(0).ceilingHeight;
      if (ceiling < previousCeiling) observedDescendingCeiling = true;
      expect(game.player.viewZ, lessThanOrEqualTo(ceiling - toFixed(4)));
      previousCeiling = ceiling;
    }
    expect(observedDescendingCeiling, isTrue);
  });

  test('camera clamp also covers a static low passage', () {
    final GameState game = GameState.start(
      testMap(
        sectors: const <Sector>[
          Sector(
            floorHeight: 0,
            ceilingHeight: 44,
            floorFlat: 'F',
            ceilingFlat: 'C',
            lightLevel: 160,
            special: 0,
            tag: 0,
          ),
        ],
      ),
      const GameConfig(monsters: false),
    );
    expect(game.player.viewZ, toFixed(40));
  });

  test('fixed driver rejects a negative frame delta', () {
    final FixedTickDriver driver = FixedTickDriver();
    expect(
      () => driver.advanceMicros(-1, (_) {}, TicCmd.empty),
      throwsArgumentError,
    );
  });

  test('replay is repeatable and chunking does not affect state', () {
    final List<TicCmd> commands = List<TicCmd>.generate(
      20,
      (int i) => TicCmd(
        forwardMove: i.isEven ? 10 : 0,
        angleTurn: 0x200,
        buttons: i % 5 == 0 ? Buttons.attack : 0,
      ),
    );
    final GameState a = GameState.start(fixture(), const GameConfig(), seed: 7);
    final GameState b = GameState.start(fixture(), const GameConfig(), seed: 7);
    final List<int> ah = CommandReplay(seed: 7, commands: commands).run(a);
    final List<int> bh = CommandReplay(seed: 7, commands: commands).run(b);
    expect(ah, bh);
    expect(a.hashState(), b.hashState());
    // Golden input: synthetic MAP01, seed 7, twenty commands above.
    // The long-linedef collision predicate changes the recorded position and
    // momentum; ordered actor ids, state records, and shared chase RNG remain
    // part of the same future-affecting replay identity. Barrel no-blood flags
    // and exact monster ray-circle targeting and actor hit effects are
    // future-affecting too.
    expect(a.hashState(), 0xe553be3f);
  });

  test('replay hash ignores an unused actor-state table insertion', () {
    int replayHash() {
      final List<TicCmd> commands = List<TicCmd>.generate(
        20,
        (int i) => TicCmd(
          forwardMove: i.isEven ? 10 : 0,
          angleTurn: 0x200,
          buttons: i % 5 == 0 ? Buttons.attack : 0,
        ),
      );
      final GameState game = GameState.start(
        fixture(),
        const GameConfig(),
        seed: 7,
      );
      CommandReplay(seed: 7, commands: commands).run(game);
      return game.hashState();
    }

    final int baseline = replayHash();
    final int shifted = MobjStateTable.withUnusedStateInsertedForTesting(
      before: 0,
      body: replayHash,
    );

    print(
      'replay insertion probe: '
      'baseline=0x${baseline.toRadixString(16).padLeft(8, '0')} '
      'shifted=0x${shifted.toRadixString(16).padLeft(8, '0')}',
    );
    expect(shifted, baseline);
  });

  test(
    'different seeds enter the replay hash before the first random draw',
    () {
      final GameState a = GameState.start(
        fixture(),
        const GameConfig(),
        seed: 1,
      );
      final GameState b = GameState.start(
        fixture(),
        const GameConfig(),
        seed: 2,
      );
      expect(a.hashState(), isNot(b.hashState()));
    },
  );

  test('game state is identical across render-frame chunkings', () {
    final GameState a = GameState.start(
      fixture(),
      const GameConfig(monsters: false),
      seed: 9,
    );
    final GameState b = GameState.start(
      fixture(),
      const GameConfig(monsters: false),
      seed: 9,
    );
    final FixedTickDriver one = FixedTickDriver(maxTicsPerFrame: 100);
    final FixedTickDriver many = FixedTickDriver(maxTicsPerFrame: 100);
    one.advanceMicros(1000000, a.runTic, const TicCmd(forwardMove: 1));
    for (int i = 0; i < 1000; i++) {
      many.advanceMicros(1000, b.runTic, const TicCmd(forwardMove: 1));
    }
    expect((a.tic, a.hashState()), (35, b.hashState()));
  });

  test('use-button latch is part of future-affecting replay state', () {
    final GameState held = GameState.start(
      testMap(),
      const GameConfig(monsters: false),
    );
    final GameState released = GameState.start(
      testMap(),
      const GameConfig(monsters: false),
    );
    held.runTic(const TicCmd(buttons: Buttons.use));
    released.runTic(TicCmd.empty);
    expect(held.hashState(), isNot(released.hashState()));
  });

  test('consuming pending sector journal does not alter replay hash', () {
    final MapData map = testMap(
      sectors: twoSectors(backCeiling: 32),
      sides: twoSides(),
      lines: <Linedef>[portal(special: LineSpecial.doorOpenStay)],
    );
    final GameState pending = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    final GameState consumed = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    for (final GameState game in <GameState>[pending, consumed]) {
      game.runTic(const TicCmd(buttons: Buttons.use));
      game.runTic(TicCmd.empty);
    }
    expect(pending.changeJournal, isNotEmpty);
    expect(consumed.consumeChangeJournal(), isNotEmpty);
    expect(pending.hashState(), consumed.hashState());
  });

  test(
    'no-benefit health pickup remains while actor identity stays hashed',
    () {
      final GameState base = GameState.start(
        testMap(),
        const GameConfig(monsters: false),
      );
      final GameState allocated = GameState.start(
        testMap(
          things: const <Thing>[
            Thing(
              x: 64,
              y: 64,
              angle: 0,
              type: 1,
              flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
            ),
            Thing(
              x: 64,
              y: 64,
              angle: 0,
              type: 2011,
              flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
            ),
          ],
        ),
        const GameConfig(monsters: false),
      );
      base.runTic(TicCmd.empty);
      allocated.runTic(TicCmd.empty);
      expect(base.player.health, allocated.player.health);
      expect(
        allocated.mobjs.map((MobjView actor) => actor.sprite),
        contains('STIM'),
      );
      expect(allocated.mobjs.length, base.mobjs.length + 1);
      expect(base.hashState(), isNot(allocated.hashState()));
    },
  );
}
