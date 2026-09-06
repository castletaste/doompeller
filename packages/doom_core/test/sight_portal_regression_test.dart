import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

const Sidedef _side0 = Sidedef(
  xOffset: 0,
  yOffset: 0,
  upperTexture: '-',
  lowerTexture: '-',
  middleTexture: '-',
  sector: 0,
);
const Sidedef _side1 = Sidedef(
  xOffset: 0,
  yOffset: 0,
  upperTexture: '-',
  lowerTexture: '-',
  middleTexture: '-',
  sector: 1,
);
const Sidedef _side2 = Sidedef(
  xOffset: 0,
  yOffset: 0,
  upperTexture: '-',
  lowerTexture: '-',
  middleTexture: '-',
  sector: 2,
);

Sector _sector(int floor, int ceiling) => Sector(
  floorHeight: floor,
  ceilingHeight: ceiling,
  floorFlat: 'F',
  ceilingFlat: 'C',
  lightLevel: 160,
  special: 0,
  tag: 0,
);

MapData _map({
  required List<MapVertex> vertices,
  required List<Linedef> lines,
  required List<Sidedef> sides,
  required List<Sector> sectors,
  required List<Thing> things,
}) => MapData(
  name: 'SIGHT',
  vertices: vertices,
  linedefs: lines,
  sidedefs: sides,
  sectors: sectors,
  segs: const <Seg>[],
  subsectors: const <Subsector>[],
  nodes: const <BspNode>[],
  things: things,
  blockmap: null,
  reject: null,
);

MapData _singleDivider({
  required int flags,
  int backFloor = 0,
  int backCeiling = 128,
  bool farWall = false,
  bool monster = true,
}) {
  final vertices = <MapVertex>[
    const MapVertex(128, 128),
    const MapVertex(128, 0),
    if (farWall) ...const <MapVertex>[MapVertex(256, 128), MapVertex(256, 0)],
  ];
  final lines = <Linedef>[
    Linedef(
      v1: 0,
      v2: 1,
      flags: flags,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: (flags & LinedefFlags.twoSided) != 0 ? 1 : kNoSidedef,
    ),
    if (farWall)
      const Linedef(
        v1: 2,
        v2: 3,
        flags: LinedefFlags.blocking,
        special: 0,
        tag: 0,
        rightSidedef: 1,
        leftSidedef: kNoSidedef,
      ),
  ];
  return _map(
    vertices: vertices,
    lines: lines,
    sides: const <Sidedef>[_side0, _side1],
    sectors: <Sector>[_sector(0, 128), _sector(backFloor, backCeiling)],
    things: <Thing>[
      const Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
      if (monster)
        const Thing(x: 224, y: 64, angle: 180, type: 3004, flags: _skills),
    ],
  );
}

MobjView _zombie(GameState game) =>
    game.mobjs.singleWhere((MobjView actor) => actor.sprite == 'POSS');

void main() {
  test(
    'open two-sided ML_BLOCKING rail blocks movement but permits sight and fire',
    () {
      final game = GameState.start(
        _singleDivider(flags: LinedefFlags.twoSided | LinedefFlags.blocking),
        const GameConfig(),
        seed: 0,
      );
      final monsterStartX = _zombie(game).x;

      for (var tic = 0; tic < 500 && game.player.health == 100; tic++) {
        game.runTic(const TicCmd(forwardMove: 50));
      }

      expect(game.player.x, lessThan(toFixed(110)));
      expect(_zombie(game).x, lessThan(monsterStartX));
      expect(game.player.health, lessThan(100));
    },
  );

  test('player wall puff passes an open ML_BLOCKING rail', () {
    final game = GameState.start(
      _singleDivider(
        flags: LinedefFlags.twoSided | LinedefFlags.blocking,
        farWall: true,
        monster: false,
      ),
      const GameConfig(monsters: false),
      seed: 0,
    );

    for (var tic = 0; tic < 5; tic++) {
      game.runTic(const TicCmd(buttons: Buttons.attack));
    }

    final puff = game.mobjs.singleWhere(
      (MobjView actor) => actor.sprite == 'PUFF',
    );
    expect(fixedToInt(puff.x), greaterThan(200));
  });

  test('a low portal can expose the lower part of a target', () {
    final game = GameState.start(
      _singleDivider(flags: LinedefFlags.twoSided, backCeiling: 32),
      const GameConfig(monsters: false),
      seed: 3,
    );
    final healthBefore = _zombie(game).health;

    for (var tic = 0; tic < 5; tic++) {
      game.runTic(const TicCmd(buttons: Buttons.attack));
    }

    expect(_zombie(game).health, lessThan(healthBefore));
  });

  test('one-sided and vertically closed dividers stay opaque', () {
    for (final map in <MapData>[
      _singleDivider(flags: LinedefFlags.blocking),
      _singleDivider(
        flags: LinedefFlags.twoSided,
        backFloor: 128,
        backCeiling: 128,
      ),
    ]) {
      final game = GameState.start(map, const GameConfig(), seed: 0);
      final monsterStartX = _zombie(game).x;
      for (var tic = 0; tic < 200; tic++) {
        game.runTic(TicCmd.empty);
      }
      expect(_zombie(game).x, monsterStartX);
      expect(game.player.health, 100);
    }
  });

  test(
    'successive incompatible vertical windows cumulatively occlude sight',
    () {
      final game = GameState.start(
        _map(
          vertices: const <MapVertex>[
            MapVertex(96, 128),
            MapVertex(96, 0),
            MapVertex(160, 176),
            MapVertex(160, 0),
          ],
          lines: const <Linedef>[
            Linedef(
              v1: 0,
              v2: 1,
              flags: LinedefFlags.twoSided,
              special: 0,
              tag: 0,
              rightSidedef: 0,
              leftSidedef: 1,
            ),
            Linedef(
              v1: 2,
              v2: 3,
              flags: LinedefFlags.twoSided,
              special: 0,
              tag: 0,
              rightSidedef: 1,
              leftSidedef: 2,
            ),
          ],
          sides: const <Sidedef>[_side0, _side1, _side2],
          sectors: <Sector>[_sector(0, 64), _sector(0, 128), _sector(112, 176)],
          things: const <Thing>[
            Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
            Thing(x: 224, y: 64, angle: 180, type: 3004, flags: _skills),
          ],
        ),
        const GameConfig(),
        seed: 0,
      );
      final monsterStartX = _zombie(game).x;

      for (var tic = 0; tic < 200; tic++) {
        game.runTic(TicCmd.empty);
      }

      expect(_zombie(game).x, monsterStartX);
      expect(game.player.health, 100);
    },
  );
}
