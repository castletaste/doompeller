// Developer-only, read-only E1M1 route search and GameState replay proof.
//
// The IWAD is held in memory and never extracted or written. Output contains
// only simulation telemetry; it deliberately omits map geometry and WAD data.
import 'dart:io';
import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';

import 'wad_report.dart' show readWadBytes;

const String _wadPathEnvironment = 'DOOM_WAD_PATH';
const String _mapName = 'E1M1';

Future<void> main(List<String> arguments) async {
  final String path = arguments.isNotEmpty
      ? arguments.single
      : (Platform.environment[_wadPathEnvironment]?.trim() ?? '');
  if (path.isEmpty) {
    stderr.writeln(
      'Set DOOM_WAD_PATH to a legally obtained IWAD or pass its path.',
    );
    exitCode = 2;
    return;
  }

  try {
    final WadFile wad = WadFile.parse(readWadBytes(path));
    final MapData map = MapData.load(WadSet(<WadFile>[wad]), _mapName);
    final E1m1PlaythroughResult result = E1m1PlaythroughRunner(map).run();
    stdout.writeln(result.summary);
    if (!result.completed) exitCode = 1;
  } on Object catch (error) {
    stderr.writeln('E1M1 PLAYTHROUGH FAILED: $error');
    exitCode = 1;
  }
}

/// Aggregate proof from an input-only [GameState] traversal.
final class E1m1PlaythroughResult {
  const E1m1PlaythroughResult({
    required this.completed,
    required this.tics,
    required this.health,
    required this.finalSector,
    required this.kills,
    required this.totalKills,
    required this.items,
    required this.totalItems,
    required this.secrets,
    required this.totalSecrets,
    required this.commands,
    required this.doorOpened,
    required this.liftActivated,
    required this.liftMoved,
    required this.damageObserved,
    required this.floorInvariantHeld,
    required this.wallInvariantHeld,
    required this.maxStationaryTics,
    required this.p95Micros,
    required this.maxMicros,
    required this.hash,
  });

  final bool completed;
  final int tics;
  final int health;
  final int finalSector;
  final int kills, totalKills, items, totalItems, secrets, totalSecrets;
  final List<TicCmd> commands;
  final bool doorOpened;
  final bool liftActivated;
  final bool liftMoved;
  final bool damageObserved;
  final bool floorInvariantHeld;
  final bool wallInvariantHeld;
  final int maxStationaryTics;
  final int p95Micros;
  final int maxMicros;
  final int hash;

  String get summary =>
      'E1M1 ${completed ? 'COMPLETE' : 'INCOMPLETE'}: '
      'tics=$tics health=$health sector=$finalSector '
      'kills=$kills/$totalKills items=$items/$totalItems '
      'secrets=$secrets/$totalSecrets '
      'doors=$doorOpened lift=$liftActivated/$liftMoved '
      'damage=$damageObserved floor=$floorInvariantHeld wall=$wallInvariantHeld '
      'maxStationary=$maxStationaryTics '
      'ticP95=${p95Micros}us ticMax=${maxMicros}us '
      'hash=0x${hash.toRadixString(16)}';
}

/// Finds a route from the player start through a lift and damaging sector to
/// an exit, then drives that route through the real 35 Hz simulation.
final class E1m1PlaythroughRunner {
  E1m1PlaythroughRunner(this.map);

  final MapData map;

  E1m1PlaythroughResult run() {
    final Thing start = map.things.firstWhere((Thing thing) => thing.type == 1);
    final _Planner planner = _Planner(map, _Point(start.x, start.y));
    final _PlannedRoute route = planner.plan();
    final GameState game = GameState.start(
      map,
      const GameConfig(monsters: false),
      seed: 0xE1,
    );
    final _Driver driver = _Driver(map, game);

    _stage('route to lift', () => driver.follow(route.toLift));
    if (_Planner._liftUseSpecials.contains(
      map.linedefs[route.liftLine].special,
    )) {
      _stage('activate lift', () => driver.useLine(route.liftLine));
    } else {
      _stage('cross lift trigger', () => driver.crossLine(route.liftLine));
    }
    driver.wait(160);
    _stage(
      'route to damaging sector',
      () => driver.follow(route.toDamage, includeFirst: true),
    );
    _stage('observe sector damage', driver.waitForSectorDamage);
    _stage('route to exit', () => driver.follow(route.toExit));
    if (_Planner._exitUseSpecials.contains(
      map.linedefs[route.exitLine].special,
    )) {
      _stage(
        'activate exit',
        () => driver.useLine(route.exitLine, untilComplete: true),
      );
    } else {
      _stage('cross exit trigger', () => driver.crossLine(route.exitLine));
    }

    final List<int> sortedMicros = List<int>.of(driver.tickMicros)..sort();
    final int p95Index = math.max(0, (sortedMicros.length * 0.95).ceil() - 1);
    return E1m1PlaythroughResult(
      completed: game.levelComplete,
      tics: game.tic,
      health: game.player.health,
      finalSector: game.playerSectorIndex,
      kills: game.killCount,
      totalKills: game.totalKills,
      items: game.itemCount,
      totalItems: game.totalItems,
      secrets: game.secretsFound,
      totalSecrets: game.totalSecrets,
      commands: List<TicCmd>.unmodifiable(driver.commands),
      doorOpened: driver.doorOpened,
      liftActivated: driver.liftActivated,
      liftMoved: driver.liftMoved,
      damageObserved: driver.damageObserved,
      floorInvariantHeld: driver.floorInvariantHeld,
      wallInvariantHeld: driver.wallInvariantHeld,
      maxStationaryTics: driver.maxStationaryTics,
      p95Micros: sortedMicros[p95Index],
      maxMicros: sortedMicros.last,
      hash: game.hashState(),
    );
  }

  static void _stage(String name, void Function() action) {
    try {
      action();
    } on StateError catch (error) {
      throw StateError('$name: ${error.message}');
    }
  }
}

final class _PlannedRoute {
  const _PlannedRoute({
    required this.toLift,
    required this.liftLine,
    required this.toDamage,
    required this.toExit,
    required this.exitLine,
  });

  final List<_Point> toLift;
  final int liftLine;
  final List<_Point> toDamage;
  final List<_Point> toExit;
  final int exitLine;
}

final class _Planner {
  _Planner(this.map, this.origin) {
    for (var i = 0; i < map.linedefs.length; i++) {
      final Linedef line = map.linedefs[i];
      if (_dynamicSpecials.contains(line.special)) {
        if (line.tag == 0) {
          final int? back = _backSector(line);
          if (back != null) _dynamicSectors.add(back);
        } else {
          for (var sector = 0; sector < map.sectors.length; sector++) {
            if (map.sectors[sector].tag == line.tag) {
              _dynamicSectors.add(sector);
            }
          }
        }
      }
    }
  }

  static const int _grid = 8;
  // Keep two map units of planning clearance beyond the simulation radius so
  // integer grid points do not graze a corner that collision treats as closed.
  static const int _radius = 18;
  static const int _height = 56;
  static const Set<int> _liftUseSpecials = <int>{21, 62, 122, 123};
  static const Set<int> _liftWalkSpecials = <int>{10, 88, 120, 121};
  static const Set<int> _exitUseSpecials = <int>{11, 51};
  static const Set<int> _exitWalkSpecials = <int>{52, 124};
  static const Set<int> _dynamicSpecials = <int>{
    1,
    2,
    3,
    4,
    10,
    16,
    21,
    26,
    27,
    28,
    31,
    32,
    33,
    34,
    61,
    62,
    75,
    86,
    88,
    90,
    99,
    103,
    120,
    121,
    122,
    123,
    134,
  };

  final MapData map;
  final _Point origin;
  final Set<int> _dynamicSectors = <int>{};

  int _frontSector(Linedef line) => map.sidedefs[line.rightSidedef].sector;
  int? _backSector(Linedef line) => line.leftSidedef == kNoSidedef
      ? null
      : map.sidedefs[line.leftSidedef].sector;

  _PlannedRoute plan() {
    final List<int> lifts = <int>[
      for (var i = 0; i < map.linedefs.length; i++)
        if (_liftUseSpecials.contains(map.linedefs[i].special) ||
            _liftWalkSpecials.contains(map.linedefs[i].special))
          i,
    ];
    final List<int> exits = <int>[
      for (var i = 0; i < map.linedefs.length; i++)
        if (_exitUseSpecials.contains(map.linedefs[i].special) ||
            _exitWalkSpecials.contains(map.linedefs[i].special))
          i,
    ];
    if (lifts.isEmpty) {
      throw StateError('E1M1 lacks a supported lift trigger');
    }
    if (exits.isEmpty) {
      throw StateError('E1M1 lacks a supported exit line');
    }

    _RouteCandidate? bestLift;
    for (final int line in lifts) {
      for (final _Point target in _frontActionPoints(line)) {
        final List<_Point>? path = _search(
          origin,
          (p) => p.distance2(target) <= 256,
          allowBackDoorCrossing: true,
        );
        if (path != null &&
            (bestLift == null || path.length < bestLift.path.length)) {
          bestLift = _RouteCandidate(line, path, target);
        }
      }
    }
    if (bestLift == null) {
      throw StateError('no reachable supported lift trigger');
    }

    final _Point afterLift =
        _liftWalkSpecials.contains(map.linedefs[bestLift.line].special)
        ? _backActionPoint(bestLift.line)
        : bestLift.path.last;
    List<_Point>? bestDamagePath;
    _RouteCandidate? bestExit;
    for (
      var damagingSector = 0;
      damagingSector < map.sectors.length;
      damagingSector++
    ) {
      if (!_damagingSectors.contains(map.sectors[damagingSector].special)) {
        continue;
      }
      final List<_Point>? damagePath = _search(
        afterLift,
        (p) => _sectorAt(p) == damagingSector && _hasLineClearance(p, 32),
        allowBackDoorCrossing: true,
      );
      if (damagePath == null) continue;
      for (final int line in exits) {
        for (final _Point target in _frontActionPoints(line)) {
          final List<_Point>? path = _search(
            damagePath.last,
            (p) => p.distance2(target) <= 256,
            allowBackDoorCrossing: true,
          );
          if (path != null &&
              (bestExit == null ||
                  path.length + damagePath.length <
                      bestExit.path.length + bestDamagePath!.length)) {
            bestDamagePath = damagePath;
            bestExit = _RouteCandidate(line, path, target);
          }
        }
      }
    }
    if (bestDamagePath == null) {
      throw StateError('no lift/damaging-sector/exit route obeys door sides');
    }
    if (bestExit == null) {
      throw StateError('no reachable supported exit switch');
    }

    return _PlannedRoute(
      toLift: <_Point>[...bestLift.path, bestLift.target],
      liftLine: bestLift.line,
      toDamage: bestDamagePath,
      toExit: <_Point>[...bestExit.path, bestExit.target],
      exitLine: bestExit.line,
    );
  }

  List<_Point>? routeBetween(_Point start, _Point target) => _search(
    start,
    (point) => point.distance2(target) <= 16 * 16,
    allowBackDoorCrossing: true,
  );

  static const Set<int> _damagingSectors = <int>{5, 7, 11};

  bool _hasLineClearance(_Point point, int clearance) {
    for (final Linedef line in map.linedefs) {
      if (_distanceSquared(
            point,
            map.vertices[line.v1],
            map.vertices[line.v2],
          ) <=
          clearance * clearance) {
        return false;
      }
    }
    return true;
  }

  List<_Point> _frontActionPoints(int lineIndex) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    final double dx = (b.x - a.x).toDouble();
    final double dy = (b.y - a.y).toDouble();
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) throw StateError('zero-length action line');
    return <_Point>[
      for (final double along in const <double>[0.25, 0.5, 0.75])
        for (final int offset in const <int>[24, 32, 48, 64])
          _Point(
            (a.x + dx * along + dy * offset / length).round(),
            (a.y + dy * along - dx * offset / length).round(),
          ),
    ];
  }

  _Point _backActionPoint(int lineIndex) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    final double dx = (b.x - a.x).toDouble();
    final double dy = (b.y - a.y).toDouble();
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) throw StateError('zero-length action line');
    return _Point(
      ((a.x + b.x) / 2 - dy * 32 / length).round(),
      ((a.y + b.y) / 2 + dx * 32 / length).round(),
    );
  }

  List<_Point>? _search(
    _Point start,
    bool Function(_Point) goal, {
    required bool allowBackDoorCrossing,
  }) {
    final List<_Point> queue = <_Point>[start];
    final Map<_GridKey, _GridKey?> previous = <_GridKey, _GridKey?>{};
    final Map<_GridKey, _Point> points = <_GridKey, _Point>{};
    final _GridKey startKey = _key(start);
    previous[startKey] = null;
    points[startKey] = start;
    var head = 0;
    _GridKey? found;
    while (head < queue.length && queue.length < 250000) {
      final _Point current = queue[head++];
      final _GridKey currentKey = _key(current);
      if (goal(current)) {
        found = currentKey;
        break;
      }
      for (final (int, int) delta in const <(int, int)>[
        (1, 0),
        (-1, 0),
        (0, 1),
        (0, -1),
        (1, 1),
        (1, -1),
        (-1, 1),
        (-1, -1),
      ]) {
        final _GridKey nextKey = _GridKey(
          currentKey.x + delta.$1,
          currentKey.y + delta.$2,
        );
        if (previous.containsKey(nextKey)) continue;
        final _Point next = _point(nextKey);
        if (!_standable(next) ||
            !_segmentPassable(
              current,
              next,
              allowBackDoorCrossing: allowBackDoorCrossing,
            )) {
          continue;
        }
        previous[nextKey] = currentKey;
        points[nextKey] = next;
        queue.add(next);
      }
    }
    if (found == null) return null;
    final List<_Point> reversed = <_Point>[];
    _GridKey? cursor = found;
    while (cursor != null) {
      reversed.add(points[cursor]!);
      cursor = previous[cursor];
    }
    return reversed.reversed.toList(growable: false);
  }

  _GridKey _key(_Point point) => _GridKey(
    ((point.x - origin.x) / _grid).round(),
    ((point.y - origin.y) / _grid).round(),
  );
  _Point _point(_GridKey key) =>
      _Point(origin.x + key.x * _grid, origin.y + key.y * _grid);

  bool _segmentPassable(
    _Point a,
    _Point b, {
    required bool allowBackDoorCrossing,
  }) {
    final int fromSector = _sectorAt(a);
    final int toSector = _sectorAt(b);
    if (fromSector != toSector) {
      var connected = false;
      for (final Linedef line in map.linedefs) {
        if (!line.isTwoSided || !_segmentsIntersect(a, b, line)) continue;
        final int front = _frontSector(line);
        final int? back = _backSector(line);
        if (back == null ||
            !((front == fromSector && back == toSector) ||
                (back == fromSector && front == toSector))) {
          continue;
        }
        connected = true;
        final Sector f = map.sectors[front];
        final Sector r = map.sectors[back];
        final bool initiallyBlocked =
            math.min(f.ceilingHeight, r.ceilingHeight) -
                math.max(f.floorHeight, r.floorHeight) <
            _height;
        if (initiallyBlocked &&
            line.special == 0 &&
            _dynamicSectors.contains(toSector) &&
            !_dynamicSectors.contains(fromSector)) {
          return false;
        }
      }
      if (!connected) return false;
    }
    if (!allowBackDoorCrossing) {
      for (final Linedef line in map.linedefs) {
        if (!_doorUseSpecials.contains(line.special) ||
            !_segmentsIntersect(a, b, line)) {
          continue;
        }
        final MapVertex start = map.vertices[line.v1];
        final MapVertex end = map.vertices[line.v2];
        final int fromSide =
            (end.x - start.x) * (a.y - start.y) -
            (end.y - start.y) * (a.x - start.x);
        final int toSide =
            (end.x - start.x) * (b.y - start.y) -
            (end.y - start.y) * (b.x - start.x);
        if (fromSide > 0 && toSide <= 0) return false;
      }
    }
    final int dx = b.x - a.x;
    final int dy = b.y - a.y;
    final int steps = math.max(1, (math.sqrt(dx * dx + dy * dy) / 8).ceil());
    for (var i = 1; i <= steps; i++) {
      final _Point sample = _Point(
        a.x + dx * i ~/ steps,
        a.y + dy * i ~/ steps,
      );
      if (!_standable(sample)) return false;
    }
    return true;
  }

  static const Set<int> _doorUseSpecials = <int>{
    1,
    26,
    27,
    28,
    31,
    32,
    33,
    34,
    61,
    99,
    103,
    134,
  };

  bool _segmentsIntersect(_Point p1, _Point p2, Linedef line) {
    final MapVertex q1 = map.vertices[line.v1];
    final MapVertex q2 = map.vertices[line.v2];
    if (math.max(p1.x, p2.x) < math.min(q1.x, q2.x) ||
        math.max(q1.x, q2.x) < math.min(p1.x, p2.x) ||
        math.max(p1.y, p2.y) < math.min(q1.y, q2.y) ||
        math.max(q1.y, q2.y) < math.min(p1.y, p2.y)) {
      return false;
    }
    int side(int ax, int ay, int bx, int by, int px, int py) =>
        (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    final int a = side(p1.x, p1.y, p2.x, p2.y, q1.x, q1.y);
    final int b = side(p1.x, p1.y, p2.x, p2.y, q2.x, q2.y);
    final int c = side(q1.x, q1.y, q2.x, q2.y, p1.x, p1.y);
    final int d = side(q1.x, q1.y, q2.x, q2.y, p2.x, p2.y);
    return ((a <= 0 && b >= 0) || (a >= 0 && b <= 0)) &&
        ((c <= 0 && d >= 0) || (c >= 0 && d <= 0));
  }

  bool _standable(_Point point) {
    final int sectorIndex = _sectorAt(point);
    final Sector sector = map.sectors[sectorIndex];
    if (!_dynamicSectors.contains(sectorIndex) &&
        sector.ceilingHeight - sector.floorHeight < _height) {
      return false;
    }
    for (final Thing thing in map.things) {
      if (thing.type == 1 ||
          (thing.flags & ThingFlags.multiplayerOnly) != 0 ||
          (thing.flags != 0 && (thing.flags & ThingFlags.medium) == 0)) {
        continue;
      }
      final MobjInfo? info = DoomCoreCatalog.infoForEdNum(thing.type);
      if (info == null || !info.isSolid) continue;
      final int dx = point.x - thing.x;
      final int dy = point.y - thing.y;
      final int combinedRadius = _radius + info.radius;
      if (dx * dx + dy * dy < combinedRadius * combinedRadius) return false;
    }
    for (final Linedef line in map.linedefs) {
      final MapVertex a = map.vertices[line.v1];
      final MapVertex b = map.vertices[line.v2];
      if (_distanceSquared(point, a, b) > _radius * _radius) continue;
      if (line.blocksMovement || !line.isTwoSided) return false;
      final int front = _frontSector(line);
      final int? back = _backSector(line);
      if (back == null) return false;
      if (_dynamicSectors.contains(front) || _dynamicSectors.contains(back)) {
        continue;
      }
      final Sector f = map.sectors[front];
      final Sector r = map.sectors[back];
      final int bottom = math.max(f.floorHeight, r.floorHeight);
      final int top = math.min(f.ceilingHeight, r.ceilingHeight);
      if (top - bottom < _height ||
          (f.floorHeight - r.floorHeight).abs() > 24) {
        return false;
      }
    }
    return true;
  }

  int _sectorAt(_Point point) {
    if (!map.hasBsp) return 0;
    int child = map.bspRoot;
    var guard = 0;
    while ((child & kSubsectorBit) == 0 && guard++ < map.nodes.length + 1) {
      final BspNode node = map.nodes[child];
      final int side =
          (point.x - node.x) * node.dy - (point.y - node.y) * node.dx;
      child = side >= 0 ? node.rightChild : node.leftChild;
    }
    final int subsectorIndex = child & ~kSubsectorBit;
    final Subsector subsector = map.subsectors[subsectorIndex];
    final Seg seg = map.segs[subsector.firstSeg];
    final Linedef line = map.linedefs[seg.linedef];
    final int sidedef = seg.side == 0 ? line.rightSidedef : line.leftSidedef;
    return map.sidedefs[sidedef].sector;
  }

  static int _distanceSquared(_Point p, MapVertex a, MapVertex b) {
    final int dx = b.x - a.x;
    final int dy = b.y - a.y;
    final int length2 = dx * dx + dy * dy;
    if (length2 == 0) return p.distance2(_Point(a.x, a.y));
    final double t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2;
    final double clamped = t.clamp(0, 1);
    final double qx = a.x + dx * clamped;
    final double qy = a.y + dy * clamped;
    final double ox = p.x - qx;
    final double oy = p.y - qy;
    return (ox * ox + oy * oy).round();
  }
}

final class _Driver {
  _Driver(this.map, this.game)
    : _lastX = game.player.x,
      _lastY = game.player.y,
      _lastLiftFloors = <int>[for (final s in game.sectors) s.floorHeight];

  final MapData map;
  final GameState game;
  final List<TicCmd> commands = <TicCmd>[];
  final List<int> tickMicros = <int>[];
  List<int> _lastLiftFloors;
  int _lastX;
  int _lastY;
  int _estimatedMomX = 0;
  int _estimatedMomY = 0;
  int _stationary = 0;
  int maxStationaryTics = 0;
  bool doorOpened = false;
  int doorOpenEvents = 0;
  bool liftActivated = false;
  bool liftMoved = false;
  bool damageObserved = false;
  bool floorInvariantHeld = true;
  bool wallInvariantHeld = true;
  static const int _playerThrustPerCommand = 2048;
  static const Set<int> _doorUseSpecials = <int>{
    1,
    26,
    27,
    28,
    31,
    32,
    33,
    34,
    61,
    99,
    103,
    134,
  };

  void follow(List<_Point> points, {bool includeFirst = false}) {
    for (var index = includeFirst ? 0 : 1; index < points.length; index++) {
      try {
        _driveTo(points[index]);
      } on StateError catch (error) {
        if (_nearbySolidActors() > 0) {
          final _Point current = _Point(
            fixedToInt(game.player.x),
            fixedToInt(game.player.y),
          );
          final List<_Point>? detour = _Planner(
            map,
            current,
          ).routeBetween(current, points[index]);
          if (detour != null) {
            follow(detour, includeFirst: true);
            continue;
          }
        }
        throw StateError(
          'waypoint $index/${points.length - 1}: ${error.message}; '
          'doorOpened=$doorOpened liftActivated=$liftActivated '
          'tic=${game.tic} '
          'sector=${game.playerSectorIndex}/${_sectorAt(_Point(fixedToInt(game.player.x), fixedToInt(game.player.y)))}->${_sectorAt(points[index])} '
          'nearby=${_nearbySpecials()} '
          'doors=${_nearbyDoorLines().length}/${_nearbyDoorCount()} '
          'doorTopology=${_nearbyDoorTopology()} '
          'planes=${_sectorPlanes(game.playerSectorIndex)}/${_sectorPlanes(_sectorAt(points[index]))} '
          'connections=${_connections(game.playerSectorIndex, _sectorAt(points[index]))} '
          'solidActors=${_nearbySolidActors()} '
          'stationary=$_stationary '
          'distance=${fixedToInt(approxDistance(toFixed(points[index].x) - game.player.x, toFixed(points[index].y) - game.player.y))}',
        );
      }
    }
  }

  List<int> _nearbySpecials() {
    final _Point player = _Point(
      fixedToInt(game.player.x),
      fixedToInt(game.player.y),
    );
    return <int>{
      for (final Linedef line in map.linedefs)
        if (_Planner._distanceSquared(
              player,
              map.vertices[line.v1],
              map.vertices[line.v2],
            ) <=
            96 * 96)
          line.special,
    }.toList()..sort();
  }

  int _nearbySolidActors() {
    var count = 0;
    for (final MobjView mobj in game.mobjs) {
      if (mobj.id == 1 || (mobj.flags & MobjFlags.solid) == 0) continue;
      final int dx = mobj.x - game.player.x;
      final int dy = mobj.y - game.player.y;
      if (dx * dx + dy * dy <= toFixed(96) * toFixed(96)) count++;
    }
    return count;
  }

  String _sectorPlanes(int index) {
    final SectorRuntime sector = game.sectors.elementAt(index);
    return '${fixedToInt(sector.floorHeight)}:${fixedToInt(sector.ceilingHeight)}';
  }

  List<String> _connections(int first, int second) {
    final _Point player = _Point(
      fixedToInt(game.player.x),
      fixedToInt(game.player.y),
    );
    final List<String> result = <String>[];
    for (final Linedef line in map.linedefs) {
      if (!line.isTwoSided) continue;
      final int front = map.sidedefs[line.rightSidedef].sector;
      final int back = map.sidedefs[line.leftSidedef].sector;
      if (!((front == first && back == second) ||
          (front == second && back == first))) {
        continue;
      }
      result.add(
        '${line.special}/${line.flags}/${_Planner._distanceSquared(player, map.vertices[line.v1], map.vertices[line.v2])}',
      );
    }
    return result;
  }

  int _nearbyDoorCount() {
    final _Point player = _Point(
      fixedToInt(game.player.x),
      fixedToInt(game.player.y),
    );
    var count = 0;
    for (final Linedef line in map.linedefs) {
      if (!_doorUseSpecials.contains(line.special)) continue;
      if (_Planner._distanceSquared(
            player,
            map.vertices[line.v1],
            map.vertices[line.v2],
          ) <=
          80 * 80) {
        count++;
      }
    }
    return count;
  }

  List<String> _nearbyDoorTopology() {
    final _Point player = _Point(
      fixedToInt(game.player.x),
      fixedToInt(game.player.y),
    );
    final List<String> result = <String>[];
    for (final Linedef line in map.linedefs) {
      if (!_doorUseSpecials.contains(line.special)) continue;
      final MapVertex a = map.vertices[line.v1];
      final MapVertex b = map.vertices[line.v2];
      final int distance2 = _Planner._distanceSquared(player, a, b);
      if (distance2 > 80 * 80) continue;
      final int cross =
          (b.x - a.x) * (player.y - a.y) - (b.y - a.y) * (player.x - a.x);
      final int front = map.sidedefs[line.rightSidedef].sector;
      final int back = line.leftSidedef == kNoSidedef
          ? -1
          : map.sidedefs[line.leftSidedef].sector;
      final SectorRuntime runtime = game.sectors.elementAt(back);
      result.add(
        '$front/$back/${cross <= 0 ? 'F' : 'B'}/$distance2/'
        '${fixedToInt(runtime.ceilingHeight - runtime.floorHeight)}/'
        '${runtime.hasMover}',
      );
    }
    return result;
  }

  int _sectorAt(_Point point) {
    int child = map.bspRoot;
    while ((child & kSubsectorBit) == 0) {
      final BspNode node = map.nodes[child];
      final int side =
          (point.x - node.x) * node.dy - (point.y - node.y) * node.dx;
      child = side >= 0 ? node.rightChild : node.leftChild;
    }
    final Subsector subsector = map.subsectors[child & ~kSubsectorBit];
    final Seg seg = map.segs[subsector.firstSeg];
    final Linedef line = map.linedefs[seg.linedef];
    final int sidedef = seg.side == 0 ? line.rightSidedef : line.leftSidedef;
    return map.sidedefs[sidedef].sector;
  }

  void _driveTo(
    _Point target, {
    bool settle = false,
    bool allowDoorRecovery = true,
    int? requiredSector,
  }) {
    var bestDistance2 = 0x7fffffffffffffff;
    var stalled = 0;
    for (var attempt = 0; attempt < 600; attempt++) {
      final int dx = toFixed(target.x) - game.player.x;
      final int dy = toFixed(target.y) - game.player.y;
      final int distance2 = dx * dx + dy * dy;
      final int tolerance = settle ? 4 : 28;
      final bool withinTarget =
          distance2 <= toFixed(tolerance) * toFixed(tolerance);
      final bool reachedSector =
          requiredSector == null ||
          game.playerSectorIndex == requiredSector ||
          distance2 <= toFixed(1) * toFixed(1);
      if (withinTarget &&
          reachedSector &&
          (!settle ||
              approxDistance(_estimatedMomX, _estimatedMomY) <= toFixed(1))) {
        return;
      }
      if (distance2 < bestDistance2) {
        bestDistance2 = distance2;
        stalled = 0;
      } else {
        stalled++;
      }
      final int desired = Trig.atan2(dy, dx);
      final int delta = angleDelta(desired, game.player.angle);
      final int turn = (delta >> 16).clamp(-8192, 8192);
      final int distance = approxDistance(dx, dy);
      final int speed = settle && withinTarget && reachedSector
          ? 0
          : math.min(distance, toFixed(4));
      final int cosine = Trig.cos(desired);
      final int sine = Trig.sin(desired);
      final int impulseX = fixedMul(speed, cosine) - _estimatedMomX;
      final int impulseY = fixedMul(speed, sine) - _estimatedMomY;
      int forward = _fixedToCommand(
        fixedMul(impulseX, cosine) + fixedMul(impulseY, sine),
      ).clamp(-25, 25);
      int side = _fixedToCommand(
        fixedMul(impulseX, sine) - fixedMul(impulseY, cosine),
      ).clamp(-25, 25);
      // Static actors still participate in collision when AI is disabled.
      // Attack along the route so the proof cannot phase through a blocking
      // E1M1 thing and remains an input-only traversal.
      int buttons = Buttons.attack;
      final int appliedTurn = turn;
      if (allowDoorRecovery &&
          (stalled == 10 || (attempt > 0 && attempt % 50 == 0))) {
        if (_tryNearbyDoors()) {
          wait(24);
          stalled = 0;
          continue;
        }
      }
      if (stalled >= 10) {
        forward = 0;
        side = 0;
      }
      _tick(
        TicCmd(
          forwardMove: forward,
          sideMove: side,
          angleTurn: appliedTurn,
          buttons: buttons,
        ),
      );
      if (stalled > 500) {
        throw StateError(
          'simulation remained blocked while following planned route',
        );
      }
    }
    throw StateError('simulation did not converge on a planned waypoint');
  }

  int _fixedToCommand(int fixed) => fixed >= 0
      ? (fixed + (_playerThrustPerCommand ~/ 2)) ~/ _playerThrustPerCommand
      : -((-fixed + (_playerThrustPerCommand ~/ 2)) ~/ _playerThrustPerCommand);

  bool _tryNearbyDoors() {
    final int before = doorOpenEvents;
    for (final int door in _nearbyDoorLines()) {
      _tryUseDoorLine(door);
      if (doorOpenEvents > before) return true;
    }
    return false;
  }

  void _tryUseDoorLine(int lineIndex) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    final double dx = (b.x - a.x).toDouble();
    final double dy = (b.y - a.y).toDouble();
    final double length2 = dx * dx + dy * dy;
    final double projection = length2 == 0
        ? 0.5
        : (((fixedToDouble(game.player.x) - a.x) * dx +
                      (fixedToDouble(game.player.y) - a.y) * dy) /
                  length2)
              .clamp(0.05, 0.95);
    for (final double along in <double>[
      projection,
      1 / 6,
      2 / 6,
      3 / 6,
      4 / 6,
      5 / 6,
    ]) {
      final int before = doorOpenEvents;
      final int targetX = doubleToFixed(a.x + dx * along);
      final int targetY = doubleToFixed(a.y + dy * along);
      final int desired = Trig.atan2(
        targetY - game.player.y,
        targetX - game.player.x,
      );
      final int delta = angleDelta(desired, game.player.angle);
      _tick(TicCmd(angleTurn: delta >> 16, buttons: Buttons.use));
      _tick(TicCmd.empty);
      if (doorOpenEvents > before) return;
    }
  }

  List<int> _nearbyDoorLines() {
    final _Point player = _Point(
      fixedToInt(game.player.x),
      fixedToInt(game.player.y),
    );
    final List<({int index, int distance2})> candidates =
        <({int index, int distance2})>[];
    for (var index = 0; index < map.linedefs.length; index++) {
      final Linedef line = map.linedefs[index];
      if (!_doorUseSpecials.contains(line.special)) continue;
      final MapVertex a = map.vertices[line.v1];
      final MapVertex b = map.vertices[line.v2];
      final int distance2 = _Planner._distanceSquared(player, a, b);
      if (distance2 > 64 * 64) continue;
      final int cross =
          (b.x - a.x) * (player.y - a.y) - (b.y - a.y) * (player.x - a.x);
      if (cross <= 0) candidates.add((index: index, distance2: distance2));
    }
    candidates.sort((a, b) => a.distance2.compareTo(b.distance2));
    return <int>[for (final candidate in candidates) candidate.index];
  }

  void useLine(int lineIndex, {bool untilComplete = false}) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    final int targetX = toFixed(a.x + b.x) ~/ 2;
    final int targetY = toFixed(a.y + b.y) ~/ 2;
    for (var attempt = 0; attempt < (untilComplete ? 20 : 2); attempt++) {
      final int desired = Trig.atan2(
        targetY - game.player.y,
        targetX - game.player.x,
      );
      final int delta = angleDelta(desired, game.player.angle);
      _tick(TicCmd(angleTurn: delta >> 16, buttons: Buttons.use));
      _tick(TicCmd.empty);
      if (!untilComplete || game.levelComplete) return;
    }
    if (untilComplete && !game.levelComplete) {
      throw StateError('exit use did not complete the level');
    }
  }

  void crossLine(int lineIndex) {
    final Linedef line = map.linedefs[lineIndex];
    final MapVertex a = map.vertices[line.v1];
    final MapVertex b = map.vertices[line.v2];
    final double dx = (b.x - a.x).toDouble();
    final double dy = (b.y - a.y).toDouble();
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) throw StateError('zero-length walk trigger');
    _driveTo(
      _Point(
        ((a.x + b.x) / 2 - dy * 32 / length).round(),
        ((a.y + b.y) / 2 + dx * 32 / length).round(),
      ),
      settle: true,
    );
  }

  void wait(int tics) {
    for (var i = 0; i < tics; i++) {
      _tick(TicCmd.empty);
    }
  }

  void waitForSectorDamage() {
    final int special = map.sectors[game.playerSectorIndex].special;
    if (!_Planner._damagingSectors.contains(special)) {
      throw StateError('planned damaging-sector waypoint was not reached');
    }
    final int health = game.player.health;
    for (var i = 0; i < 40 && game.player.health == health; i++) {
      _tick(TicCmd.empty);
    }
    if (game.player.health >= health) {
      throw StateError('damaging sector did not reduce player health');
    }
    damageObserved = true;
  }

  void _tick(TicCmd command) {
    final int beforeX = game.player.x;
    final int beforeY = game.player.y;
    final Stopwatch stopwatch = Stopwatch()..start();
    game.runTic(command);
    stopwatch.stop();
    commands.add(command);
    tickMicros.add(stopwatch.elapsedMicroseconds);
    _estimatedMomX = fixedMul(game.player.x - beforeX, 0xe800);
    _estimatedMomY = fixedMul(game.player.y - beforeY, 0xe800);

    for (final SoundEvent event in game.consumeSoundJournal()) {
      if (event.soundId == 'DSDOROPN') {
        doorOpened = true;
        doorOpenEvents++;
      }
      if (event.soundId == 'DSPSTART') liftActivated = true;
    }
    final List<int> floors = <int>[for (final s in game.sectors) s.floorHeight];
    for (var i = 0; i < floors.length; i++) {
      if (floors[i] != _lastLiftFloors[i] && liftActivated) liftMoved = true;
    }
    _lastLiftFloors = floors;

    final PlayerView player = game.player;
    if (player.x == _lastX && player.y == _lastY) {
      _stationary++;
      maxStationaryTics = math.max(maxStationaryTics, _stationary);
    } else {
      _stationary = 0;
    }
    _lastX = player.x;
    _lastY = player.y;
    final SectorRuntime sector = game.sectors.elementAt(game.playerSectorIndex);
    if (player.z != sector.floorHeight) floorInvariantHeld = false;
    if (_insideBlockingWall(player, game.sectors.toList())) {
      wallInvariantHeld = false;
    }
  }

  bool _insideBlockingWall(PlayerView player, List<SectorRuntime> sectors) {
    for (final Linedef line in map.linedefs) {
      final MapVertex a = map.vertices[line.v1];
      final MapVertex b = map.vertices[line.v2];
      if (_fixedDistanceSquaredToSegment(
            player.x,
            player.y,
            toFixed(a.x),
            toFixed(a.y),
            toFixed(b.x),
            toFixed(b.y),
          ) >=
          16 * 16) {
        continue;
      }
      if (line.blocksMovement || !line.isTwoSided) return true;
      final int front = map.sidedefs[line.rightSidedef].sector;
      final int back = map.sidedefs[line.leftSidedef].sector;
      final int bottom = math.max(
        sectors[front].floorHeight,
        sectors[back].floorHeight,
      );
      final int top = math.min(
        sectors[front].ceilingHeight,
        sectors[back].ceilingHeight,
      );
      if (top - bottom < toFixed(56) || player.z < bottom - toFixed(24)) {
        return true;
      }
    }
    return false;
  }

  static double _fixedDistanceSquaredToSegment(
    int px,
    int py,
    int ax,
    int ay,
    int bx,
    int by,
  ) {
    final double pointX = fixedToDouble(px);
    final double pointY = fixedToDouble(py);
    final double startX = fixedToDouble(ax);
    final double startY = fixedToDouble(ay);
    final double dx = fixedToDouble(bx - ax);
    final double dy = fixedToDouble(by - ay);
    final double lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) {
      final double ox = pointX - startX;
      final double oy = pointY - startY;
      return ox * ox + oy * oy;
    }
    final double projection =
        (((pointX - startX) * dx + (pointY - startY) * dy) / lengthSquared)
            .clamp(0, 1);
    final double qx = startX + dx * projection;
    final double qy = startY + dy * projection;
    final double ox = pointX - qx;
    final double oy = pointY - qy;
    return ox * ox + oy * oy;
  }
}

final class _RouteCandidate {
  const _RouteCandidate(this.line, this.path, this.target);
  final int line;
  final List<_Point> path;
  final _Point target;
}

final class _Point {
  const _Point(this.x, this.y);
  final int x;
  final int y;
  int distance2(_Point other) {
    final int dx = x - other.x;
    final int dy = y - other.y;
    return dx * dx + dy * dy;
  }
}

final class _GridKey {
  const _GridKey(this.x, this.y);
  final int x;
  final int y;
  @override
  bool operator ==(Object other) =>
      other is _GridKey && x == other.x && y == other.y;
  @override
  int get hashCode => Object.hash(x, y);
}
