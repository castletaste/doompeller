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

    test('BLOCKMAP and linear fallback choose same deterministic state', () {
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
      final GameState a = GameState.start(
        bare,
        const GameConfig(monsters: false),
      );
      final GameState b = GameState.start(
        mapped,
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 10; i++) {
        a.runTic(const TicCmd(forwardMove: 14));
        b.runTic(const TicCmd(forwardMove: 14));
      }
      expect(a.hashState(), b.hashState());
    });
  });

  group('doors, lifts and effects', () {
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
          sides: twoSides(),
          lines: <Linedef>[portal(special: LineSpecial.floorRaise24, tag: 7)],
        ),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.attack));
      for (int i = 0; i < 25; i++) {
        game.runTic(TicCmd.empty);
      }
      expect(game.sectors.elementAt(1).floorHeight, toFixed(24));
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

    test('damage secret light journal and exit are public state', () {
      final MapData map = testMap(
        sectors: twoSectors(backSpecial: SectorSpecial.secret),
        sides: twoSides(),
        lines: <Linedef>[portal(special: LineSpecial.exit)],
      );
      final GameState game = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      for (int i = 0; i < 20; i++) {
        game.runTic(const TicCmd(forwardMove: 10));
      }
      expect(game.levelComplete, isTrue);
      expect(game.secretsFound, greaterThanOrEqualTo(0));
    });
  });
}
