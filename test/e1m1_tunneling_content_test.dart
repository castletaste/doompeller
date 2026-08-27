import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const String _defaultWadPath = '.local/doom/DOOM1.WAD';
const int _wallIndex = 6;
const int _legalSector = 38;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'original E1M1 spawn slides along west wall without tunneling',
    () async {
      final MapData map = await _loadOriginalE1M1();
      final Linedef wall = map.linedefs[_wallIndex];
      final MapVertex a = map.vertices[wall.v1];
      final MapVertex b = map.vertices[wall.v2];

      expect((a.x, a.y, b.x, b.y), (960, -3648, 832, -3552));
      expect(wall.isTwoSided, isFalse);
      expect(map.sidedefs[wall.rightSidedef].sector, _legalSector);

      final GameState game = GameState.start(
        map,
        const GameConfig(monsters: false),
      );
      expect(
        (
          fixedToInt(game.player.x),
          fixedToInt(game.player.y),
          game.player.angle,
        ),
        (1056, -3616, degreesToAngle(90)),
      );

      // These are the normal walking impulses emitted while A is held. At
      // angle 90, sideMove -24 drives west until the player contacts line 6.
      const TicCmd heldStrafeLeft = TicCmd(sideMove: -24);
      for (var tic = 0; tic < 22; tic++) {
        game.runTic(heldStrafeLeft);
        _expectContained(game, a, b, phase: 'strafe-left', tic: tic + 1);
      }

      // Release the key long enough for the retained momentum to settle at
      // the diagonal wall. The old axis-only slide path remains short of this
      // contact and is therefore caught by the assertion below.
      for (var tic = 0; tic < 30; tic++) {
        game.runTic(TicCmd.empty);
        _expectContained(game, a, b, phase: 'settle', tic: tic + 1);
      }
      final double settledDistance = _distanceToSegment(
        fixedToDouble(game.player.x),
        fixedToDouble(game.player.y),
        a.x.toDouble(),
        a.y.toDouble(),
        b.x.toDouble(),
        b.y.toDouble(),
      );
      expect(
        settledDistance,
        lessThan(17.5),
        reason: 'held strafe-left did not reach original E1M1 linedef 6',
      );
      final int settledY = game.player.y;

      // W is a keyboard-like forward TicCmd. It must continue north along
      // the wall rather than becoming permanently stuck or crossing it.
      const TicCmd heldForward = TicCmd(forwardMove: 25);
      for (var tic = 0; tic < 30; tic++) {
        game.runTic(heldForward);
        _expectContained(game, a, b, phase: 'forward', tic: tic + 1);
      }
      expect(
        game.player.y,
        greaterThan(settledY + toFixed(32)),
        reason: 'forward input remained snagged at diagonal linedef 6',
      );
    },
  );

  test('original E1M1 endpoint capsule cannot be cut by one tic', () async {
    final MapData original = await _loadOriginalE1M1();
    const int lineIndex = 37;
    final Linedef wall = original.linedefs[lineIndex];
    final MapVertex a = original.vertices[wall.v1];
    final MapVertex b = original.vertices[wall.v2];
    expect((a.x, a.y, b.x, b.y), (1376, -3648, 1376, -3360));
    expect(wall.isTwoSided, isFalse);

    // Running northwest builds enough momentum to round the exposed endpoint.
    // Destination-only collision used to accept tic 24 because both centers
    // were outside the endpoint circle even though the straight swept path
    // cut more than 1.5 map units into the player's collision radius.
    final GameState game = GameState.start(
      _withIsolatedLine(original, wall, x: 1428, y: -3380, angle: 172),
      const GameConfig(monsters: false),
    );
    for (var tic = 0; tic < 40; tic++) {
      final double beforeX = fixedToDouble(game.player.x);
      final double beforeY = fixedToDouble(game.player.y);
      game.runTic(const TicCmd(forwardMove: 50));
      final double afterX = fixedToDouble(game.player.x);
      final double afterY = fixedToDouble(game.player.y);
      final double sweptDistance = _segmentDistance(
        beforeX,
        beforeY,
        afterX,
        afterY,
        a.x.toDouble(),
        a.y.toDouble(),
        b.x.toDouble(),
        b.y.toDouble(),
      );
      expect(
        sweptDistance,
        greaterThanOrEqualTo(16 - 1 / 256),
        reason:
            'tic ${tic + 1} cut through original E1M1 line $lineIndex '
            'from ($beforeX,$beforeY) to ($afterX,$afterY)',
      );
    }
    expect(
      game.player.y,
      greaterThan(toFixed(-3344)),
      reason: 'swept collision must slide around, not lock at, the endpoint',
    );
  });
}

Future<MapData> _loadOriginalE1M1() async {
  final ByteData asset = await rootBundle.load(_defaultWadPath);
  final Uint8List bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  expect(bytes.lengthInBytes, 4196020);
  return MapData.load(WadSet(<WadFile>[WadFile.parse(bytes)]), 'E1M1');
}

MapData _withIsolatedLine(
  MapData source,
  Linedef line, {
  required int x,
  required int y,
  required int angle,
}) => MapData(
  name: source.name,
  vertices: source.vertices,
  linedefs: <Linedef>[line],
  sidedefs: source.sidedefs,
  sectors: source.sectors,
  segs: const <Seg>[],
  subsectors: const <Subsector>[],
  nodes: const <BspNode>[],
  things: <Thing>[
    Thing(
      x: x,
      y: y,
      angle: angle,
      type: 1,
      flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
    ),
  ],
  blockmap: null,
  reject: null,
);

void _expectContained(
  GameState game,
  MapVertex a,
  MapVertex b, {
  required String phase,
  required int tic,
}) {
  expect(
    game.playerSectorIndex,
    _legalSector,
    reason: '$phase tic $tic crossed out of legal sector $_legalSector',
  );
  final double x = fixedToDouble(game.player.x);
  final double y = fixedToDouble(game.player.y);
  final double cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
  expect(
    cross,
    lessThanOrEqualTo(0.01),
    reason: '$phase tic $tic crossed blocking linedef $_wallIndex',
  );
  expect(
    _distanceToSegment(
      x,
      y,
      a.x.toDouble(),
      a.y.toDouble(),
      b.x.toDouble(),
      b.y.toDouble(),
    ),
    greaterThanOrEqualTo(16 - 1 / 256),
    reason: '$phase tic $tic penetrated blocking linedef $_wallIndex',
  );
}

double _distanceToSegment(
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
  final double offsetX = px - closestX;
  final double offsetY = py - closestY;
  return math.sqrt(offsetX * offsetX + offsetY * offsetY);
}

double _segmentDistance(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double dx,
  double dy,
) {
  if (_segmentsIntersect(ax, ay, bx, by, cx, cy, dx, dy)) return 0;
  return <double>[
    _distanceToSegment(ax, ay, cx, cy, dx, dy),
    _distanceToSegment(bx, by, cx, cy, dx, dy),
    _distanceToSegment(cx, cy, ax, ay, bx, by),
    _distanceToSegment(dx, dy, ax, ay, bx, by),
  ].reduce(math.min);
}

bool _segmentsIntersect(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double dx,
  double dy,
) {
  double side(
    double x1,
    double y1,
    double x2,
    double y2,
    double px,
    double py,
  ) => (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1);

  final double abC = side(ax, ay, bx, by, cx, cy);
  final double abD = side(ax, ay, bx, by, dx, dy);
  final double cdA = side(cx, cy, dx, dy, ax, ay);
  final double cdB = side(cx, cy, dx, dy, bx, by);
  return ((abC <= 0 && abD >= 0) || (abC >= 0 && abD <= 0)) &&
      ((cdA <= 0 && cdB >= 0) || (cdA >= 0 && cdB <= 0));
}
