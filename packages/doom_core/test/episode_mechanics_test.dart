import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

MapData _teleporter() => MapData(
  name: 'TELEPORT',
  vertices: const <MapVertex>[
    MapVertex(128, 128),
    MapVertex(128, 0),
    MapVertex(256, 0),
    MapVertex(256, 128),
  ],
  linedefs: const <Linedef>[
    Linedef(
      v1: 0,
      v2: 1,
      flags: LinedefFlags.twoSided,
      special: LineSpecial.walkTeleportOnce,
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
  ],
  sidedefs: const <Sidedef>[
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
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 1,
    ),
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
      ceilingHeight: 128,
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
      tag: 7,
    ),
  ],
  segs: const <Seg>[],
  subsectors: const <Subsector>[],
  nodes: const <BspNode>[],
  things: const <Thing>[
    Thing(x: 64, y: 64, angle: 0, type: 1, flags: _skills),
    Thing(x: 344, y: 64, angle: 90, type: 14, flags: _skills),
  ],
  blockmap: null,
  reject: null,
);

void main() {
  test(
    'W1 teleport stops saturated movement and applies the 18-tic freeze',
    () {
      final GameState game = GameState.start(
        _teleporter(),
        const GameConfig(monsters: false),
      );
      for (var tic = 0; tic < 32 && game.player.x != toFixed(344); tic++) {
        game.runTic(const TicCmd(forwardMove: 50));
      }
      expect(game.player.x, toFixed(344));
      expect(game.player.y, toFixed(64));
      expect(game.player.angle, degreesToAngle(90));
      expect(
        game.mobjs.where((MobjView m) => m.sprite == 'TFOG'),
        hasLength(2),
      );
      for (var tic = 0; tic < 18; tic++) {
        game.runTic(const TicCmd(forwardMove: 50, angleTurn: 100));
      }
      expect(game.player.x, toFixed(344));
      game.runTic(const TicCmd(forwardMove: 50));
      expect(game.player.y, greaterThan(toFixed(64)));
    },
  );

  test(
    'episode catalog exposes teleport, progression, and Baron mechanics',
    () {
      expect(
        DoomCoreCatalog.supportedLinedefSpecials,
        containsAll(<int>{35, 39, 46, 63, 70, 76, 97, 98, 125, 126}),
      );
      final MobjInfo baron = DoomCoreCatalog.infoForEdNum(3003)!;
      expect(baron.spriteName, 'BOSS');
      expect(baron.spawnHealth, 1000);
      expect(DoomCoreCatalog.infoForEdNum(14)!.id, MobjType.teleportSpot);
      expect(DoomCoreCatalog.infoForEdNum(46)!.spriteName, 'TRED');
    },
  );
}
