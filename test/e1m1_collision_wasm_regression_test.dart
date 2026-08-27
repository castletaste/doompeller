import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
// ignore: implementation_imports
import 'package:doom_core/src/map_runtime.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('original E1M1 linedef 37 stays solid with Wasm-safe arithmetic', () {
    // Exact endpoints of one of the original E1M1 walls that the former
    // `(dot << 16)` projection missed. Keeping this tiny regression beside the
    // full-WAD content test makes it cheap enough to execute under dart2wasm.
    final MapData map = MapData(
      name: 'E1M1-LINE37',
      vertices: const <MapVertex>[
        MapVertex(1376, -3648),
        MapVertex(1376, -3360),
      ],
      linedefs: const <Linedef>[
        Linedef(
          v1: 0,
          v2: 1,
          flags: 0,
          special: 0,
          tag: 0,
          rightSidedef: 0,
          leftSidedef: kNoSidedef,
        ),
      ],
      sidedefs: const <Sidedef>[
        Sidedef(
          xOffset: 0,
          yOffset: 0,
          upperTexture: '-',
          lowerTexture: '-',
          middleTexture: 'STARTAN3',
          sector: 0,
        ),
      ],
      sectors: const <Sector>[
        Sector(
          floorHeight: 0,
          ceilingHeight: 128,
          floorFlat: 'FLOOR4_8',
          ceilingFlat: 'CEIL3_5',
          lightLevel: 160,
          special: 0,
          tag: 0,
        ),
      ],
      segs: const <Seg>[],
      subsectors: const <Subsector>[],
      nodes: const <BspNode>[],
      things: const <Thing>[
        Thing(
          x: 1400,
          y: -3504,
          angle: 180,
          type: 1,
          flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
        ),
      ],
      blockmap: null,
      reject: null,
    );
    final MapRuntime runtime = MapRuntime(map);
    expect(
      runtime.blocksAt(
        0,
        toFixed(1376),
        toFixed(-3504),
        toFixed(16),
        0,
        toFixed(56),
      ),
      isTrue,
    );

    final GameState game = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    for (var tic = 0; tic < 24; tic++) {
      game.runTic(const TicCmd(forwardMove: 50));
    }
    expect(fixedToDouble(game.player.x), greaterThanOrEqualTo(1392));
    expect(
      math.sqrt(
        math.pow(fixedToDouble(game.player.x) - 1376, 2) +
            math.pow(fixedToDouble(game.player.y) + 3504, 2),
      ),
      greaterThanOrEqualTo(16 - 1 / 256),
    );
  });

  test('original E1M1 connected corner contains a running wall slide', () {
    // Original lump order and topology, compacted to the three linedefs that
    // meet at vertex (1376, -3360): 31 continues north across a 64-unit step,
    // 33 closes the west side, and 37 is the long one-sided wall to the south.
    final MapData map = MapData(
      name: 'E1M1-LINES31-33-37',
      vertices: const <MapVertex>[
        MapVertex(1376, -3360),
        MapVertex(1376, -3264),
        MapVertex(1344, -3360),
        MapVertex(1376, -3648),
      ],
      linedefs: const <Linedef>[
        // Original linedef 31 and sidedefs 34/35.
        Linedef(
          v1: 0,
          v2: 1,
          flags: 28,
          special: 0,
          tag: 0,
          rightSidedef: 0,
          leftSidedef: 1,
        ),
        // Original linedef 33 and sidedef 37.
        Linedef(
          v1: 0,
          v2: 2,
          flags: LinedefFlags.blocking,
          special: 0,
          tag: 0,
          rightSidedef: 2,
          leftSidedef: kNoSidedef,
        ),
        // Original linedef 37 and sidedef 41.
        Linedef(
          v1: 3,
          v2: 0,
          flags: LinedefFlags.blocking,
          special: 0,
          tag: 0,
          rightSidedef: 3,
          leftSidedef: kNoSidedef,
        ),
      ],
      sidedefs: const <Sidedef>[
        Sidedef(
          xOffset: 0,
          yOffset: 0,
          upperTexture: 'STARTAN3',
          lowerTexture: 'STARTAN3',
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
          middleTexture: 'DOORSTOP',
          sector: 1,
        ),
        Sidedef(
          xOffset: 0,
          yOffset: 0,
          upperTexture: '-',
          lowerTexture: '-',
          middleTexture: 'STARTAN3',
          sector: 0,
        ),
      ],
      sectors: const <Sector>[
        // Original sector 5.
        Sector(
          floorHeight: -56,
          ceilingHeight: 216,
          floorFlat: 'FLOOR7_1',
          ceilingFlat: 'F_SKY1',
          lightLevel: 255,
          special: 0,
          tag: 0,
        ),
        // Original sector 14. Its 64-unit rise makes linedef 31 blocking.
        Sector(
          floorHeight: 8,
          ceilingHeight: 192,
          floorFlat: 'FLAT5_5',
          ceilingFlat: 'FLAT5_5',
          lightLevel: 255,
          special: 0,
          tag: 0,
        ),
      ],
      segs: const <Seg>[],
      subsectors: const <Subsector>[],
      nodes: const <BspNode>[],
      things: const <Thing>[
        Thing(
          x: 1392,
          y: -3504,
          angle: 90,
          type: 1,
          flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
        ),
      ],
      blockmap: null,
      reject: null,
    );
    final GameState game = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    final int startY = game.player.y;
    var furthestY = startY;

    // Maximum run-forward plus run-strafe values form a legal high-speed
    // diagonal. It pushes into line 37 while momentum carries the player
    // north to the blocking 31/33 junction at its endpoint.
    const TicCmd runIntoCorner = TicCmd(forwardMove: 50, sideMove: -40);
    for (var tic = 0; tic < 24; tic++) {
      game.runTic(runIntoCorner);
      if (game.player.y > furthestY) furthestY = game.player.y;
      expect(
        game.player.x,
        greaterThanOrEqualTo(toFixed(1392)),
        reason:
            'tic ${tic + 1} lost the player-radius clearance from the '
            'connected lines 31/33/37',
      );
    }

    expect(
      furthestY,
      greaterThan(startY + toFixed(96)),
      reason: 'collision containment must preserve a useful wall slide',
    );
    expect(
      game.player.y,
      lessThan(toFixed(-3360)),
      reason: 'the high-speed slide passed through the connected corner',
    );
  });

  test('original E1M1 linedef 125 receives its Wasm-safe puff impact', () {
    // Exact geometry and firing pose selected from the bundled original E1M1.
    // The former full 16.16 ratio overflowed before it could spawn PUFF.
    final MapData map = MapData(
      name: 'E1M1-LINE125',
      vertices: const <MapVertex>[MapVertex(64, -3648), MapVertex(-640, -3648)],
      linedefs: const <Linedef>[
        Linedef(
          v1: 0,
          v2: 1,
          flags: 0,
          special: 0,
          tag: 0,
          rightSidedef: 0,
          leftSidedef: kNoSidedef,
        ),
      ],
      sidedefs: const <Sidedef>[
        Sidedef(
          xOffset: 0,
          yOffset: 0,
          upperTexture: '-',
          lowerTexture: '-',
          middleTexture: 'STARTAN3',
          sector: 0,
        ),
      ],
      sectors: const <Sector>[
        Sector(
          floorHeight: 0,
          ceilingHeight: 128,
          floorFlat: 'FLOOR4_8',
          ceilingFlat: 'CEIL3_5',
          lightLevel: 160,
          special: 0,
          tag: 0,
        ),
      ],
      segs: const <Seg>[],
      subsectors: const <Subsector>[],
      nodes: const <BspNode>[],
      things: const <Thing>[
        Thing(
          x: -288,
          y: -3584,
          angle: 270,
          type: 1,
          flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
        ),
      ],
      blockmap: null,
      reject: null,
    );
    final GameState game = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    for (var tic = 0; tic < 5; tic++) {
      game.runTic(const TicCmd(buttons: Buttons.attack));
    }
    final MobjView puff = game.mobjs.singleWhere(
      (MobjView actor) => actor.sprite == 'PUFF',
    );
    expect(fixedToDouble(puff.x), closeTo(-288, 0.5));
    expect(fixedToDouble(puff.y), closeTo(-3644, 0.5));
  });
}
