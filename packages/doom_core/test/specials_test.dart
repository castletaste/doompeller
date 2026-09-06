import 'dart:typed_data';

import 'package:doom_core/doom_core.dart';
import 'package:doom_core/src/game_state.dart' as game_state_internal;
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MapData testMap({
  List<MapVertex>? vertices,
  List<Sector>? sectors,
  List<Linedef>? lines,
  List<Sidedef>? sides,
  List<Thing>? things,
  Blockmap? blockmap,
}) {
  final List<MapVertex> defaultVertices = <MapVertex>[
    const MapVertex(0, 0),
    const MapVertex(128, 0),
    const MapVertex(128, 128),
    const MapVertex(0, 128),
    const MapVertex(256, 0),
    const MapVertex(256, 128),
  ];
  return MapData(
    name: 'TEST',
    vertices: vertices ?? defaultVertices,
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

MapData taggedSpecialMap({
  required int special,
  int targetFloor = 0,
  int targetCeiling = 128,
  List<int> neighborFloors = const <int>[0, 0],
  List<int> neighborCeilings = const <int>[128, 128],
  bool switchTexture = false,
  List<Thing> extraThings = const <Thing>[],
  int playerX = 64,
  int playerAngle = 0,
  String sourceFloorFlat = 'STAIR',
  int sourceSpecial = 0,
  String targetFloorFlat = 'STAIR',
  int targetSpecial = 0,
  List<String> neighborFloorFlats = const <String>['STAIR', 'STAIR'],
  List<int> neighborSpecials = const <int>[0, 0],
}) {
  assert(neighborFloors.length == 2);
  assert(neighborCeilings.length == 2);
  assert(neighborFloorFlats.length == 2);
  assert(neighborSpecials.length == 2);
  const List<MapVertex> vertices = <MapVertex>[
    MapVertex(128, 128),
    MapVertex(128, 0),
    MapVertex(0, 320),
    MapVertex(128, 320),
    MapVertex(0, 384),
    MapVertex(128, 384),
  ];
  Sidedef side(int sector, {String upper = '-'}) => Sidedef(
    xOffset: 0,
    yOffset: 0,
    upperTexture: upper,
    lowerTexture: '-',
    middleTexture: '-',
    sector: sector,
  );
  Sector sector({
    required int floor,
    required int ceiling,
    int tag = 0,
    String floorFlat = 'STAIR',
    int special = 0,
  }) => Sector(
    floorHeight: floor,
    ceilingHeight: ceiling,
    floorFlat: floorFlat,
    ceilingFlat: 'C',
    lightLevel: 160,
    special: special,
    tag: tag,
  );
  return MapData(
    name: 'TAGGED',
    vertices: vertices,
    linedefs: <Linedef>[
      Linedef(
        v1: 0,
        v2: 1,
        flags: LinedefFlags.twoSided,
        special: special,
        tag: 7,
        rightSidedef: 0,
        leftSidedef: 1,
      ),
      const Linedef(
        v1: 2,
        v2: 3,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 2,
        leftSidedef: 3,
      ),
      const Linedef(
        v1: 4,
        v2: 5,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 2,
        leftSidedef: 4,
      ),
    ],
    sidedefs: <Sidedef>[
      side(0, upper: switchTexture ? 'SW1COMP' : '-'),
      side(1),
      side(2),
      side(3),
      side(4),
    ],
    sectors: <Sector>[
      sector(
        floor: 0,
        ceiling: 128,
        floorFlat: sourceFloorFlat,
        special: sourceSpecial,
      ),
      sector(floor: 0, ceiling: 128),
      sector(
        floor: targetFloor,
        ceiling: targetCeiling,
        tag: 7,
        floorFlat: targetFloorFlat,
        special: targetSpecial,
      ),
      sector(
        floor: neighborFloors[0],
        ceiling: neighborCeilings[0],
        floorFlat: neighborFloorFlats[0],
        special: neighborSpecials[0],
      ),
      sector(
        floor: neighborFloors[1],
        ceiling: neighborCeilings[1],
        floorFlat: neighborFloorFlats[1],
        special: neighborSpecials[1],
      ),
    ],
    segs: const <Seg>[],
    subsectors: const <Subsector>[],
    nodes: const <BspNode>[],
    things: <Thing>[
      Thing(x: playerX, y: 64, angle: playerAngle, type: 1, flags: _allSkills),
      ...extraThings,
    ],
    blockmap: null,
    reject: null,
  );
}

MapData stairMap(int special) {
  final MapData base = taggedSpecialMap(special: special);
  final List<Sector> sectors = List<Sector>.of(base.sectors)
    ..add(
      const Sector(
        floorHeight: 0,
        ceilingHeight: 128,
        floorFlat: 'STAIR',
        ceilingFlat: 'C',
        lightLevel: 160,
        special: 0,
        tag: 0,
      ),
    );
  final List<Sidedef> sides = List<Sidedef>.of(base.sidedefs)
    ..add(
      const Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: '-',
        lowerTexture: '-',
        middleTexture: '-',
        sector: 5,
      ),
    );
  final List<Linedef> lines = <Linedef>[
    base.linedefs[0],
    // Directed front-to-back chain 2 -> 3 -> 5. Sector 4 is another
    // neighbour but not on the stair chain.
    base.linedefs[1],
    const Linedef(
      v1: 4,
      v2: 5,
      flags: LinedefFlags.twoSided,
      special: 0,
      tag: 0,
      rightSidedef: 3,
      leftSidedef: 5,
    ),
  ];
  return MapData(
    name: base.name,
    vertices: base.vertices,
    linedefs: lines,
    sidedefs: sides,
    sectors: sectors,
    segs: base.segs,
    subsectors: base.subsectors,
    nodes: base.nodes,
    things: base.things,
    blockmap: null,
    reject: null,
  );
}

MapData withThings(MapData base, List<Thing> things) => MapData(
  name: base.name,
  vertices: base.vertices,
  linedefs: base.linedefs,
  sidedefs: base.sidedefs,
  sectors: base.sectors,
  segs: base.segs,
  subsectors: base.subsectors,
  nodes: base.nodes,
  things: things,
  blockmap: base.blockmap,
  reject: base.reject,
);

MapData crusherStopMap(int stopSpecial) {
  final MapData base = taggedSpecialMap(special: LineSpecial.walkCrusherRepeat);
  return MapData(
    name: 'CRUSHSTOP',
    vertices: <MapVertex>[
      ...base.vertices,
      const MapVertex(160, 128),
      const MapVertex(160, 0),
    ],
    linedefs: <Linedef>[
      ...base.linedefs,
      Linedef(
        v1: 6,
        v2: 7,
        flags: LinedefFlags.twoSided,
        special: stopSpecial,
        tag: 7,
        rightSidedef: 0,
        leftSidedef: 1,
      ),
    ],
    sidedefs: base.sidedefs,
    sectors: base.sectors,
    segs: base.segs,
    subsectors: base.subsectors,
    nodes: base.nodes,
    things: base.things,
    blockmap: null,
    reject: null,
  );
}

MapData donutMap({int extraTaggedSectors = 0}) {
  const List<MapVertex> vertices = <MapVertex>[
    MapVertex(128, 128),
    MapVertex(128, 0),
    MapVertex(0, 320),
    MapVertex(128, 320),
    MapVertex(0, 384),
    MapVertex(128, 384),
  ];
  const List<Sidedef> sides = <Sidedef>[
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
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 2,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 3,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 4,
    ),
  ];
  Sector sector(int floor, String flat, {int tag = 0, int special = 0}) =>
      Sector(
        floorHeight: floor,
        ceilingHeight: 128,
        floorFlat: flat,
        ceilingFlat: 'C',
        lightLevel: 160,
        special: special,
        tag: tag,
      );
  return MapData(
    name: 'DONUT',
    vertices: vertices,
    linedefs: const <Linedef>[
      Linedef(
        v1: 0,
        v2: 1,
        flags: LinedefFlags.twoSided,
        special: LineSpecial.switchDonutOnce,
        tag: 7,
        rightSidedef: 0,
        leftSidedef: 1,
      ),
      Linedef(
        v1: 2,
        v2: 3,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 2,
        leftSidedef: 3,
      ),
      Linedef(
        v1: 4,
        v2: 5,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 3,
        leftSidedef: 4,
      ),
    ],
    sidedefs: sides,
    sectors: <Sector>[
      sector(0, 'SOURCE'),
      sector(0, 'PLAYER'),
      sector(32, 'HOLE', tag: 7),
      sector(-16, 'RING', special: SectorSpecial.damage5),
      sector(0, 'OUTER'),
      for (var i = 0; i < extraTaggedSectors; i++)
        sector(32, 'HOSTILE', tag: 7),
    ],
    segs: const <Seg>[],
    subsectors: const <Subsector>[],
    nodes: const <BspNode>[],
    things: const <Thing>[
      Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
    ],
    blockmap: null,
    reject: null,
  );
}

MapData donutLookupMap(int sectorCount, {required bool hasTag}) {
  if (sectorCount < 5) throw ArgumentError.value(sectorCount, 'sectorCount');
  Sector sector(int floor, String flat, {int tag = 0}) => Sector(
    floorHeight: floor,
    ceilingHeight: 128,
    floorFlat: flat,
    ceilingFlat: 'C',
    lightLevel: 160,
    special: 0,
    tag: tag,
  );
  final int hole = sectorCount - 1;
  return MapData(
    name: 'DONUT_LOOKUP',
    vertices: const <MapVertex>[
      MapVertex(128, 128),
      MapVertex(128, 0),
      MapVertex(0, 320),
      MapVertex(128, 320),
      MapVertex(0, 384),
      MapVertex(128, 384),
    ],
    linedefs: <Linedef>[
      const Linedef(
        v1: 0,
        v2: 1,
        flags: LinedefFlags.twoSided,
        special: LineSpecial.switchDonutOnce,
        tag: 7,
        rightSidedef: 0,
        leftSidedef: 1,
      ),
      const Linedef(
        v1: 2,
        v2: 3,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 2,
        leftSidedef: 3,
      ),
      const Linedef(
        v1: 4,
        v2: 5,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 3,
        leftSidedef: 4,
      ),
    ],
    sidedefs: <Sidedef>[
      const Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: 'SW1COMP',
        lowerTexture: '-',
        middleTexture: '-',
        sector: 0,
      ),
      const Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: '-',
        lowerTexture: '-',
        middleTexture: '-',
        sector: 1,
      ),
      Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: '-',
        lowerTexture: '-',
        middleTexture: '-',
        sector: hole,
      ),
      const Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: '-',
        lowerTexture: '-',
        middleTexture: '-',
        sector: 2,
      ),
      const Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: '-',
        lowerTexture: '-',
        middleTexture: '-',
        sector: 3,
      ),
    ],
    sectors: <Sector>[
      sector(0, 'SOURCE'),
      sector(0, 'PLAYER'),
      sector(-16, 'RING'),
      sector(0, 'OUTER'),
      for (var i = 4; i < hole; i++) sector(0, 'FILLER'),
      sector(32, 'HOLE', tag: hasTag ? 7 : 0),
    ],
    segs: const <Seg>[],
    subsectors: const <Subsector>[],
    nodes: const <BspNode>[],
    things: const <Thing>[
      Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
    ],
    blockmap: null,
    reject: null,
  );
}

double donutLookupMicros(GameState game) {
  for (var i = 0; i < 1000; i++) {
    game_state_internal.activateDonutForTesting(game, 0);
  }
  var iterations = 1024;
  while (true) {
    final Stopwatch watch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      game_state_internal.activateDonutForTesting(game, 0);
    }
    watch.stop();
    if (watch.elapsedMicroseconds >= 10000 || iterations >= 1048576) {
      return watch.elapsedMicroseconds / iterations;
    }
    iterations *= 2;
  }
}

void crossEast(GameState game) {
  for (var tic = 0; tic < 100 && game.player.x <= toFixed(128); tic++) {
    game.runTic(const TicCmd(forwardMove: 10));
  }
  expect(game.player.x, greaterThan(toFixed(128)));
}

void crossWest(GameState game) {
  game.runTic(const TicCmd(angleTurn: 0x8000));
  for (var tic = 0; tic < 100 && game.player.x >= toFixed(128); tic++) {
    game.runTic(const TicCmd(forwardMove: 10));
  }
  expect(game.player.x, lessThan(toFixed(128)));
}

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

    test('MAXMOVE plus split movement cannot tunnel through a thin wall', () {
      final GameState game = GameState.start(
        testMap(
          vertices: const <MapVertex>[MapVertex(64, 0), MapVertex(64, 128)],
          lines: const <Linedef>[
            Linedef(
              v1: 0,
              v2: 1,
              flags: LinedefFlags.blocking,
              special: 0,
              tag: 0,
              rightSidedef: 0,
              leftSidedef: kNoSidedef,
            ),
          ],
          things: const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
      );

      // Deliberately outside the input adapter's normal range: without the
      // momentum clamp both half-move endpoints land beyond the thin wall.
      game.runTic(const TicCmd(forwardMove: 4000));

      print(
        'thin-wall clamp: playerX='
        '${fixedToDouble(game.player.x).toStringAsFixed(6)} wallX=64',
      );
      expect(game.player.x, lessThanOrEqualTo(toFixed(48)));
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
      for (int i = 0; i < 60; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.z, toFixed(24));
    });

    test('a grounded player follows an inclusive 24 unit drop', () {
      final GameState game = GameState.start(
        testMap(
          sectors: twoSectors(backFloor: -24),
          sides: twoSides(),
          lines: <Linedef>[portal()],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 60; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, greaterThan(toFixed(128)));
      expect(game.player.z, toFixed(-24));
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
      for (int i = 0; i < 60; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, lessThan(toFixed(128)));
    });

    test('the player may descend a drop taller than 24 units', () {
      final List<Sector> sectors = twoSectors(backFloor: -25);
      final GameState game = GameState.start(
        testMap(
          sectors: sectors,
          sides: twoSides(),
          lines: <Linedef>[portal()],
        ),
        const GameConfig(monsters: false),
      );
      for (int i = 0; i < 60; i++) {
        game.runTic(const TicCmd(forwardMove: 8));
      }
      expect(game.player.x, greaterThan(toFixed(128)));
      expect(game.player.z, toFixed(-25));
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
        for (int i = 0; i < 60; i++) {
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
    test('public capability catalog shares dispatcher and actor truth', () {
      expect(
        game_state_internal.linedefDispatcherCoverageIssuesForTesting(),
        isEmpty,
      );
      expect(
        DoomCoreCatalog.supportedLinedefSpecials,
        containsAll(<int>[
          LineSpecial.walkDoorOpenStayOnce,
          LineSpecial.walkFloorLowerToHighestOnce,
          LineSpecial.walkBuildStairs8Once,
          LineSpecial.walkFastCrusherOnce,
          LineSpecial.walkCrusherStopRepeat,
          LineSpecial.switchFloorRaiseToNextHigherAndChangeOnce,
          LineSpecial.walkFloorLowerToLowestAndChangeOnce,
          LineSpecial.switchDonutOnce,
        ]),
      );
      expect(
        DoomCoreCatalog.supportedSectorSpecials,
        contains(SectorSpecial.secret),
      );
      expect(DoomCoreCatalog.infoForEdNum(3001)?.isMonster, isTrue);
      expect(DoomCoreCatalog.infoForEdNum(5)?.spriteName, 'BKEY');
      expect(DoomCoreCatalog.keyForEdNum(5), Key.blue);
      expect(
        DoomCoreCatalog.requiredKeyForLineSpecial(
          LineSpecial.blueDoorOpenWaitClose,
        ),
        Key.blue,
      );
      expect(DoomCoreCatalog.soundIds, contains('DSWPNUP'));
      expect(
        DoomCoreCatalog.soundIds.every((String id) => id.startsWith('DS')),
        isTrue,
      );
    });

    test('walk doors implement W1/WR modes and obstruction safety', () {
      GameState door(int special, {List<Thing> extras = const <Thing>[]}) {
        final bool startsOpen = <int>{
          LineSpecial.walkDoorCloseOnce,
          LineSpecial.walkDoorCloseWaitOpenOnce,
          LineSpecial.walkDoorCloseRepeat,
        }.contains(special);
        return GameState.start(
          taggedSpecialMap(
            special: special,
            targetCeiling: startsOpen ? 128 : 32,
            extraThings: extras,
          ),
          const GameConfig(monsters: false),
        );
      }

      final GameState openStay = door(LineSpecial.walkDoorOpenStayOnce);
      crossEast(openStay);
      for (var i = 0; i < 30; i++) {
        openStay.runTic(TicCmd.empty);
      }
      expect(openStay.sectors.elementAt(2).ceilingHeight, toFixed(124));
      crossWest(openStay);
      expect(openStay.sectors.elementAt(2).hasMover, isFalse);

      final GameState close = door(LineSpecial.walkDoorCloseOnce);
      crossEast(close);
      for (var i = 0; i < 40; i++) {
        close.runTic(TicCmd.empty);
      }
      expect(close.sectors.elementAt(2).ceilingHeight, toFixed(0));

      final GameState raise = door(LineSpecial.walkDoorOpenWaitCloseOnce);
      crossEast(raise);
      for (var i = 0; i < 30; i++) {
        raise.runTic(TicCmd.empty);
      }
      expect(raise.sectors.elementAt(2).ceilingHeight, toFixed(124));
      for (var i = 0; i < 200; i++) {
        raise.runTic(TicCmd.empty);
      }
      expect(raise.sectors.elementAt(2).ceilingHeight, toFixed(0));

      final GameState closeWaitOpen = door(
        LineSpecial.walkDoorCloseWaitOpenOnce,
      );
      crossEast(closeWaitOpen);
      for (var i = 0; i < 40; i++) {
        closeWaitOpen.runTic(TicCmd.empty);
      }
      expect(closeWaitOpen.sectors.elementAt(2).ceilingHeight, toFixed(0));
      for (var i = 0; i < 1100; i++) {
        closeWaitOpen.runTic(TicCmd.empty);
      }
      expect(closeWaitOpen.sectors.elementAt(2).ceilingHeight, toFixed(128));

      final GameState blockedClose = door(
        LineSpecial.walkDoorCloseOnce,
        extras: const <Thing>[
          Thing(x: 64, y: 300, angle: 0, type: 2035, flags: _allSkills),
        ],
      );
      crossEast(blockedClose);
      for (var i = 0; i < 40; i++) {
        blockedClose.runTic(TicCmd.empty);
      }
      expect(
        blockedClose.sectors.elementAt(2).ceilingHeight,
        greaterThan(toFixed(42)),
      );
      expect(
        blockedClose.mobjs
            .firstWhere((MobjView m) => m.sprite == 'BAR1')
            .health,
        20,
      );

      for (final int special in <int>[
        LineSpecial.walkDoorCloseRepeat,
        LineSpecial.walkDoorOpenStayRepeat,
        LineSpecial.walkDoorOpenWaitCloseRepeat,
      ]) {
        final GameState repeat = door(special);
        crossEast(repeat);
        for (var i = 0; i < 230; i++) {
          repeat.runTic(TicCmd.empty);
        }
        crossWest(repeat);
        expect(
          repeat.sectors.elementAt(2).hasMover,
          isTrue,
          reason: '$special',
        );
      }
    });

    test('crusher specials activate with distinct normal and fast speeds', () {
      for (final (int special, int speed, bool use) in <(int, int, bool)>[
        (LineSpecial.walkFastCrusherOnce, 2, false),
        (LineSpecial.walkCrusherOnce, 1, false),
        (LineSpecial.switchCrusherOnce, 1, true),
        (LineSpecial.walkCrusherRepeat, 1, false),
        (LineSpecial.walkFastCrusherRepeat, 2, false),
      ]) {
        final GameState game = GameState.start(
          taggedSpecialMap(special: special, switchTexture: use),
          const GameConfig(monsters: false),
        );
        if (use) {
          game.runTic(const TicCmd(buttons: Buttons.use));
        } else {
          crossEast(game);
        }
        final sector = game.sectors.elementAt(2);
        expect(sector.hasMover, isTrue, reason: '$special activation');
        final int before = sector.ceilingHeight;
        game.runTic(TicCmd.empty);
        expect(
          before - sector.ceilingHeight,
          toFixed(speed),
          reason: '$special downward speed',
        );
        var sawBottom = false;
        for (var tic = 0; tic < 300; tic++) {
          game.runTic(TicCmd.empty);
          if (sector.ceilingHeight == toFixed(8)) sawBottom = true;
        }
        expect(sawBottom, isTrue, reason: '$special floor+8 target');
        expect(sector.hasMover, isTrue, reason: 'crusher cycles forever');
      }
    });

    test(
      'normal crusher slows to one eighth on contact while fast does not',
      () {
        GameState game(int special) => GameState.start(
          taggedSpecialMap(
            special: special,
            extraThings: const <Thing>[
              Thing(x: 64, y: 300, angle: 0, type: 3004, flags: _allSkills),
            ],
          ),
          const GameConfig(monsters: false),
        );

        final GameState normal = game(LineSpecial.walkCrusherOnce);
        final GameState fast = game(LineSpecial.walkFastCrusherOnce);
        crossEast(normal);
        crossEast(fast);
        while (normal.sectors.elementAt(2).ceilingHeight > toFixed(56)) {
          normal.runTic(TicCmd.empty);
        }
        while (fast.sectors.elementAt(2).ceilingHeight > toFixed(56)) {
          fast.runTic(TicCmd.empty);
        }
        normal.runTic(TicCmd.empty);
        fast.runTic(TicCmd.empty);
        final int normalBefore = normal.sectors.elementAt(2).ceilingHeight;
        final int fastBefore = fast.sectors.elementAt(2).ceilingHeight;
        normal.runTic(TicCmd.empty);
        fast.runTic(TicCmd.empty);
        expect(
          normalBefore - normal.sectors.elementAt(2).ceilingHeight,
          kFracUnit ~/ 8,
        );
        expect(
          fastBefore - fast.sectors.elementAt(2).ceilingHeight,
          toFixed(2),
        );
      },
    );

    test('crusher damages every four tics and gibs the crushed monster', () {
      final GameState game = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkCrusherOnce,
          extraThings: const <Thing>[
            Thing(x: 64, y: 300, angle: 0, type: 3004, flags: _allSkills),
          ],
        ),
        const GameConfig(monsters: false),
      );
      crossEast(game);
      MobjView monster() =>
          game.mobjs.firstWhere((MobjView m) => m.sprite == 'POSS');
      while (game.sectors.elementAt(2).ceilingHeight > toFixed(56)) {
        game.runTic(TicCmd.empty);
      }
      final List<int> damagedAt = <int>[];
      var previous = monster().health;
      for (var tic = 0; tic < 40 && monster().health > 0; tic++) {
        game.runTic(TicCmd.empty);
        final int health = monster().health;
        if (health != previous) {
          expect(previous - health, 10, reason: 'crusher damage portion');
          damagedAt.add(game.tic);
        }
        previous = health;
      }
      expect(damagedAt.length, greaterThanOrEqualTo(2));
      for (var i = 1; i < damagedAt.length; i++) {
        expect(damagedAt[i] - damagedAt[i - 1], 4);
      }
      for (var tic = 0; tic < 500 && monster().height != 0; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(monster().health, 0);
      expect(monster().height, 0, reason: 'corpse becomes gib puddle');
      expect(monster().flags & MobjFlags.solid, 0);
    });

    test('crusher deals ten damage per portion to the player', () {
      final MapData base = taggedSpecialMap(special: 0);
      final List<Linedef> lines = List<Linedef>.of(base.linedefs);
      final Linedef trigger = lines[1];
      lines[1] = Linedef(
        v1: trigger.v1,
        v2: trigger.v2,
        flags: trigger.flags,
        special: LineSpecial.switchCrusherOnce,
        tag: 7,
        rightSidedef: trigger.rightSidedef,
        leftSidedef: trigger.leftSidedef,
      );
      final GameState game = GameState.start(
        MapData(
          name: base.name,
          vertices: base.vertices,
          linedefs: lines,
          sidedefs: base.sidedefs,
          sectors: base.sectors,
          segs: base.segs,
          subsectors: base.subsectors,
          nodes: base.nodes,
          things: const <Thing>[
            Thing(x: 64, y: 300, angle: 90, type: 1, flags: _allSkills),
          ],
          blockmap: null,
          reject: null,
        ),
        const GameConfig(monsters: false),
      );
      expect(game.playerSectorIndex, 2);
      game.runTic(const TicCmd(buttons: Buttons.use));
      expect(game.sectors.elementAt(2).hasMover, isTrue);
      final int before = game.player.health;
      for (var tic = 0; tic < 200 && game.player.health == before; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(before - game.player.health, 10);
    });

    test('crusher stop 57/74 enters stasis without becoming a door', () {
      for (final int stopSpecial in <int>[
        LineSpecial.walkCrusherStopOnce,
        LineSpecial.walkCrusherStopRepeat,
      ]) {
        final GameState game = GameState.start(
          crusherStopMap(stopSpecial),
          const GameConfig(monsters: false),
        );
        crossEast(game);
        final sector = game.sectors.elementAt(2);
        final int moving = sector.ceilingHeight;
        game.runTic(TicCmd.empty);
        expect(sector.ceilingHeight, lessThan(moving));
        while (game.player.x <= toFixed(160)) {
          game.runTic(const TicCmd(forwardMove: 10));
        }
        final int stopped = sector.ceilingHeight;
        for (var tic = 0; tic < 20; tic++) {
          game.runTic(TicCmd.empty);
        }
        expect(sector.ceilingHeight, stopped, reason: '$stopSpecial stasis');
        expect(sector.hasMover, isTrue, reason: 'stopped thinker retained');
        game.runTic(const TicCmd(angleTurn: 0x8000));
        while (game.player.x >= toFixed(128)) {
          game.runTic(const TicCmd(forwardMove: 10));
        }
        final int restarted = sector.ceilingHeight;
        game.runTic(TicCmd.empty);
        expect(
          sector.ceilingHeight,
          isNot(restarted),
          reason: 'repeat crusher trigger restarts $stopSpecial stasis',
        );
      }
    });

    test('door waits use vanilla tick counts at top and bottom', () {
      final GameState top = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkDoorOpenWaitCloseOnce,
          targetCeiling: 32,
        ),
        const GameConfig(monsters: false),
      );
      crossEast(top);
      while (top.sectors.elementAt(2).ceilingHeight < toFixed(124)) {
        top.runTic(TicCmd.empty);
      }
      for (var i = 0; i < 149; i++) {
        top.runTic(TicCmd.empty);
      }
      expect(top.sectors.elementAt(2).ceilingHeight, toFixed(124));
      top.runTic(TicCmd.empty);
      expect(top.sectors.elementAt(2).ceilingHeight, toFixed(120));

      final GameState bottom = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkDoorCloseWaitOpenOnce,
          targetCeiling: 128,
        ),
        const GameConfig(monsters: false),
      );
      crossEast(bottom);
      while (bottom.sectors.elementAt(2).ceilingHeight > 0) {
        bottom.runTic(TicCmd.empty);
      }
      for (var i = 0; i < 1050; i++) {
        bottom.runTic(TicCmd.empty);
      }
      expect(bottom.sectors.elementAt(2).ceilingHeight, toFixed(0));
      bottom.runTic(TicCmd.empty);
      expect(bottom.sectors.elementAt(2).ceilingHeight, toFixed(4));
    });

    test('monsters cross-trigger only the vanilla 4, 10, and 88 subset', () {
      for (final (int special, bool expected) in <(int, bool)>[
        (LineSpecial.walkDoorOpenWaitCloseOnce, true),
        (LineSpecial.liftDownWaitUp, true),
        (LineSpecial.liftDownWaitUpFast, true),
        (LineSpecial.walkDoorOpenStayOnce, false),
      ]) {
        final MapData base = taggedSpecialMap(
          special: special,
          targetFloor: 32,
          targetCeiling: special == LineSpecial.walkDoorOpenWaitCloseOnce
              ? 32
              : 128,
        );
        final GameState game = GameState.start(
          withThings(base, const <Thing>[
            Thing(x: 192, y: 64, angle: 180, type: 1, flags: _allSkills),
            Thing(x: 64, y: 64, angle: 0, type: 3004, flags: _allSkills),
          ]),
          const GameConfig(),
          seed: 2,
        );
        for (
          var tic = 0;
          tic < 200 && !game.sectors.elementAt(2).hasMover;
          tic++
        ) {
          game.runTic(TicCmd.empty);
        }
        expect(
          game.sectors.elementAt(2).hasMover,
          expected,
          reason:
              'monster did not activate walk special $special: '
              '${game.mobjs.map((MobjView m) => (m.sprite, fixedToInt(m.x), fixedToInt(m.y))).toList()}',
        );
      }
    });

    test(
      'walk and switch floors use distinct vanilla height queries',
      () async {
        Future<void> reaches(
          int special,
          int expected, {
          int start = 64,
          List<int> floors = const <int>[16, 96],
          List<int> ceilings = const <int>[100, 120],
          bool use = false,
        }) async {
          final GameState game = GameState.start(
            taggedSpecialMap(
              special: special,
              targetFloor: start,
              neighborFloors: floors,
              neighborCeilings: ceilings,
              switchTexture: use,
            ),
            const GameConfig(monsters: false),
          );
          if (use) {
            game.runTic(const TicCmd(buttons: Buttons.use));
          } else {
            crossEast(game);
          }
          for (var i = 0; i < 400; i++) {
            game.runTic(TicCmd.empty);
          }
          expect(
            game.sectors.elementAt(2).floorHeight,
            toFixed(expected),
            reason: '$special',
          );
        }

        await reaches(LineSpecial.walkFloorLowerToHighestOnce, 96, start: 128);
        await reaches(LineSpecial.walkFloorLowerTurboOnce, 104, start: 128);
        await reaches(LineSpecial.walkFloorLowerToLowestOnce, 16);
        await reaches(LineSpecial.walkFloorLowerToLowestRepeat, 16);
        await reaches(LineSpecial.walkFloorRaise24Once, 88);
        await reaches(LineSpecial.walkFloorRaiseToLowestCeilingRepeat, 100);
        await reaches(
          LineSpecial.walkFloorRaiseToNextHigherOnce,
          80,
          floors: const <int>[80, 112],
        );
        await reaches(
          LineSpecial.walkFloorRaiseToNextHigherRepeat,
          80,
          floors: const <int>[80, 112],
        );
        await reaches(
          LineSpecial.switchFloorRaiseToNextHigherOnce,
          80,
          use: true,
          floors: const <int>[80, 112],
        );
        await reaches(LineSpecial.switchFloorLowerToLowestOnce, 16, use: true);
      },
    );

    test(
      '20/22 raise half-speed and transfer front flat with special zero',
      () {
        for (final (int special, bool use) in <(int, bool)>[
          (LineSpecial.switchFloorRaiseToNextHigherAndChangeOnce, true),
          (LineSpecial.walkFloorRaiseToNextHigherAndChangeOnce, false),
        ]) {
          final GameState game = GameState.start(
            taggedSpecialMap(
              special: special,
              targetFloor: 0,
              neighborFloors: const <int>[24, 48],
              switchTexture: use,
              sourceFloorFlat: 'MODEL',
              sourceSpecial: SectorSpecial.damage10,
              targetFloorFlat: 'OLD',
              targetSpecial: SectorSpecial.damage5,
            ),
            const GameConfig(monsters: false),
          );
          if (use) {
            game.runTic(const TicCmd(buttons: Buttons.use));
          } else {
            crossEast(game);
          }
          final sector = game.sectors.elementAt(2);
          expect(sector.floorFlat, 'MODEL', reason: '$special source flat');
          expect(sector.special, 0, reason: '$special clears damage special');
          expect(
            game.changeJournal
                .where((SectorChange c) => c.kind == PlaneKind.floorFlat)
                .single
                .flatName,
            'MODEL',
          );
          final int before = sector.floorHeight;
          game.runTic(TicCmd.empty);
          expect(sector.floorHeight - before, kFracUnit ~/ 2);
          for (var tic = 0; tic < 100; tic++) {
            game.runTic(TicCmd.empty);
          }
          expect(sector.floorHeight, toFixed(24));
        }
      },
    );

    test(
      '37 transfers lowest-neighbor flat and special only at destination',
      () {
        final GameState game = GameState.start(
          taggedSpecialMap(
            special: LineSpecial.walkFloorLowerToLowestAndChangeOnce,
            targetFloor: 32,
            neighborFloors: const <int>[0, 16],
            targetFloorFlat: 'OLD',
            targetSpecial: SectorSpecial.damage10,
            neighborFloorFlats: const <String>['LOW', 'OTHER'],
            neighborSpecials: const <int>[
              SectorSpecial.damage5,
              SectorSpecial.glow,
            ],
          ),
          const GameConfig(monsters: false),
        );
        crossEast(game);
        final sector = game.sectors.elementAt(2);
        expect(sector.floorFlat, 'OLD');
        while (sector.floorHeight > 0) {
          game.runTic(TicCmd.empty);
        }
        expect(sector.floorFlat, 'LOW');
        expect(sector.special, SectorSpecial.damage5);
        expect(
          game.changeJournal
              .where((SectorChange c) => c.kind == PlaneKind.floorFlat)
              .single
              .flatName,
          'LOW',
        );
      },
    );

    test('59 raises 24 and transfers the front model immediately', () {
      final GameState game = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkFloorRaise24AndChangeOnce,
          targetFloor: 8,
          sourceFloorFlat: 'MODEL59',
          sourceSpecial: SectorSpecial.glow,
          targetFloorFlat: 'OLD59',
        ),
        const GameConfig(monsters: false),
      );
      crossEast(game);
      final sector = game.sectors.elementAt(2);
      expect((sector.floorFlat, sector.special), ('MODEL59', 8));
      for (var tic = 0; tic < 40; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(sector.floorHeight, toFixed(32));
      expect(
        game.changeJournal
            .where((SectorChange c) => c.kind == PlaneKind.floorFlat)
            .single
            .flatName,
        'MODEL59',
      );
    });

    test('donut lowers hole, raises ring, and transfers outer flat', () {
      final GameState game = GameState.start(
        donutMap(),
        const GameConfig(monsters: false),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      expect(game.switchJournal.single.textureName, 'SW2COMP');
      final hole = game.sectors.elementAt(2);
      final ring = game.sectors.elementAt(3);
      expect(hole.floorHeight, toFixed(32));
      expect(ring.floorHeight, toFixed(-16));
      game.runTic(TicCmd.empty);
      expect(hole.floorHeight, toFixed(32) - kFracUnit ~/ 2);
      expect(ring.floorHeight, toFixed(-16) + kFracUnit ~/ 2);
      for (var tic = 0; tic < 100; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(hole.floorHeight, 0);
      expect(ring.floorHeight, 0);
      expect((ring.floorFlat, ring.special), ('OUTER', 0));
      expect(
        game.changeJournal
            .where((SectorChange c) => c.kind == PlaneKind.floorFlat)
            .single
            .flatName,
        'OUTER',
      );
    });

    test('hostile donut topology stops at budget and remains fast', () {
      final Stopwatch watch = Stopwatch()..start();
      final GameState game = GameState.start(
        donutMap(extraTaggedSectors: 4000),
        const GameConfig(monsters: false, maxDonutBuildVisits: 2),
      );
      game.runTic(const TicCmd(buttons: Buttons.use));
      watch.stop();
      expect(game.sectors.elementAt(2).hasMover, isFalse);
      expect(watch.elapsedMilliseconds, lessThan(500));
      expect(
        game.hashState(),
        isNot(
          GameState.start(
            donutMap(extraTaggedSectors: 4000),
            const GameConfig(monsters: false, maxDonutBuildVisits: 3),
          ).hashState(),
        ),
      );
    });

    test('donut lookup handles an absent tag and a last-sector tag', () {
      final GameState absent = GameState.start(
        donutLookupMap(16000, hasTag: false),
        const GameConfig(monsters: false, maxDonutBuildVisits: 2),
      );
      expect(game_state_internal.activateDonutForTesting(absent, 0), isFalse);

      final GameState last = GameState.start(
        donutLookupMap(16000, hasTag: true),
        const GameConfig(monsters: false, maxDonutBuildVisits: 3),
      );
      expect(game_state_internal.activateDonutForTesting(last, 0), isTrue);
      expect(last.sectors.elementAt(15999).hasMover, isTrue);
    });

    test('absent donut tag lookup cost stays flat as the map grows', () {
      const List<int> sizes = <int>[100, 1000, 4000, 16000];
      final Map<int, GameState> games = <int, GameState>{
        for (final int sectors in sizes)
          sectors: GameState.start(
            donutLookupMap(sectors, hasTag: false),
            const GameConfig(monsters: false, maxDonutBuildVisits: 2),
          ),
      };
      final Map<int, List<double>> samples = <int, List<double>>{
        for (final int sectors in sizes) sectors: <double>[],
      };
      for (var sample = 0; sample < 5; sample++) {
        final Iterable<int> order = sample.isEven ? sizes : sizes.reversed;
        for (final int sectors in order) {
          samples[sectors]!.add(donutLookupMicros(games[sectors]!));
        }
      }
      final Map<int, double> medians = <int, double>{
        for (final int sectors in sizes)
          sectors: (samples[sectors]!..sort())[2],
      };
      final double ratio = medians[16000]! / medians[100]!;
      // Kept in the test output because this is a performance regression
      // contract, and the absolute samples help diagnose a noisy host.
      print(
        'donut absent-tag us/activation: '
        '${sizes.map((int sectors) {
          return '$sectors=${medians[sectors]!.toStringAsFixed(3)}';
        }).join(', ')}; ratio=${ratio.toStringAsFixed(3)}',
      );
      expect(
        ratio,
        lessThan(1.5),
        reason:
            'median lookup ratio must remain close to one, got $ratio '
            '(${medians[100]} vs ${medians[16000]} us/activation)',
      );
    });

    test('mutable floor model is hashed while its journal is output-only', () {
      final MapData map = taggedSpecialMap(
        special: LineSpecial.walkFloorRaise24AndChangeOnce,
        sourceFloorFlat: 'HASHMODEL',
        sourceSpecial: SectorSpecial.glow,
        targetFloorFlat: 'HASHOLD',
      );
      final GameState a = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      final GameState b = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      crossEast(a);
      crossEast(b);
      expect(a.hashState(), b.hashState());
      final int beforeConsume = a.hashState();
      expect(a.consumeChangeJournal(), isNotEmpty);
      expect(a.hashState(), beforeConsume);
      expect(a.sectors.elementAt(2).floorFlat, 'HASHMODEL');
    });

    test('all use specials reject the directed line back side', () {
      final GameState front = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.switchFloorRaiseToNextHigherOnce,
          targetFloor: 64,
          neighborFloors: const <int>[80, 112],
          switchTexture: true,
        ),
        const GameConfig(monsters: false),
      );
      front.runTic(const TicCmd(buttons: Buttons.use));
      expect(front.sectors.elementAt(2).hasMover, isTrue);

      final GameState back = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.switchFloorRaiseToNextHigherOnce,
          targetFloor: 64,
          neighborFloors: const <int>[80, 112],
          switchTexture: true,
          playerX: 160,
          playerAngle: 180,
        ),
        const GameConfig(monsters: false),
      );
      back.runTic(const TicCmd(buttons: Buttons.use));
      expect(back.sectors.elementAt(2).hasMover, isFalse);
      expect(back.switchJournal, isEmpty);
    });

    test('W1 floor is consumed while WR floor retriggers', () {
      final GameState once = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkFloorRaise24Once,
          targetFloor: 0,
        ),
        const GameConfig(monsters: false),
      );
      crossEast(once);
      for (var i = 0; i < 30; i++) {
        once.runTic(TicCmd.empty);
      }
      crossWest(once);
      for (var i = 0; i < 30; i++) {
        once.runTic(TicCmd.empty);
      }
      expect(once.sectors.elementAt(2).floorHeight, toFixed(24));

      final GameState repeat = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkFloorRaiseToNextHigherRepeat,
          targetFloor: 0,
          neighborFloors: const <int>[24, 48],
        ),
        const GameConfig(monsters: false),
      );
      crossEast(repeat);
      for (var i = 0; i < 30; i++) {
        repeat.runTic(TicCmd.empty);
      }
      crossWest(repeat);
      for (var i = 0; i < 30; i++) {
        repeat.runTic(TicCmd.empty);
      }
      expect(repeat.sectors.elementAt(2).floorHeight, toFixed(48));
    });

    test('future mover phase, speed, and stair budget are hashed', () {
      final GameState stairsOne = GameState.start(
        stairMap(LineSpecial.walkBuildStairs8Once),
        const GameConfig(monsters: false, maxStairBuildVisits: 1),
      );
      final GameState stairsTwo = GameState.start(
        stairMap(LineSpecial.walkBuildStairs8Once),
        const GameConfig(monsters: false, maxStairBuildVisits: 2),
      );
      expect(stairsOne.hashState(), isNot(stairsTwo.hashState()));

      final GameState slow = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkFloorLowerToHighestOnce,
          targetFloor: 128,
          neighborFloors: const <int>[16, 96],
        ),
        const GameConfig(monsters: false),
      );
      final GameState turbo = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkFloorLowerTurboOnce,
          targetFloor: 128,
          neighborFloors: const <int>[16, 88],
        ),
        const GameConfig(monsters: false),
      );
      crossEast(slow);
      crossEast(turbo);
      // Both target 96, but the mover speed changes their future.
      expect(slow.hashState(), isNot(turbo.hashState()));

      final GameState closing = GameState.start(
        taggedSpecialMap(
          special: LineSpecial.walkDoorCloseWaitOpenOnce,
          targetCeiling: 128,
        ),
        const GameConfig(monsters: false),
      );
      crossEast(closing);
      for (var i = 0; i < 40; i++) {
        closing.runTic(TicCmd.empty);
      }
      final int waitingHash = closing.hashState();
      closing.runTic(TicCmd.empty);
      expect(closing.hashState(), isNot(waitingHash));
    });

    test('stairs follow directed same-flat chain and obey visit budget', () {
      final GameState full = GameState.start(
        stairMap(LineSpecial.walkBuildStairs8Once),
        const GameConfig(monsters: false, maxStairBuildVisits: 3),
      );
      crossEast(full);
      for (var i = 0; i < 110; i++) {
        full.runTic(TicCmd.empty);
      }
      expect(full.sectors.elementAt(2).floorHeight, toFixed(8));
      expect(full.sectors.elementAt(3).floorHeight, toFixed(16));
      expect(full.sectors.elementAt(5).floorHeight, toFixed(24));

      final GameState bounded = GameState.start(
        stairMap(LineSpecial.switchBuildStairs8Once),
        const GameConfig(monsters: false, maxStairBuildVisits: 2),
      );
      bounded.runTic(const TicCmd(buttons: Buttons.use));
      for (var i = 0; i < 110; i++) {
        bounded.runTic(TicCmd.empty);
      }
      expect(bounded.sectors.elementAt(2).floorHeight, toFixed(8));
      expect(bounded.sectors.elementAt(3).floorHeight, toFixed(16));
      expect(bounded.sectors.elementAt(5).floorHeight, toFixed(0));
    });

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

    for (final int special in <int>[103, 61, 63]) {
      test('switch door $special preserves its open/close behavior', () {
        final MapData map = taggedSpecialMap(
          special: special,
          targetFloor: 64,
          targetCeiling: 64,
          neighborCeilings: <int>[176, 208],
          switchTexture: true,
        );
        final List<TicCmd> commands = <TicCmd>[
          const TicCmd(buttons: Buttons.use),
          ...List<TicCmd>.filled(500, TicCmd.empty),
        ];
        int replay() {
          final GameState game = GameState.start(
            map,
            const GameConfig(monsters: false),
          );
          for (final TicCmd command in commands.take(70)) {
            game.runTic(command);
          }
          expect(game.sectors.elementAt(2).ceilingHeight, toFixed(172));
          for (final TicCmd command in commands.skip(70)) {
            game.runTic(command);
          }
          expect(
            game.sectors.elementAt(2).ceilingHeight,
            toFixed(special == 63 ? 64 : 172),
            reason: '103 is S1 open-stay, 61 is SR open-stay, 63 is SR raise',
          );
          return game.hashState();
        }

        expect(replay(), replay());
      });
    }

    test(
      'S1 switch stays pressed and its future-affecting state is hashed',
      () {
        final MapData map = testMap(
          sectors: twoSectors(backCeiling: 32),
          sides: switchSides(),
          lines: <Linedef>[portal(special: LineSpecial.switchDoorOpenStayOnce)],
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
      expect(game.sectors.elementAt(1).ceilingHeight, toFixed(0));
    });

    test(
      'use ray chooses the first paired door face, not nearest midpoint',
      () {
        final GameState game = GameState.start(
          testMap(
            vertices: const <MapVertex>[
              MapVertex(100, 400),
              MapVertex(100, 0),
              MapVertex(120, 0),
              MapVertex(120, 128),
            ],
            sectors: const <Sector>[
              Sector(
                floorHeight: 0,
                ceilingHeight: 128,
                floorFlat: 'F',
                ceilingFlat: 'C',
                lightLevel: 160,
                special: 0,
                tag: 0,
              ),
              Sector(
                floorHeight: 0,
                ceilingHeight: 0,
                floorFlat: 'F',
                ceilingFlat: 'C',
                lightLevel: 160,
                special: 0,
                tag: 0,
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
            sides: const <Sidedef>[
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
              Sidedef(
                xOffset: 0,
                yOffset: 0,
                upperTexture: '-',
                lowerTexture: '-',
                middleTexture: '-',
                sector: 2,
              ),
            ],
            lines: const <Linedef>[
              Linedef(
                v1: 0,
                v2: 1,
                flags: LinedefFlags.twoSided,
                special: LineSpecial.doorOpenWaitClose,
                tag: 0,
                rightSidedef: 0,
                leftSidedef: 1,
              ),
              Linedef(
                v1: 2,
                v2: 3,
                flags: LinedefFlags.twoSided,
                special: LineSpecial.doorOpenWaitClose,
                tag: 0,
                rightSidedef: 2,
                leftSidedef: 1,
              ),
            ],
            things: const <Thing>[
              Thing(x: 64, y: 64, angle: 0, type: 1, flags: _allSkills),
            ],
          ),
          const GameConfig(monsters: false),
        );

        game.runTic(const TicCmd(buttons: Buttons.use));

        expect(game.sectors.elementAt(1).hasMover, isTrue);
        expect(
          game.consumeSoundJournal().map((event) => event.soundId),
          contains('DSDOROPN'),
        );
      },
    );

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
      expect(game.sectors.elementAt(1).ceilingHeight, toFixed(0));
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
        for (int i = 0; i < 60; i++) {
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
        for (int i = 0; i < 60; i++) {
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
        for (int i = 0; i < 60; i++) {
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
      for (int i = 0; i < 60; i++) {
        game.runTic(const TicCmd(forwardMove: 10));
      }
      expect(game.levelComplete, isTrue);
      expect(game.secretsFound, 1);
    });
  });
}
