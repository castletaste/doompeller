@Tags(['content'])
library;

import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
// ignore: implementation_imports
import 'package:doom_core/src/map_runtime.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/local_iwad.dart';

const String _defaultWadPath = '.local/doom/DOOM1.WAD';
const List<int> _expectedLongWallChallenges = <int>[
  37,
  46,
  69,
  70,
  125,
  127,
  129,
  145,
  146,
  159,
  161,
  163,
  179,
  181,
  190,
  256,
  257,
  268,
  273,
  304,
  305,
  311,
  312,
  361,
  363,
  367,
  374,
  396,
  399,
  406,
  450,
  457,
  460,
  461,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('original E1M1 long one-sided walls contain a running player', () async {
    final ByteData asset = await loadLocalIwad(_defaultWadPath);
    final Uint8List bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    expect(bytes.lengthInBytes, 4196020);
    final WadFile wad = WadFile.parse(bytes);
    final MapData original = MapData.load(WadSet(<WadFile>[wad]), 'E1M1');
    expect(
      (
        vertices: original.vertices.length,
        linedefs: original.linedefs.length,
        sidedefs: original.sidedefs.length,
        sectors: original.sectors.length,
        segs: original.segs.length,
        subsectors: original.subsectors.length,
        nodes: original.nodes.length,
        things: original.things.length,
      ),
      (
        vertices: 467,
        linedefs: 475,
        sidedefs: 648,
        sectors: 85,
        segs: 732,
        subsectors: 237,
        nodes: 236,
        things: 138,
      ),
    );

    final Map<
      int,
      ({MapVertex a, MapVertex b, int startX, int startY, int angle})
    >
    challenges =
        <
          int,
          ({MapVertex a, MapVertex b, int startX, int startY, int angle})
        >{};
    for (var lineIndex = 0; lineIndex < original.linedefs.length; lineIndex++) {
      final Linedef line = original.linedefs[lineIndex];
      if (line.isTwoSided) continue;
      final MapVertex a = original.vertices[line.v1];
      final MapVertex b = original.vertices[line.v2];
      final int dx = b.x - a.x;
      final int dy = b.y - a.y;
      final double length = math.sqrt(dx * dx + dy * dy);
      if (length < 256) continue;

      final int startX = ((a.x + b.x) / 2 + dy * 24 / length).round();
      final int startY = ((a.y + b.y) / 2 - dx * 24 / length).round();
      if (_sectorAt(original, startX, startY) !=
          original.sidedefs[line.rightSidedef].sector) {
        continue;
      }
      final int startSide = _side(a, b, startX, startY);
      if (startSide >= 0) continue;

      final int angle =
          (math.atan2((a.y + b.y) / 2 - startY, (a.x + b.x) / 2 - startX) *
                  180 /
                  math.pi)
              .round() %
          360;
      challenges[lineIndex] = (
        a: a,
        b: b,
        startX: startX,
        startY: startY,
        angle: angle,
      );
    }

    expect(
      challenges.keys.toList(growable: false),
      _expectedLongWallChallenges,
    );

    // Exercise the exact production predicate exhaustively. Before the fix,
    // the 16.16 projection overflowed for 33 of these 34 E1M1 linedefs.
    final MapRuntime runtime = MapRuntime(original);
    final List<int> predicateMisses = <int>[];
    for (final entry in challenges.entries) {
      final int lineIndex = entry.key;
      final Linedef line = original.linedefs[lineIndex];
      final MapVertex a = original.vertices[line.v1];
      final MapVertex b = original.vertices[line.v2];
      if (!runtime.blocksAt(
        lineIndex,
        (toFixed(a.x) + toFixed(b.x)) ~/ 2,
        (toFixed(a.y) + toFixed(b.y)) ~/ 2,
        toFixed(16),
        0,
        toFixed(56),
      )) {
        predicateMisses.add(lineIndex);
      }
    }
    expect(
      predicateMisses,
      isEmpty,
      reason: 'player circle missed original E1M1 walls $predicateMisses',
    );

    // Keep full movement coverage at the first, formerly non-failing middle,
    // and final challenge. The exhaustive assertion above owns arithmetic
    // coverage; these three own GameState integration without making Wasm
    // instantiate E1M1 thirty-four times.
    final List<int> escaped = <int>[];
    final List<int> penetrated = <int>[];
    for (final int lineIndex in const <int>[37, 179, 461]) {
      final challenge = challenges[lineIndex]!;
      final MapVertex a = challenge.a;
      final MapVertex b = challenge.b;
      final MapData map = MapData(
        name: original.name,
        vertices: original.vertices,
        linedefs: original.linedefs,
        sidedefs: original.sidedefs,
        sectors: original.sectors,
        segs: original.segs,
        subsectors: original.subsectors,
        nodes: original.nodes,
        things: <Thing>[
          Thing(
            x: challenge.startX,
            y: challenge.startY,
            angle: challenge.angle,
            type: 1,
            flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
          ),
        ],
        blockmap: original.blockmap,
        reject: original.reject,
      );
      final GameState game = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      for (var tic = 0; tic < 24; tic++) {
        final int beforeX = game.player.x;
        final int beforeY = game.player.y;
        game.runTic(const TicCmd(forwardMove: 50));
        if (_properlyIntersects(
          beforeX,
          beforeY,
          game.player.x,
          game.player.y,
          toFixed(a.x),
          toFixed(a.y),
          toFixed(b.x),
          toFixed(b.y),
        )) {
          escaped.add(lineIndex);
          break;
        }
        final double distance = _distanceToSegmentMapUnits(
          fixedToDouble(game.player.x),
          fixedToDouble(game.player.y),
          a.x.toDouble(),
          a.y.toDouble(),
          b.x.toDouble(),
          b.y.toDouble(),
        );
        if (_side(a, b, fixedToInt(game.player.x), fixedToInt(game.player.y)) >
                0 ||
            distance < 16 - 1 / 256) {
          penetrated.add(lineIndex);
          break;
        }
      }
    }

    expect(
      escaped,
      isEmpty,
      reason: 'player crossed original E1M1 one-sided linedefs $escaped',
    );
    expect(
      penetrated,
      isEmpty,
      reason: 'player penetrated original E1M1 one-sided linedefs $penetrated',
    );
  });

  test('original E1M1 tangent player can advance parallel to a wall', () async {
    final ByteData asset = await loadLocalIwad(_defaultWadPath);
    final Uint8List bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    final MapData original = MapData.load(
      WadSet(<WadFile>[WadFile.parse(bytes)]),
      'E1M1',
    );
    final Linedef wall = original.linedefs[37];
    final MapVertex a = original.vertices[wall.v1];
    final MapVertex b = original.vertices[wall.v2];
    expect((a.x, a.y, b.x, b.y), (1376, -3648, 1376, -3360));
    expect(wall.isTwoSided, isFalse);

    final GameState game = GameState.start(
      _withPlayer(original, x: 1392, y: -3504, angle: 90),
      const GameConfig(monsters: false),
    );
    final int startY = game.player.y;
    for (var tic = 0; tic < 12; tic++) {
      game.runTic(const TicCmd(forwardMove: 25));
    }

    expect(
      game.player.y,
      greaterThan(startY + toFixed(16)),
      reason: 'touching a wall must not lock movement along its tangent',
    );
    expect(
      game.player.x,
      greaterThanOrEqualTo(toFixed(1392)),
      reason: 'parallel movement must not penetrate original linedef 37',
    );

    final GameState intoWall = GameState.start(
      _withPlayer(original, x: 1392, y: -3504, angle: 270),
      const GameConfig(monsters: false),
    );
    for (var tic = 0; tic < 12; tic++) {
      intoWall.runTic(const TicCmd(forwardMove: 25));
    }
    expect(
      intoWall.player.x,
      greaterThanOrEqualTo(toFixed(1376)),
      reason: 'an inward move must not cross the one-sided wall',
    );

    final GameState awayFromWall = GameState.start(
      _withPlayer(original, x: 1392, y: -3504, angle: 0),
      const GameConfig(monsters: false),
    );
    for (var tic = 0; tic < 12; tic++) {
      awayFromWall.runTic(const TicCmd(forwardMove: 25));
    }
    expect(
      awayFromWall.player.x,
      greaterThan(toFixed(1392)),
      reason: 'an outward move must escape the wall contact',
    );

    final GameState invalidBackSide = GameState.start(
      _withPlayer(original, x: 1360, y: -3504, angle: 90),
      const GameConfig(monsters: false),
    );
    final int invalidStartY = invalidBackSide.player.y;
    for (var tic = 0; tic < 12; tic++) {
      invalidBackSide.runTic(const TicCmd(forwardMove: 25));
    }
    expect(
      invalidBackSide.player.y,
      invalidStartY,
      reason: 'a back-side actor must not use the legal tangent-slide bypass',
    );
  });

  test(
    'original E1M1 true spawn strafe remains contained at diagonal cap',
    () async {
      final ByteData asset = await loadLocalIwad(_defaultWadPath);
      final Uint8List bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final MapData original = MapData.load(
        WadSet(<WadFile>[WadFile.parse(bytes)]),
        'E1M1',
      );
      final GameState game = GameState.start(
        _withPlayer(original, x: 1056, y: -3616, angle: 90),
        const GameConfig(monsters: false),
      );
      final Linedef wall = original.linedefs[6];
      final MapVertex a = original.vertices[wall.v1];
      final MapVertex b = original.vertices[wall.v2];
      expect((a.x, a.y, b.x, b.y), (960, -3648, 832, -3552));
      expect(wall.isTwoSided, isFalse);

      final int startX = game.player.x;
      final int startY = game.player.y;
      var crossedWall = false;
      var penetratedWall = false;
      void tick(TicCmd command) {
        final int beforeX = game.player.x;
        final int beforeY = game.player.y;
        game.runTic(command);
        crossedWall =
            crossedWall ||
            _properlyIntersects(
              beforeX,
              beforeY,
              game.player.x,
              game.player.y,
              toFixed(a.x),
              toFixed(a.y),
              toFixed(b.x),
              toFixed(b.y),
            );
        final double distance = _distanceToSegmentMapUnits(
          fixedToDouble(game.player.x),
          fixedToDouble(game.player.y),
          a.x.toDouble(),
          a.y.toDouble(),
          b.x.toDouble(),
          b.y.toDouble(),
        );
        penetratedWall = penetratedWall || distance < 16 - 1 / 256;
      }

      // Reach the diagonal cap with the real keyboard strafe command, let the
      // residual momentum settle, then walk north along the wall.
      for (var tic = 0; tic < 22; tic++) {
        tick(const TicCmd(sideMove: -24));
      }
      for (var tic = 0; tic < 30; tic++) {
        tick(TicCmd.empty);
      }
      for (var tic = 0; tic < 30; tic++) {
        tick(const TicCmd(forwardMove: 25));
      }

      expect(crossedWall, isFalse, reason: 'crossed original E1M1 linedef 6');
      expect(
        penetratedWall,
        isFalse,
        reason: 'entered the radius of original E1M1 linedef 6',
      );
      expect(
        game.player.y,
        greaterThan(startY + toFixed(128)),
        reason: 'the true-spawn route must continue past the diagonal cap',
      );
      expect(
        game.player.x,
        lessThan(startX - toFixed(64)),
        reason: 'the player must make progress while skimming the cap',
      );
      expect(
        _side(a, b, fixedToInt(game.player.x), fixedToInt(game.player.y)),
        lessThan(0),
        reason: 'the player must remain on linedef 6 front side',
      );
    },
  );
}

MapData _withPlayer(
  MapData source, {
  required int x,
  required int y,
  required int angle,
}) => MapData(
  name: source.name,
  vertices: source.vertices,
  linedefs: source.linedefs,
  sidedefs: source.sidedefs,
  sectors: source.sectors,
  segs: source.segs,
  subsectors: source.subsectors,
  nodes: source.nodes,
  things: <Thing>[
    Thing(
      x: x,
      y: y,
      angle: angle,
      type: 1,
      flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
    ),
  ],
  blockmap: source.blockmap,
  reject: source.reject,
);

double _distanceToSegmentMapUnits(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final double dx = bx - ax;
  final double dy = by - ay;
  final double lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) {
    return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
  }
  final double projection = (((px - ax) * dx + (py - ay) * dy) / lengthSquared)
      .clamp(0, 1);
  final double closestX = ax + dx * projection;
  final double closestY = ay + dy * projection;
  final double ox = px - closestX;
  final double oy = py - closestY;
  return math.sqrt(ox * ox + oy * oy);
}

int _side(MapVertex a, MapVertex b, int x, int y) =>
    (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);

bool _properlyIntersects(
  int ax,
  int ay,
  int bx,
  int by,
  int cx,
  int cy,
  int dx,
  int dy,
) {
  int side(int x1, int y1, int x2, int y2, int px, int py) =>
      (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1);
  final int abC = side(ax, ay, bx, by, cx, cy);
  final int abD = side(ax, ay, bx, by, dx, dy);
  final int cdA = side(cx, cy, dx, dy, ax, ay);
  final int cdB = side(cx, cy, dx, dy, bx, by);
  return ((abC < 0 && abD > 0) || (abC > 0 && abD < 0)) &&
      ((cdA < 0 && cdB > 0) || (cdA > 0 && cdB < 0));
}

int _sectorAt(MapData map, int x, int y) {
  int child = map.bspRoot;
  var guard = 0;
  while ((child & kSubsectorBit) == 0 && guard++ <= map.nodes.length) {
    final BspNode node = map.nodes[child];
    final int side = (x - node.x) * node.dy - (y - node.y) * node.dx;
    child = side >= 0 ? node.rightChild : node.leftChild;
  }
  final Subsector subsector = map.subsectors[child & ~kSubsectorBit];
  final Seg seg = map.segs[subsector.firstSeg];
  final Linedef line = map.linedefs[seg.linedef];
  final int sidedef = seg.side == 0 ? line.rightSidedef : line.leftSidedef;
  return map.sidedefs[sidedef].sector;
}
