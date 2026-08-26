import 'dart:typed_data';

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MapData testMap({
  List<Sector>? sectors,
  List<Linedef>? lines,
  List<Sidedef>? sides,
  List<Thing>? things,
  Blockmap? blockmap,
}) {
  final List<MapVertex> vertices = <MapVertex>[
    const MapVertex(0, 0),
    const MapVertex(128, 0),
    const MapVertex(128, 128),
    const MapVertex(0, 128),
    const MapVertex(256, 0),
    const MapVertex(256, 128),
  ];
  return MapData(
    name: 'TEST',
    vertices: vertices,
    linedefs:
        lines ??
        <Linedef>[
          const Linedef(
            v1: 0,
            v2: 1,
            flags: LinedefFlags.blocking,
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
          const Linedef(
            v1: 2,
            v2: 3,
            flags: LinedefFlags.blocking,
            special: 0,
            tag: 0,
            rightSidedef: 0,
            leftSidedef: kNoSidedef,
          ),
          const Linedef(
            v1: 3,
            v2: 0,
            flags: LinedefFlags.blocking,
            special: 0,
            tag: 0,
            rightSidedef: 0,
            leftSidedef: kNoSidedef,
          ),
        ],
    sidedefs:
        sides ??
        <Sidedef>[
          const Sidedef(
            xOffset: 0,
            yOffset: 0,
            upperTexture: '-',
            lowerTexture: '-',
            middleTexture: '-',
            sector: 0,
          ),
        ],
    sectors:
        sectors ??
        <Sector>[
          const Sector(
            floorHeight: 0,
            ceilingHeight: 128,
            floorFlat: 'F',
            ceilingFlat: 'C',
            lightLevel: 160,
            special: 0,
            tag: 0,
          ),
        ],
    segs: const <Seg>[],
    subsectors: const <Subsector>[],
    nodes: const <BspNode>[],
    things:
        things ??
        <Thing>[
          const Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
        ],
    blockmap: blockmap,
    reject: null,
  );
}

Linedef portal({int special = 0, int tag = 0, bool opening = true}) => Linedef(
  v1: 2,
  v2: 1,
  flags: LinedefFlags.twoSided,
  special: special,
  tag: tag,
  rightSidedef: 0,
  leftSidedef: 1,
);
List<Sidedef> twoSides() => const <Sidedef>[
  Sidedef(
    xOffset: 0,
    yOffset: 0,
    upperTexture: '-',
    lowerTexture: '-',
    middleTexture: '-',
    sector: 0,
  ),
  Sidedef(
    xOffset: 0,
    yOffset: 0,
    upperTexture: '-',
    lowerTexture: '-',
    middleTexture: '-',
    sector: 1,
  ),
];
List<Sidedef> switchSides() => const <Sidedef>[
  Sidedef(
    xOffset: 0,
    yOffset: 0,
    upperTexture: 'SW1COMP',
    lowerTexture: '-',
    middleTexture: '-',
    sector: 0,
  ),
  Sidedef(
    xOffset: 0,
    yOffset: 0,
    upperTexture: '-',
    lowerTexture: '-',
    middleTexture: '-',
    sector: 1,
  ),
];
List<Sector> twoSectors({
  int backFloor = 0,
  int backCeiling = 128,
  int backSpecial = 0,
}) => <Sector>[
  const Sector(
    floorHeight: 0,
    ceilingHeight: 128,
    floorFlat: 'F',
    ceilingFlat: 'C',
    lightLevel: 160,
    special: 0,
    tag: 0,
  ),
  Sector(
    floorHeight: backFloor,
    ceilingHeight: backCeiling,
    floorFlat: 'F',
    ceilingFlat: 'C',
    lightLevel: 160,
    special: backSpecial,
    tag: 0,
  ),
];

void main() {
  group('runtime map/collision', () {
    test('one sided boundary blocks player', () {
      final GameState game = GameState.start(
        testMap(),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 30; i++) {
        game.runTic(const TicCmd(forwardMove: 50));
      }
      expect(game.player.x, lessThan(toFixed(128)));
    });

    test('two sided opening permits movement', () {
      final MapData map = testMap(
        sectors: twoSectors(),
        sides: twoSides(),
        lines: <Linedef>[portal()],
      );
      final GameState game = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(forwardMove: 10));
      }
      expect(game.player.x, greaterThan(toFixed(64)));
    });

    test('a 24 unit step is inclusive', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backFloor: 24),
          sides: twoSides(),
          lines: <Linedef>[portal()],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 12; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.z, toFixed(24));
    });

    test('a 25 unit step is rejected', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backFloor: 25),
          sides: twoSides(),
          lines: <Linedef>[portal()],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, lessThan(toFixed(128)));
    });

    test('a drop taller than 24 units is rejected', () {
      final List<Sector> sectors = twoSectors(backFloor: -25);
      final GameState game = GameState.start(
        testMap(
          sectors: sectors,
          sides: twoSides(),
          lines: <Linedef>[portal()],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, lessThan(toFixed(128)));
    });

    test('low destination ceiling rejects a tall actor', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backFloor: 24, backCeiling: 79),
          sides: twoSides(),
          lines: <Linedef>[portal()],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, lessThan(toFixed(112)));
    });

    test('solid actor blocks player movement', () {
      final GameState game = GameState.start(
        testMap(
          things: const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _allSkills),
            Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, lessThan(toFixed(60)));
    });

    test('diagonal collision slides along wall without recursion', () {
      final GameState game = GameState.start(
        testMap(),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 30; i++) {
        game.runTic(const TicCmd(forwardMove: 8, sideMove: 8));
      }
      expect(game.player.x, lessThan(toFixed(112)));
      expect(game.player.y, isNot(toFixed(64)));
    });

    test('circle collision includes a linedef endpoint', () {
      final GameState game = GameState.start(
        testMap(),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 30; i++) {
        game.runTic(const TicCmd(forwardMove: 8, sideMove: 8));
      }
      final int dx = game.player.x - toFixed(128);
      final int dy = game.player.y;
      expect(
        dx * dx + dy * dy,
        greaterThanOrEqualTo(toFixed(16) * toFixed(16)),
      );
    });

    test(
      'closed two sided door blocks because opening is below player height',
      () {
        final MapData map = testMap(
          sectors: twoSectors(backCeiling: 40),
          sides: twoSides(),
          lines: <Linedef>[portal()],
        );
        final GameState game = GameState.start(
          map,
          const GameConfig(monsters: false),
        );
        for (int i = 0; i < 20; i++) {
          game.runTic(const TicCmd(forwardMove: 10));
        }
        expect(game.player.x, lessThan(toFixed(112)));
      },
    );

    test('null, valid and incomplete BLOCKMAP collision are equivalent', () {
      final MapData bare = testMap();
      final Blockmap blocks = Blockmap(
        originX: 0,
        originY: 0,
        columns: 1,
        rows: 1,
        cells: <Uint16List>[
          Uint16List.fromList(<int>[0, 1, 2, 3]),
        ],
      );
      final MapData mapped = testMap(blockmap: blocks);
      final MapData incomplete = testMap(
        blockmap: Blockmap(
          originX: 0,
          originY: 0,
          columns: 1,
          rows: 1,
          // Valid but unrelated bottom edge; east wall line 1 is omitted.
          cells: <Uint16List>[
            Uint16List.fromList(<int>[0]),
          ],
        ),
      );
      final MapData outOfRange = testMap(
        blockmap: Blockmap(
          originX: 1000,
          originY: 1000,
          columns: 1,
          rows: 1,
          cells: <Uint16List>[
            Uint16List.fromList(<int>[0, 1, 2, 3]),
          ],
        ),
      );
      final GameState a = GameState.start(
        bare,
        const GameConfig(monsters: false),
      );
      final GameState b = GameState.start(
        mapped,
        const GameConfig(monsters: false),
      );
      final GameState c = GameState.start(
        incomplete,
        const GameConfig(monsters: false),
      );
      final GameState d = GameState.start(
        outOfRange,
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 10; i++) {
        a.runTic(const TicCmd(forwardMove: 14));
        b.runTic(const TicCmd(forwardMove: 14));
        c.runTic(const TicCmd(forwardMove: 14));
        d.runTic(const TicCmd(forwardMove: 14));
      }
      expect(a.hashState(), b.hashState());
      expect(a.hashState(), c.hashState());
      expect(a.hashState(), d.hashState());
      expect(c.player.x, lessThan(toFixed(128)));
    });
  });

  group('doors, lifts and effects', () {
    test(
      'animation frame lookup is derived output and does not mutate hash',
      () {
        final GameState game = GameState.start(
          testMap(),
          const GameConfig(monsters: false),
        );
        final int before = game.hashState();
        expect(game.animationFrameIndex(frameCount: 3, speed: 8), 0);
        expect(game.hashState(), before);
      },
    );

    test(
      'S1 switch stays pressed and its future-affecting state is hashed',
      () {
        final MapData map = testMap(
          sectors: twoSectors(backCeiling: 32),
          sides: switchSides(),
          lines: <Linedef>[
            portal(special: LineSpecial.switchDoorOpenWaitClose),
          ],
        );
        final GameState idle = GameState.start(
          map,
          const GameConfig(monsters: false),
        );
        final GameState pressed = GameState.start(
          map,
          const GameConfig(monsters: false),
        );
        idle.runTic(TicCmd.empty);
        pressed.runTic(const TicCmd(buttons: Buttons.use));
        expect(pressed.switchJournal.single.textureName, 'SW2COMP');
        expect(pressed.hashState(), isNot(idle.hashState()));
        final int pressedHash = pressed.hashState();
        pressed.consumeSwitchJournal();
        expect(
          pressed.hashState(),
          pressedHash,
          reason: 'journal is output-only',
        );
        for (var i = 0; i < 200; i++) {
          pressed.runTic(TicCmd.empty);
        }
        expect(pressed.switchJournal, isEmpty, reason: 'S1 never resets');
        pressed.runTic(const TicCmd(buttons: Buttons.use));
        expect(pressed.switchJournal, isEmpty, reason: 'S1 never reactivates');
      },
    );

    test('SR switch resets then can toggle on again', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backFloor: 32),
          sides: switchSides(),
          lines: <Linedef>[portal(special: LineSpecial.liftDownWaitUpTurbo)],
        ),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      expect(game.consumeSwitchJournal().single.textureName, 'SW2COMP');
      game.consumeSoundJournal();
      for (var i = 0; i < 35; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.consumeSwitchJournal().single.textureName, 'SW1COMP');
      expect(game.consumeSoundJournal().single.soundId, 'DSSWTCHN');
      for (var i = 0; i < 30; i++) {
        game.runTic(TicCmd.empty);
      }
      game.runTic(const TicCmd(buttons: Buttons.use));
      expect(game.consumeSwitchJournal().single.textureName, 'SW2COMP');
    });

    test('pressed SR timer alone changes future-state hash', () {
      GameState build(List<Sidedef> sides) => GameState.start(
        testMap(
          sectors: twoSectors(backFloor: 32),
          sides: sides,
          lines: <Linedef>[portal(special: LineSpecial.liftDownWaitUpTurbo)],
        ),
        const GameConfig(monsters: false),
      );
      final GameState ordinary = build(twoSides());
      final GameState switched = build(switchSides());
      ordinary.runTic(const TicCmd(buttons: Buttons.use));
      switched.runTic(const TicCmd(buttons: Buttons.use));
      expect(switched.hashState(), isNot(ordinary.hashState()));
    });

    test('tag zero manual door opens waits then closes', () {
      final MapData map = testMap(
        sectors: twoSectors(backCeiling: 32),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.doorOpenWaitClose)],
      );
      final GameState game = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 25; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).ceilingHeight, toFixed(124));
      for (int i = 0; i < 200; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).ceilingHeight, toFixed(32));
    });

    test('door stay-open completes without closing', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backCeiling: 32),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.doorOpenStay)],
        ),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 200; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).ceilingHeight, toFixed(124));
      expect(game.sectors.elementAt(1).hasMover, isFalse);
    });

    test('closing door reopens when player obstructs it', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backCeiling: 32),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.doorOpenWaitClose)],
          things: const <Thing>[
            Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
            Thing(x: 160, y: 64, angle: 0, type: 2035, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 25; i++) {
        game.runTic(TicCmd.empty);
      }
      for (int i = 0; i < 210; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).ceilingHeight, greaterThan(toFixed(48)));
      expect(game.mobjs.where((MobjView m) => m.sprite == 'BAR1'), isNotEmpty);
    });

    test('closing door ignores a non-solid quarter-height corpse', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backCeiling: 32),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.doorOpenWaitClose)],
          things: const <Thing>[
            Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
            Thing(x: 160, y: 64, angle: 180, type: 3004, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
        seed: 3,
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (var tic = 0; tic < 25; tic++) {
        game.runTic(TicCmd.empty);
      }
      while (game.mobjs
              .firstWhere((MobjView actor) => actor.sprite == 'POSS')
              .health >
          0) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      final MobjView corpse = game.mobjs.firstWhere(
        (MobjView actor) => actor.sprite == 'POSS',
      );
      expect(corpse.flags & 0x0002, 0);
      expect(corpse.height, toFixed(14));
      for (var tic = 0; tic < 250; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).ceilingHeight, toFixed(32));
    });

    test('mapped lift executes down-wait-up cycle', () {
      final List<Sector> sectors = twoSectors(backFloor: 32);
      final GameState game = GameState.start(
        testMap(
          sectors: sectors,
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.liftDownWaitUpSwitch)],
        ),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 10; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).floorHeight, toFixed(0));
      for (int i = 0; i < 50; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).floorHeight, toFixed(32));
    });

    test('mapped floor raise 24 executes to its target', () {
      final List<Sector> sectors = <Sector>[
        twoSectors()[0],
        const Sector(
          floorHeight: 0,
          ceilingHeight: 128,
          floorFlat: 'F',
          ceilingFlat: 'C',
          lightLevel: 160,
          special: 0,
          tag: 7,
        ),
      ];
      final GameState game = GameState.start(
        testMap(
          sectors: sectors,
          sides: switchSides(),
          lines: <Linedef>[portal(special: LineSpecial.floorRaise24, tag: 7)],
        ),
        const GameConfig(monsters: false),
      );
      for (var tic = 0; tic < 5; tic++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      expect(game.consumeSwitchJournal().single.textureName, 'SW2COMP');
      for (int i = 0; i < 25; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).floorHeight, toFixed(24));
      expect(game.switchJournal, isEmpty, reason: 'gun switch never resets');

      for (var tic = 0; tic < 5; tic++) {
        game.runTic(const TicCmd(buttons: Buttons.attack));
      }
      for (int i = 0; i < 25; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).floorHeight, toFixed(24));
      expect(game.switchJournal, isEmpty, reason: 'gun switch is one-shot');
    });

    test('sector journal retains multiple tics until consumed', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backCeiling: 32),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.doorOpenStay)],
        ),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      game.runTic(TicCmd.empty);
      game.runTic(TicCmd.empty);
      expect(game.changeJournal.length, 2);
      expect(game.consumeChangeJournal().length, 2);
      expect(game.changeJournal, isEmpty);
    });

    test('secret sector is counted once', () {
      final GameState game = GameState.start(
        testMap(
          sectors: const <Sector>[
            Sector(
              floorHeight: 0,
              ceilingHeight: 128,
              floorFlat: 'F',
              ceilingFlat: 'C',
              lightLevel: 160,
              special: SectorSpecial.secret,
              tag: 0,
            ),
          ],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 10; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.secretsFound, 1);
    });

    test('sector damage runs every 32 tics and armor absorbs one third', () {
      final GameState game = GameState.start(
        testMap(
          sectors: const <Sector>[
            Sector(
              floorHeight: 0,
              ceilingHeight: 128,
              floorFlat: 'F',
              ceilingFlat: 'C',
              lightLevel: 160,
              special: SectorSpecial.damage10,
              tag: 0,
            ),
          ],
          things: const <Thing>[
            Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 2018, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 31; i++) {
        game.runTic(TicCmd.empty);
      }
      expect((game.player.health, game.player.armor), (100, 100));
      game.runTic(TicCmd.empty);
      expect((game.player.health, game.player.armor), (93, 97));
    });

    test('flicker light and journal are deterministic for a seed', () {
      final List<Sector> sectors = const <Sector>[
        Sector(
          floorHeight: 0,
          ceilingHeight: 128,
          floorFlat: 'F',
          ceilingFlat: 'C',
          lightLevel: 160,
          special: SectorSpecial.lightFlicker,
          tag: 0,
        ),
      ];
      final GameState a = GameState.start(
        testMap(sectors: sectors),
        const GameConfig(monsters: false),
        seed: 18,
      );
      final GameState b = GameState.start(
        testMap(sectors: sectors),
        const GameConfig(monsters: false),
        seed: 18,
      );
      for (int i = 0; i < 20; i++) {
        a.runTic(TicCmd.empty);
        b.runTic(TicCmd.empty);
      }
      expect(a.hashState(), b.hashState());
      expect(a.changeJournal.length, b.changeJournal.length);
      expect(a.changeJournal, isNotEmpty);
    });

    test('locked blue door denies then accepts blue key', () {
      final MapData locked = testMap(
        sectors: twoSectors(backCeiling: 32),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.blueDoorOpenWaitClose)],
        things: <Thing>[
          const Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
        ],
      );
      final GameState denied = GameState.start(
        locked,
        const GameConfig(monsters: false),
      );
      denied.runTic(const TicCmd(buttons: Buttons.use));
      expect(denied.sectors.elementAt(1).hasMover, isFalse);
      final MapData keyed = testMap(
        sectors: twoSectors(backCeiling: 32),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.blueDoorOpenWaitClose)],
        things: <Thing>[
          const Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
          const Thing(x: 64, y: 64, angle: 0, type: 5, flags: _allSkills),
        ],
      );
      final GameState allowed = GameState.start(
        keyed,
        const GameConfig(monsters: false),
      );
      allowed.runTic(TicCmd.empty);
      allowed.runTic(const TicCmd(buttons: Buttons.use));
      expect(allowed.player.keys, contains(Key.blue));
      expect(allowed.sectors.elementAt(1).hasMover, isTrue);
    });

    test('switch-use normal exit 11 completes only from the front side', () {
      final GameState front = GameState.start(
        testMap(
          sectors: twoSectors(),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.exitSwitchOnce)],
        ),
        const GameConfig(monsters: false),
      );
      front.runTic(const TicCmd(buttons: Buttons.use));
      expect(front.levelComplete, isTrue);
      expect(front.usedSecretExit, isFalse);

      final GameState back = GameState.start(
        testMap(
          sectors: twoSectors(),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.exitSwitchOnce)],
          things: const <Thing>[
            Thing(x: 160, y: 64, angle: 180, type: 1, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
      );
      back.runTic(const TicCmd(buttons: Buttons.use));
      expect(back.levelComplete, isFalse);
    });

    test('switch-use secret exit 51 records secret intent', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(),
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.secretExitSwitchOnce)],
        ),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      expect(game.levelComplete, isTrue);
      expect(game.usedSecretExit, isTrue);
    });

    test('crossing switch exits 11 and 51 does not complete', () {
      for (final int special in <int>[
        LineSpecial.exitSwitchOnce,
        LineSpecial.secretExitSwitchOnce,
      ]) {
        final GameState game = GameState.start(
          testMap(
            sectors: twoSectors(),
            sides: twoSides(),
            lines: <Linedef>[portal(special: special)],
          ),
          const GameConfig(monsters: false),
        );
        for (int i = 0; i < 20; i++) {
          game.runTic(const TicCmd(forwardMove: 10));
        }
        expect(game.levelComplete, isFalse, reason: 'special $special');
      }
    });

    test(
      'walk-once exits 52 and 124 complete in either crossing direction',
      () {
        final GameState normal = GameState.start(
          testMap(
            sectors: twoSectors(),
            sides: twoSides(),
            lines: <Linedef>[portal(special: LineSpecial.exitWalkOnce)],
          ),
          const GameConfig(monsters: false),
        );
        for (int i = 0; i < 20; i++) {
          normal.runTic(const TicCmd(forwardMove: 10));
        }
        expect(normal.levelComplete, isTrue);
        expect(normal.usedSecretExit, isFalse);

        final GameState secret = GameState.start(
          testMap(
            sectors: twoSectors(),
            sides: twoSides(),
            lines: <Linedef>[portal(special: LineSpecial.secretExitWalkOnce)],
            things: const <Thing>[
              Thing(x: 160, y: 64, angle: 180, type: 1, flags: _allSkills),
            ],
          ),
          const GameConfig(monsters: false),
        );
        for (int i = 0; i < 20; i++) {
          secret.runTic(const TicCmd(forwardMove: 10));
        }
        expect(secret.levelComplete, isTrue);
        expect(secret.usedSecretExit, isTrue);
      },
    );

    test('using an unrelated or walk-only line does not exit', () {
      for (final int special in <int>[0, LineSpecial.exitWalkOnce]) {
        final GameState game = GameState.start(
          testMap(
            sectors: twoSectors(),
            sides: twoSides(),
            lines: <Linedef>[portal(special: special)],
          ),
          const GameConfig(monsters: false),
        );
        game.runTic(const TicCmd(buttons: Buttons.use));
        expect(game.levelComplete, isFalse, reason: 'special $special');
      }
    });

    test('secret sector and completion remain independently public', () {
      final MapData map = testMap(
        sectors: twoSectors(backSpecial: SectorSpecial.secret),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.exitWalkOnce)],
      );
      final GameState game = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(forwardMove: 10));
      }
      expect(game.levelComplete, isTrue);
      expect(game.secretsFound, 1);
    });
  });
}
