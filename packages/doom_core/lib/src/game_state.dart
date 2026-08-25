import 'package:doom_wad/doom_wad.dart';

import 'angles.dart';
import 'config.dart';
import 'fixed.dart';
import 'map_runtime.dart';
import 'mobj.dart';
import 'mobj_info.dart';
import 'random.dart';
import 'sector_runtime.dart';
import 'specials.dart';
import 'ticcmd.dart';
import 'views.dart';

const int _playerRadius = 16 * kFracUnit;
const int _maxStep = 24 * kFracUnit;

/// Integer-only 35 Hz game simulation. Its iteration order is spawn order;
/// removal is deferred to the end of each tic so callbacks cannot reorder it.
class GameState {
  GameState._(this._runtime, this.config, int seed)
    : _random = DoomRandom(index: seed) {
    _spawnMapThings();
  }

  static GameState start(MapData map, GameConfig config, {int seed = 0}) =>
      GameState._(MapRuntime(map), config, seed);

  final MapRuntime _runtime;
  final GameConfig config;
  final DoomRandom _random;
  final List<Mobj> _mobjs = <Mobj>[];
  final List<SectorChange> _changes = <SectorChange>[];
  int _tic = 0;
  int _nextId = 1;
  late Mobj _playerMobj;
  int _health = 100, _armor = 0, _bullets = 50, _shells = 0;
  Weapon _weapon = Weapon.pistol;
  final Set<Weapon> _ownedWeapons = <Weapon>{Weapon.fist, Weapon.pistol};
  final Set<Key> _keys = <Key>{};
  final Set<int> _foundSecrets = <int>{};
  final Set<int> _activatedOnceLines = <int>{};
  int _secrets = 0;
  bool _levelComplete = false;
  bool _secretExit = false;
  int _bob = 0;
  bool _useHeld = false;

  int get tic => _tic;
  Iterable<MobjView> get mobjs =>
      _mobjs.where((Mobj m) => !m.removed).map(_view);
  Iterable<SectorRuntime> get sectors => _runtime.sectors;
  List<SectorChange> get changeJournal =>
      List<SectorChange>.unmodifiable(_changes);
  List<SectorChange> consumeChangeJournal() {
    final List<SectorChange> result = List<SectorChange>.unmodifiable(_changes);
    _changes.clear();
    return result;
  }

  int get secretsFound => _secrets;
  bool get levelComplete => _levelComplete;
  bool get usedSecretExit => _secretExit;
  PlayerView get player => PlayerView(
    x: _playerMobj.x,
    y: _playerMobj.y,
    z: _playerMobj.z,
    angle: _playerMobj.angle,
    viewZ: _playerMobj.viewZ + _bob,
    health: _health,
    armor: _armor,
    ammo: Ammo(bullets: _bullets, shells: _shells),
    weapon: _weapon,
    bob: _bob,
    keys: Set<Key>.unmodifiable(_keys),
  );

  void runTic(TicCmd cmd) {
    _tic++;
    _tickMovers();
    if (_health > 0) _tickPlayer(cmd);
    _tickSectorEffects();
    if (config.monsters) _tickActors();
    _collectPickups();
    _mobjs.removeWhere((Mobj m) => m.removed);
  }

  void _spawnMapThings() {
    for (final Thing thing in _runtime.map.things) {
      if (!_enabledForSkill(thing) ||
          (thing.flags & ThingFlags.multiplayerOnly) != 0) {
        continue;
      }
      final MobjInfo? info = _infoForEdNum(thing.type);
      if (thing.type == 1) {
        _playerMobj = _add(_playerInfo, thing.x, thing.y, thing.angle, 100);
      } else if (info != null) {
        _add(info, thing.x, thing.y, thing.angle, info.spawnHealth);
      }
    }
    if (_mobjs.where((Mobj m) => identical(m.info, _playerInfo)).isEmpty) {
      _playerMobj = _add(_playerInfo, 0, 0, 0, 100);
    }
  }

  bool _enabledForSkill(Thing thing) {
    final int flag = switch (config.skill) {
      Skill.easy => ThingFlags.easy,
      Skill.medium => ThingFlags.medium,
      Skill.hard => ThingFlags.hard,
    };
    return thing.flags == 0 || (thing.flags & flag) != 0;
  }

  Mobj _add(MobjInfo info, int x, int y, int degrees, int health) {
    final int fx = toFixed(x), fy = toFixed(y);
    final int sector = _runtime.sectorAt(fx, fy);
    final Mobj m = Mobj(
      id: _nextId++,
      info: info,
      x: fx,
      y: fy,
      z: _runtime.sectors[sector].floorHeight,
      angle: degreesToAngle(degrees),
      health: health,
      sectorIndex: sector,
    );
    m.floorZ = _runtime.sectors[sector].floorHeight;
    m.ceilingZ = _runtime.sectors[sector].ceilingHeight;
    _mobjs.add(m);
    return m;
  }

  void _tickPlayer(TicCmd cmd) {
    _playerMobj.angle = normalizeAngle(
      _playerMobj.angle + (cmd.angleTurn << 16),
    );
    if (cmd.changingWeapon) _selectWeapon(cmd.requestedWeapon);
    final int forward = toFixed(cmd.forwardMove);
    final int side = toFixed(cmd.sideMove);
    _playerMobj.thrust(_playerMobj.angle, forward);
    _playerMobj.thrust(normalizeAngle(_playerMobj.angle - kAng90), side);
    _tryMove(_playerMobj, _playerMobj.momX, _playerMobj.momY);
    _playerMobj.momX = fixedMul(_playerMobj.momX, 0xe800);
    _playerMobj.momY = fixedMul(_playerMobj.momY, 0xe800);
    _bob =
        ((approxDistance(_playerMobj.momX, _playerMobj.momY) >> 2) *
            Trig.sin(_tic * 0x10000000)) >>
        kFracBits;
    if (cmd.using && !_useHeld) _useLine();
    _useHeld = cmd.using;
    if (cmd.attacking) _playerAttack();
  }

  void _selectWeapon(int slot) {
    final Weapon requested = switch (slot) {
      0 => Weapon.fist,
      1 => Weapon.pistol,
      2 => Weapon.shotgun,
      3 => Weapon.chaingun,
      _ => _weapon,
    };
    if (!_ownedWeapons.contains(requested)) return;
    _weapon = requested;
  }

  void _playerAttack() {
    if (_weapon == Weapon.shotgun && _shells == 0) {
      _weapon = Weapon.pistol;
      return;
    }
    if ((_weapon == Weapon.pistol || _weapon == Weapon.chaingun) &&
        _bullets == 0) {
      _weapon = Weapon.fist;
      return;
    }
    switch (_weapon) {
      case Weapon.fist:
        _hitscan(64 * kFracUnit, 2 + (_random.next() % 10));
      case Weapon.pistol:
        _bullets--;
        _hitscan(1024 * kFracUnit, 5 * (1 + (_random.next() % 3)));
      case Weapon.chaingun:
        _bullets--;
        _hitscan(1024 * kFracUnit, 5 * (1 + (_random.next() % 3)));
      case Weapon.shotgun:
        _shells--;
        for (int i = 0; i < 7; i++) {
          _hitscan(
            1024 * kFracUnit,
            5 * (1 + (_random.next() % 3)),
            spread: _random.nextSigned() << 17,
          );
        }
    }
    _shootSpecialLine();
  }

  void _hitscan(int range, int damage, {int spread = 0}) {
    Mobj? target;
    int best = range;
    final int angle = normalizeAngle(_playerMobj.angle + spread);
    for (final Mobj m in _mobjs) {
      if (!m.isShootable || m.removed || identical(m, _playerMobj)) continue;
      final int dx = m.x - _playerMobj.x, dy = m.y - _playerMobj.y;
      final int distance = approxDistance(dx, dy);
      if (distance > best) continue;
      final int delta = angleDelta(Trig.atan2(dy, dx), angle).abs();
      if (delta < 0x06000000 && _hasSight(_playerMobj, m)) {
        target = m;
        best = distance;
      }
    }
    if (target != null) _damage(target, damage, _playerMobj);
  }

  bool _tryMove(Mobj m, int dx, int dy, {bool allowSlide = true}) {
    if (dx == 0 && dy == 0) return true;
    // A broadphase is not a substitute for a trace: momentum can cross a thin
    // line in one tic. Split into <=8-unit traces so a wall cannot be tunneled.
    final int magnitude = approxDistance(dx, dy);
    final int maxTrace = toFixed(8);
    if (magnitude > maxTrace) {
      final int parts = (magnitude + maxTrace - 1) ~/ maxTrace;
      final int stepX = dx ~/ parts;
      final int stepY = dy ~/ parts;
      int remainderX = dx - stepX * parts;
      int remainderY = dy - stepY * parts;
      for (int i = 0; i < parts; i++) {
        final int partX = stepX + (remainderX == 0 ? 0 : remainderX.sign);
        final int partY = stepY + (remainderY == 0 ? 0 : remainderY.sign);
        remainderX -= remainderX.sign;
        remainderY -= remainderY.sign;
        if (!_tryMove(m, partX, partY, allowSlide: allowSlide)) return false;
      }
      return true;
    }
    final int nx = wrap32(m.x + dx), ny = wrap32(m.y + dy);
    final int radius = m.radius;
    for (final int i in _runtime.candidateLines(nx, ny, radius)) {
      if (_runtime.blocksAt(i, nx, ny, radius, m.z, m.height)) {
        // Classic-feeling wall slide: discard the velocity axis that crosses
        // the blocking line most directly, then retry once.
        final Linedef l = _runtime.map.linedefs[i];
        final MapVertex a = _runtime.map.vertices[l.v1],
            b = _runtime.map.vertices[l.v2];
        final int lx = b.x - a.x, ly = b.y - a.y;
        if (!allowSlide || dx == 0 || dy == 0) {
          return false;
        }
        if (lx.abs() > ly.abs()) {
          return _tryMove(m, dx, 0, allowSlide: false);
        }
        return _tryMove(m, 0, dy, allowSlide: false);
      }
    }
    for (final Mobj other in _mobjs) {
      if (identical(other, m) ||
          other.removed ||
          !other.isSolid ||
          identical(other, m.owner) ||
          (m.isMissile && identical(other, m.target))) {
        continue;
      }
      if (m.z >= other.z + other.height || other.z >= m.z + m.height) continue;
      final int combined = m.radius + other.radius;
      final int ox = nx - other.x, oy = ny - other.y;
      if (ox * ox + oy * oy < combined * combined) return false;
    }
    int sector = m.sectorIndex;
    for (int i = 0; i < _runtime.map.linedefs.length; i++) {
      final Linedef line = _runtime.map.linedefs[i];
      if (!line.isTwoSided || !_lineCrossed(m.x, m.y, nx, ny, line)) {
        continue;
      }
      final MapVertex vertexA = _runtime.map.vertices[line.v1];
      final MapVertex vertexB = _runtime.map.vertices[line.v2];
      if (!_segmentsIntersect(
        m.x,
        m.y,
        nx,
        ny,
        toFixed(vertexA.x),
        toFixed(vertexA.y),
        toFixed(vertexB.x),
        toFixed(vertexB.y),
      )) {
        continue;
      }
      final int front = _runtime.frontSector(line);
      final int? back = _runtime.backSector(line);
      if (sector == front && back != null) {
        sector = back;
      } else if (sector == back) {
        sector = front;
      }
    }
    final SectorRuntime dest = _runtime.sectors[sector];
    if (dest.floorHeight - m.floorZ > _maxStep ||
        ((m.flags & MobjFlags.dropOff) == 0 &&
            m.floorZ - dest.floorHeight > _maxStep) ||
        dest.ceilingHeight - dest.floorHeight < m.height) {
      return false;
    }
    final int oldX = m.x, oldY = m.y;
    m.x = nx;
    m.y = ny;
    m.sectorIndex = sector;
    m.floorZ = dest.floorHeight;
    m.ceilingZ = dest.ceilingHeight;
    if (m.z < m.floorZ) {
      m.z = m.floorZ;
    }
    if (identical(m, _playerMobj)) _crossSpecials(oldX, oldY, nx, ny);
    return true;
  }

  bool _lineCrossed(int oldX, int oldY, int newX, int newY, Linedef line) {
    final MapVertex a = _runtime.map.vertices[line.v1];
    final MapVertex b = _runtime.map.vertices[line.v2];
    int side(int x, int y) =>
        (x - toFixed(a.x)) * toFixed(b.y - a.y) -
        (y - toFixed(a.y)) * toFixed(b.x - a.x);
    final int before = side(oldX, oldY);
    final int after = side(newX, newY);
    return (before < 0 && after >= 0) || (before > 0 && after <= 0);
  }

  void _crossSpecials(int oldX, int oldY, int newX, int newY) {
    for (
      int lineIndex = 0;
      lineIndex < _runtime.map.linedefs.length;
      lineIndex++
    ) {
      final Linedef line = _runtime.map.linedefs[lineIndex];
      if (line.special == 0) continue;
      final MapVertex a = _runtime.map.vertices[line.v1];
      final MapVertex b = _runtime.map.vertices[line.v2];
      if (!_lineCrossed(oldX, oldY, newX, newY, line) ||
          !_segmentsIntersect(
            oldX,
            oldY,
            newX,
            newY,
            toFixed(a.x),
            toFixed(a.y),
            toFixed(b.x),
            toFixed(b.y),
          )) {
        continue;
      }
      if (_isWalkLiftSpecial(line.special)) {
        _activateLift(line);
      }
      if (_isWalkFloorSpecial(line.special)) {
        _activateFloor(line);
      }
      if (line.special == LineSpecial.exitWalkOnce ||
          line.special == LineSpecial.secretExitWalkOnce) {
        _completeExit(
          lineIndex,
          secret: line.special == LineSpecial.secretExitWalkOnce,
        );
      }
    }
  }

  void _useLine() {
    final int range = toFixed(80);
    final int rayX =
        _playerMobj.x + fixedMul(range, Trig.cos(_playerMobj.angle));
    final int rayY =
        _playerMobj.y + fixedMul(range, Trig.sin(_playerMobj.angle));
    Linedef? selected;
    int selectedIndex = -1;
    int selectedDistance = 0x7fffffffffffffff;
    for (int i = 0; i < _runtime.map.linedefs.length; i++) {
      final Linedef line = _runtime.map.linedefs[i];
      final MapVertex a = _runtime.map.vertices[line.v1];
      final MapVertex b = _runtime.map.vertices[line.v2];
      if (!_segmentsIntersect(
        _playerMobj.x,
        _playerMobj.y,
        rayX,
        rayY,
        toFixed(a.x),
        toFixed(a.y),
        toFixed(b.x),
        toFixed(b.y),
      )) {
        continue;
      }
      final int distance = _distanceSquaredToLineMidpoint(line);
      if (distance < selectedDistance) {
        selectedDistance = distance;
        selected = line;
        selectedIndex = i;
      }
    }
    if (selected == null) return;
    if (!_isUseSpecial(selected.special)) return;
    if (_isDoorSpecial(selected.special)) _tryActivateDoor(selected);
    if (_isUseLiftSpecial(selected.special)) _activateLift(selected);
    if (selected.special == LineSpecial.exitSwitchOnce ||
        selected.special == LineSpecial.secretExitSwitchOnce) {
      if (!_isOnFrontSide(selected, _playerMobj.x, _playerMobj.y)) return;
      _completeExit(
        selectedIndex,
        secret: selected.special == LineSpecial.secretExitSwitchOnce,
      );
    }
  }

  bool _isOnFrontSide(Linedef line, int x, int y) {
    final MapVertex a = _runtime.map.vertices[line.v1];
    final MapVertex b = _runtime.map.vertices[line.v2];
    final int cross =
        toFixed(b.x - a.x) * (y - toFixed(a.y)) -
        toFixed(b.y - a.y) * (x - toFixed(a.x));
    return cross <= 0;
  }

  void _completeExit(int lineIndex, {required bool secret}) {
    if (_levelComplete) return;
    if (!_activatedOnceLines.add(lineIndex)) return;
    _levelComplete = true;
    _secretExit = secret;
  }

  void _shootSpecialLine() {
    final int range = toFixed(1024);
    final int rayX =
        _playerMobj.x + fixedMul(range, Trig.cos(_playerMobj.angle));
    final int rayY =
        _playerMobj.y + fixedMul(range, Trig.sin(_playerMobj.angle));
    Linedef? selected;
    int selectedDistance = 0x7fffffffffffffff;
    for (final Linedef line in _runtime.map.linedefs) {
      final MapVertex a = _runtime.map.vertices[line.v1];
      final MapVertex b = _runtime.map.vertices[line.v2];
      if (!_segmentsIntersect(
        _playerMobj.x,
        _playerMobj.y,
        rayX,
        rayY,
        toFixed(a.x),
        toFixed(a.y),
        toFixed(b.x),
        toFixed(b.y),
      )) {
        continue;
      }
      final int distance = _distanceSquaredToLineMidpoint(line);
      if (distance < selectedDistance) {
        selectedDistance = distance;
        selected = line;
      }
    }
    if (selected?.special == LineSpecial.floorRaise24) {
      _activateFloor(selected!);
    }
  }

  int _distanceSquaredToLineMidpoint(Linedef line) {
    final MapVertex a = _runtime.map.vertices[line.v1];
    final MapVertex b = _runtime.map.vertices[line.v2];
    final int dx = _playerMobj.x - toFixed(a.x + b.x) ~/ 2;
    final int dy = _playerMobj.y - toFixed(a.y + b.y) ~/ 2;
    return dx * dx + dy * dy;
  }

  bool _tryActivateDoor(Linedef line) {
    final Key? required = _requiredKey(line.special);
    if (required != null && !_keys.contains(required)) return false;
    _activateDoor(line);
    return true;
  }

  void _activateDoor(Linedef line) {
    // tag 0 manual doors affect the adjacent back sector; classification comes
    // from special, never from the tag.
    final int? back = _runtime.backSector(line);
    final List<int> targets = line.tag == 0
        ? (back == null ? <int>[] : <int>[back])
        : <int>[
            for (int i = 0; i < _runtime.sectors.length; i++)
              if (_runtime.sectors[i].staticData.tag == line.tag) i,
          ];
    for (final int index in targets) {
      final SectorRuntime sector = _runtime.sectors[index];
      sector.activeMover ??= _DoorMover(
        sector,
        _doorOpenTop(index),
        closeAfterWait: !_doorStaysOpen(line.special),
        obstructed: (int nextCeiling) =>
            _sectorObstructed(index, ceiling: nextCeiling),
      );
    }
  }

  void _activateLift(Linedef line) {
    final int? back = _runtime.backSector(line);
    final List<int> targets = line.tag == 0
        ? (back == null ? <int>[] : <int>[back])
        : <int>[
            for (int i = 0; i < _runtime.sectors.length; i++)
              if (_runtime.sectors[i].staticData.tag == line.tag) i,
          ];
    for (final int index in targets) {
      final SectorRuntime sector = _runtime.sectors[index];
      sector.activeMover ??= _LiftMover(sector, _lowestNeighborFloor(index));
    }
  }

  void _activateFloor(Linedef line) {
    final List<int> targets = <int>[
      for (int i = 0; i < _runtime.sectors.length; i++)
        if (_runtime.sectors[i].staticData.tag == line.tag && line.tag != 0) i,
    ];
    for (final int index in targets) {
      final SectorRuntime sector = _runtime.sectors[index];
      final int target = switch (line.special) {
        LineSpecial.floorRaise24 => sector.floorHeight + toFixed(24),
        LineSpecial.floorRaiseToLowestCeiling =>
          _lowestNeighborCeiling(index) - toFixed(8),
        _ => sector.floorHeight,
      };
      sector.activeMover ??= _FloorMover(
        sector,
        target,
        obstructed: (int nextFloor) =>
            _sectorObstructed(index, floor: nextFloor),
      );
    }
  }

  bool _sectorObstructed(int index, {int? floor, int? ceiling}) {
    final SectorRuntime sector = _runtime.sectors[index];
    final int nextFloor = floor ?? sector.floorHeight;
    final int nextCeiling = ceiling ?? sector.ceilingHeight;
    for (final Mobj m in _mobjs) {
      if (m.removed || !m.isSolid || m.sectorIndex != index) continue;
      if (m.z < nextCeiling &&
          m.z + m.height > nextFloor &&
          nextCeiling - nextFloor < m.height) {
        return true;
      }
      if (m.z + m.height > nextCeiling) return true;
    }
    return false;
  }

  int _lowestNeighborFloor(int index) {
    int floor = _runtime.sectors[index].floorHeight;
    for (final int lineIndex in _runtime.sectors[index].touchingLinedefs) {
      final Linedef line = _runtime.map.linedefs[lineIndex];
      final int? other = _runtime.frontSector(line) == index
          ? _runtime.backSector(line)
          : _runtime.frontSector(line);
      if (other != null && _runtime.sectors[other].floorHeight < floor) {
        floor = _runtime.sectors[other].floorHeight;
      }
    }
    return floor;
  }

  int _lowestNeighborCeiling(int index) {
    int ceiling = _runtime.sectors[index].ceilingHeight;
    for (final int lineIndex in _runtime.sectors[index].touchingLinedefs) {
      final Linedef line = _runtime.map.linedefs[lineIndex];
      final int? other = _runtime.frontSector(line) == index
          ? _runtime.backSector(line)
          : _runtime.frontSector(line);
      if (other != null && _runtime.sectors[other].ceilingHeight < ceiling) {
        ceiling = _runtime.sectors[other].ceilingHeight;
      }
    }
    return ceiling;
  }

  int _doorOpenTop(int index) {
    int top = 0x7fffffff;
    for (final int li in _runtime.sectors[index].touchingLinedefs) {
      final Linedef line = _runtime.map.linedefs[li];
      final int? other = _runtime.frontSector(line) == index
          ? _runtime.backSector(line)
          : _runtime.frontSector(line);
      if (other != null && _runtime.sectors[other].ceilingHeight < top) {
        top = _runtime.sectors[other].ceilingHeight;
      }
    }
    if (top == 0x7fffffff) top = _runtime.sectors[index].ceilingHeight;
    return top - toFixed(4);
  }

  void _tickMovers() {
    for (final SectorRuntime s in _runtime.sectors) {
      final SectorMover? mover = s.activeMover;
      if (mover != null) {
        final int oldFloor = s.floorHeight, oldCeiling = s.ceilingHeight;
        mover.tick();
        if (oldFloor != s.floorHeight) {
          for (final Mobj m in _mobjs) {
            if (m.removed || m.sectorIndex != s.index) continue;
            if (m.z <= oldFloor) m.z = s.floorHeight;
            m.floorZ = s.floorHeight;
          }
          _changes.add(SectorChange(s.index, PlaneKind.floor, s.floorHeight));
        }
        if (oldCeiling != s.ceilingHeight) {
          for (final Mobj m in _mobjs) {
            if (!m.removed && m.sectorIndex == s.index) {
              m.ceilingZ = s.ceilingHeight;
            }
          }
          _changes.add(
            SectorChange(s.index, PlaneKind.ceiling, s.ceilingHeight),
          );
        }
        if (mover.finished) {
          s.activeMover = null;
        }
      }
    }
  }

  void _tickSectorEffects() {
    final SectorRuntime sector = _runtime.sectors[_playerMobj.sectorIndex];
    switch (sector.staticData.special) {
      case SectorSpecial.damage5:
        if (_tic % 32 == 0) _damagePlayer(5);
      case SectorSpecial.damage10:
        if (_tic % 32 == 0) _damagePlayer(10);
      case SectorSpecial.damage20:
        if (_tic % 32 == 0) _damagePlayer(20);
      case SectorSpecial.secret:
        if (_foundSecrets.add(sector.index)) _secrets++;
    }
    for (final SectorRuntime item in _runtime.sectors) {
      final int old = item.lightLevel;
      final int special = item.staticData.special;
      if (special == SectorSpecial.lightFlicker ||
          special == SectorSpecial.lightFlickerSync) {
        item.lightLevel = (_random.next() & 3) == 0
            ? 64
            : item.staticData.lightLevel;
      } else if (special == SectorSpecial.strobeFast ||
          special == SectorSpecial.strobeFastSync ||
          special == SectorSpecial.strobeFastSync2) {
        item.lightLevel = (_tic % 15) < 5 ? 32 : item.staticData.lightLevel;
      } else if (special == SectorSpecial.strobeSlow ||
          special == SectorSpecial.strobeSlowSync) {
        item.lightLevel = (_tic % 35) < 5 ? 32 : item.staticData.lightLevel;
      } else if (special == SectorSpecial.glow) {
        item.lightLevel =
            128 + ((_tic % 64) < 32 ? (_tic % 32) * 2 : (63 - (_tic % 64)) * 2);
      }
      if (old != item.lightLevel) {
        _changes.add(
          SectorChange(item.index, PlaneKind.light, item.lightLevel),
        );
      }
    }
  }

  void _tickActors() {
    final List<Mobj> actors = List<Mobj>.of(_mobjs);
    for (final Mobj m in actors) {
      if (m.removed || !m.info.isMonster || m.health <= 0) continue;
      final int distance = approxDistance(
        _playerMobj.x - m.x,
        _playerMobj.y - m.y,
      );
      if (m.target == null &&
          distance < toFixed(512) &&
          _hasSight(m, _playerMobj)) {
        m.target = _playerMobj;
        m.state = MobjState.see;
      }
      if (m.target == null) continue;
      m.angle = Trig.atan2(_playerMobj.y - m.y, _playerMobj.x - m.x);
      if (distance < toFixed(64)) {
        _damagePlayer(3 + (_random.next() % 8));
        continue;
      }
      if ((m.info.id == MobjType.possessed || m.info.id == MobjType.shotguy) &&
          distance < toFixed(1024) &&
          _tic % 20 == 0 &&
          _hasSight(m, _playerMobj)) {
        final int pellets = m.info.id == MobjType.shotguy ? 3 : 1;
        for (int i = 0; i < pellets; i++) {
          _damagePlayer(3 * (1 + (_random.next() % 5)));
        }
        continue;
      }
      if (m.info.id == MobjType.troop &&
          distance < toFixed(384) &&
          (_tic % 20 == 0)) {
        _spawnImpShot(m);
        continue;
      }
      if (_tic % 4 == 0) {
        m.moveDir = ((normalizeAngle(m.angle + (kAng45 ~/ 2))) >> 29) & 7;
        _tryMove(
          m,
          fixedMul(toFixed(m.info.speed), Trig.cos(kDirAngles[m.moveDir])),
          fixedMul(toFixed(m.info.speed), Trig.sin(kDirAngles[m.moveDir])),
        );
      }
    }
    for (final Mobj m in List<Mobj>.of(_mobjs)) {
      if (m.isMissile && !m.removed) {
        _tickMissile(m);
      }
    }
  }

  void _spawnImpShot(Mobj source) {
    final Mobj shot = _add(
      _impShotInfo,
      fixedToInt(source.x),
      fixedToInt(source.y),
      0,
      1,
    );
    shot.x = source.x;
    shot.y = source.y;
    shot.z = source.z + toFixed(32);
    shot.angle = source.angle;
    shot.momX = fixedMul(toFixed(10), Trig.cos(shot.angle));
    shot.momY = fixedMul(toFixed(10), Trig.sin(shot.angle));
    shot.target = source.target;
    shot.owner = source;
  }

  void _tickMissile(Mobj m) {
    if (!_tryMove(m, m.momX, m.momY)) {
      m.removed = true;
      return;
    }
    if (identical(m.target, _playerMobj) &&
        approxDistance(m.x - _playerMobj.x, m.y - _playerMobj.y) <
            _playerRadius + m.radius) {
      _damagePlayer(3 + (_random.next() % 24));
      m.removed = true;
    }
  }

  bool _hasSight(Mobj a, Mobj b) {
    // Map loading already bounds the linedef count. Sight must scan the whole
    // bounded set: a safety cap that returns true would turn large maps into a
    // fail-open wallhack.
    for (int i = 0; i < _runtime.map.linedefs.length; i++) {
      final Linedef l = _runtime.map.linedefs[i];
      if (_segmentsIntersect(
        a.x,
        a.y,
        b.x,
        b.y,
        toFixed(_runtime.map.vertices[l.v1].x),
        toFixed(_runtime.map.vertices[l.v1].y),
        toFixed(_runtime.map.vertices[l.v2].x),
        toFixed(_runtime.map.vertices[l.v2].y),
      )) {
        if (l.blocksMovement || !l.isTwoSided) return false;
        final ({int bottom, int top})? opening = _runtime.openingFor(i);
        if (opening == null) return false;
        final int lowEye = a.viewZ < b.viewZ ? a.viewZ : b.viewZ;
        final int highEye = a.viewZ > b.viewZ ? a.viewZ : b.viewZ;
        if (opening.top <= lowEye || opening.bottom >= highEye) return false;
      }
    }
    return true;
  }

  bool _segmentsIntersect(
    int ax,
    int ay,
    int bx,
    int by,
    int cx,
    int cy,
    int dx,
    int dy,
  ) {
    int cross(int x1, int y1, int x2, int y2, int x3, int y3) =>
        (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
    final int a = cross(ax, ay, bx, by, cx, cy),
        b = cross(ax, ay, bx, by, dx, dy),
        c = cross(cx, cy, dx, dy, ax, ay),
        d = cross(cx, cy, dx, dy, bx, by);
    if (!(((a >= 0 && b <= 0) || (a <= 0 && b >= 0)) &&
        ((c >= 0 && d <= 0) || (c <= 0 && d >= 0)))) {
      return false;
    }
    if (a == 0 && b == 0 && c == 0 && d == 0) {
      bool overlaps(int a1, int a2, int b1, int b2) {
        final int minA = a1 < a2 ? a1 : a2;
        final int maxA = a1 > a2 ? a1 : a2;
        final int minB = b1 < b2 ? b1 : b2;
        final int maxB = b1 > b2 ? b1 : b2;
        return minA <= maxB && minB <= maxA;
      }

      return overlaps(ax, bx, cx, dx) && overlaps(ay, by, cy, dy);
    }
    return true;
  }

  void _damage(Mobj target, int damage, Mobj source) {
    target.health -= damage;
    target.target = source;
    if (target.health <= 0) {
      target.health = 0;
      target.state = MobjState.death;
      target.spriteFrame = 2;
      target.flags |= MobjFlags.corpse;
      target.flags &= ~MobjFlags.shootable;
      if (target.info.id == MobjType.barrel) _explodeBarrel(target, source);
    } else if (_random.chance(target.info.painChance)) {
      target.state = MobjState.pain;
      target.spriteFrame = 1;
    }
  }

  void _damagePlayer(int damage) {
    final int possibleSave = damage ~/ 3;
    final int saved = _armor < possibleSave ? _armor : possibleSave;
    _armor -= saved;
    _health -= damage - saved;
    if (_health < 0) {
      _health = 0;
    }
    _playerMobj.health = _health;
    if (_health == 0) {
      _playerMobj.flags &= ~MobjFlags.shootable;
      _playerMobj.state = MobjState.death;
    }
  }

  void _explodeBarrel(Mobj barrel, Mobj source) {
    for (final Mobj other in List<Mobj>.of(_mobjs)) {
      if (identical(other, barrel) || other.removed || !other.isShootable) {
        continue;
      }
      final int distance = approxDistance(
        other.x - barrel.x,
        other.y - barrel.y,
      );
      if (distance >= toFixed(128)) continue;
      final int damage = 128 - fixedToInt(distance);
      if (identical(other, _playerMobj)) {
        _damagePlayer(damage);
      } else {
        _damage(other, damage, source);
      }
    }
  }

  void _collectPickups() {
    for (final Mobj m in _mobjs) {
      if (m.removed ||
          !m.info.isPickup ||
          approxDistance(m.x - _playerMobj.x, m.y - _playerMobj.y) >
              _playerRadius + m.radius) {
        continue;
      }
      switch (m.info.id) {
        case MobjType.clip:
          _bullets += 10;
        case MobjType.shotgun:
          _shells += 8;
          _ownedWeapons.add(Weapon.shotgun);
          _weapon = Weapon.shotgun;
        case MobjType.chaingun:
          _bullets += 20;
          _ownedWeapons.add(Weapon.chaingun);
          _weapon = Weapon.chaingun;
        case MobjType.megaHealth:
          _health = (_health + 100 > 200) ? 200 : _health + 100;
        case MobjType.misc0:
          if (_armor < 100) _armor = 100;
        case MobjType.misc2:
          _keys.add(Key.blue);
        case MobjType.misc3:
          _keys.add(Key.yellow);
        case MobjType.misc4:
          _keys.add(Key.red);
        case MobjType.misc10:
          _health = _health < 200 ? _health + 1 : 200;
        case MobjType.misc11:
          _armor = _armor < 200 ? _armor + 1 : 200;
        case MobjType.misc12:
          _health = (_health + 25 > 100) ? 100 : _health + 25;
        case MobjType.misc17:
          _shells += 4;
        default:
          _health = (_health + 10 > 100) ? 100 : _health + 10;
      }
      m.removed = true;
    }
  }

  MobjView _view(Mobj m) => MobjView(
    id: m.id,
    x: m.x,
    y: m.y,
    z: m.z,
    angle: m.angle,
    sprite: m.info.spriteName,
    frame: m.spriteFrame,
    flags: m.flags,
    health: m.health,
  );

  int hashState() {
    int h = 0x811c9dc5;
    void add(int value) {
      for (int i = 0; i < 4; i++) {
        h ^= (value >> (i * 8)) & 0xff;
        h = (h * 0x01000193) & 0xffffffff;
      }
    }

    add(_tic);
    add(_random.index);
    add(config.skill.index);
    add(config.maxCatchUpTics);
    add(config.monsters ? 1 : 0);
    add(_nextId);
    add(_useHeld ? 1 : 0);
    add(_health);
    add(_armor);
    add(_bullets);
    add(_shells);
    add(_weapon.index);
    for (final Weapon weapon in Weapon.values) {
      add(_ownedWeapons.contains(weapon) ? 1 : 0);
    }
    for (final Key key in Key.values) {
      add(_keys.contains(key) ? 1 : 0);
    }
    add(_secrets);
    add(_levelComplete ? 1 : 0);
    add(_secretExit ? 1 : 0);
    for (int i = 0; i < _runtime.map.linedefs.length; i++) {
      add(_activatedOnceLines.contains(i) ? 1 : 0);
    }
    for (final SectorRuntime s in _runtime.sectors) {
      add(s.floorHeight);
      add(s.ceilingHeight);
      add(s.lightLevel);
      add(s.activeMover == null ? 0 : 1);
      for (final int word in s.activeMover?.hashWords ?? const <int>[]) {
        add(word);
      }
      add(_foundSecrets.contains(s.index) ? 1 : 0);
    }
    final List<Mobj> stableMobjs = List<Mobj>.of(_mobjs)
      ..sort((Mobj a, Mobj b) => a.id.compareTo(b.id));
    for (final Mobj m in stableMobjs) {
      add(m.id);
      add(m.info.id.index);
      add(m.x);
      add(m.y);
      add(m.z);
      add(m.angle);
      add(m.health);
      add(m.state.index);
      add(m.flags);
      add(m.spriteFrame);
      add(m.momX);
      add(m.momY);
      add(m.momZ);
      add(m.sectorIndex);
      add(m.floorZ);
      add(m.ceilingZ);
      add(m.dropOffZ);
      add(m.stateTics);
      add(m.reactionTime);
      add(m.threshold);
      add(m.moveDir);
      add(m.moveCount);
      add(m.target?.id ?? 0);
      add(m.owner?.id ?? 0);
      add(m.removed ? 1 : 0);
    }
    // _bob is a pure function of already-hashed tic and player momentum.
    // _changes is an output journal: consuming it cannot affect simulation
    // state or future tics, so including it would make replay hashes depend on
    // renderer polling rather than seed + TicCmd stream.
    return h;
  }
}

class _DoorMover extends SectorMover {
  _DoorMover(
    super.sector,
    this.target, {
    required this.closeAfterWait,
    required this.obstructed,
  }) : _closed = sector.ceilingHeight;
  final int target;
  final int _closed;
  final bool closeAfterWait;
  final bool Function(int nextCeiling) obstructed;
  int _wait = 150;
  bool _closing = false;
  @override
  bool tick() {
    final int step = toFixed(4);
    if (!_closing) {
      sector.ceilingHeight += step;
      if (sector.ceilingHeight >= target) {
        sector.ceilingHeight = target;
        if (!closeAfterWait) finished = true;
        if (closeAfterWait && _wait-- <= 0) _closing = true;
      }
    } else {
      final int next = sector.ceilingHeight - step;
      if (obstructed(next)) {
        _closing = false;
        _wait = 150;
        return false;
      }
      sector.ceilingHeight = next;
      if (sector.ceilingHeight <= _closed) {
        sector.ceilingHeight = _closed;
        finished = true;
      }
    }
    return true;
  }

  @override
  Iterable<int> get hashWords => <int>[
    1,
    target,
    _closed,
    closeAfterWait ? 1 : 0,
    _wait,
    _closing ? 1 : 0,
  ];
}

class _LiftMover extends SectorMover {
  _LiftMover(super.sector, this.bottom) : top = sector.floorHeight;
  final int bottom, top;
  int _wait = 35;
  bool _returning = false;
  @override
  bool tick() {
    const int step = 4 * kFracUnit;
    if (!_returning) {
      sector.floorHeight -= step;
      if (sector.floorHeight <= bottom) {
        sector.floorHeight = bottom;
        if (_wait-- <= 0) _returning = true;
      }
    } else {
      sector.floorHeight += step;
      if (sector.floorHeight >= top) {
        sector.floorHeight = top;
        finished = true;
      }
    }
    return true;
  }

  @override
  Iterable<int> get hashWords => <int>[
    2,
    bottom,
    top,
    _wait,
    _returning ? 1 : 0,
  ];
}

class _FloorMover extends SectorMover {
  _FloorMover(super.sector, this.target, {required this.obstructed});
  final int target;
  final bool Function(int nextFloor) obstructed;

  @override
  bool tick() {
    const int step = kFracUnit;
    if (sector.floorHeight == target) {
      finished = true;
      return false;
    }
    final int direction = target > sector.floorHeight ? 1 : -1;
    int next = sector.floorHeight + step * direction;
    if ((direction > 0 && next > target) || (direction < 0 && next < target)) {
      next = target;
    }
    if (direction > 0 && obstructed(next)) return false;
    sector.floorHeight = next;
    if (next == target) finished = true;
    return true;
  }

  @override
  Iterable<int> get hashWords => <int>[3, target];
}

bool _isDoorSpecial(int special) =>
    <int>{1, 26, 27, 28, 31, 32, 33, 34, 61, 99, 103, 134}.contains(special);
bool _doorStaysOpen(int special) => <int>{31, 32, 33, 34, 61}.contains(special);
Key? _requiredKey(int special) => switch (special) {
  26 || 32 || 99 => Key.blue,
  27 || 34 => Key.yellow,
  28 || 33 || 134 => Key.red,
  _ => null,
};
bool _isWalkLiftSpecial(int special) =>
    <int>{10, 88, 120, 121}.contains(special);
bool _isUseLiftSpecial(int special) =>
    <int>{21, 62, 122, 123}.contains(special);
bool _isWalkFloorSpecial(int special) => special == 5;
bool _isUseSpecial(int special) =>
    _isDoorSpecial(special) ||
    _isUseLiftSpecial(special) ||
    special == LineSpecial.exitSwitchOnce ||
    special == LineSpecial.secretExitSwitchOnce;

const MobjInfo _playerInfo = MobjInfo(
  id: MobjType.player,
  doomEdNum: 1,
  spawnHealth: 100,
  radius: 16,
  height: 56,
  mass: 100,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'PLAY',
  flags: MobjFlags.solid | MobjFlags.shootable,
);
const MobjInfo _possessedInfo = MobjInfo(
  id: MobjType.possessed,
  doomEdNum: 3004,
  spawnHealth: 20,
  radius: 20,
  height: 56,
  mass: 100,
  speed: 8,
  reactionTime: 0,
  painChance: 200,
  damage: 3,
  spriteName: 'POSS',
  flags: MobjFlags.solid | MobjFlags.shootable | MobjFlags.countKill,
);
const MobjInfo _shotguyInfo = MobjInfo(
  id: MobjType.shotguy,
  doomEdNum: 9,
  spawnHealth: 30,
  radius: 20,
  height: 56,
  mass: 100,
  speed: 8,
  reactionTime: 0,
  painChance: 170,
  damage: 3,
  spriteName: 'SPOS',
  flags: MobjFlags.solid | MobjFlags.shootable | MobjFlags.countKill,
);
const MobjInfo _impInfo = MobjInfo(
  id: MobjType.troop,
  doomEdNum: 3001,
  spawnHealth: 60,
  radius: 20,
  height: 56,
  mass: 100,
  speed: 8,
  reactionTime: 0,
  painChance: 200,
  damage: 3,
  spriteName: 'TROO',
  flags: MobjFlags.solid | MobjFlags.shootable | MobjFlags.countKill,
);
const MobjInfo _impShotInfo = MobjInfo(
  id: MobjType.troopshot,
  doomEdNum: -1,
  spawnHealth: 1,
  radius: 6,
  height: 8,
  mass: 100,
  speed: 10,
  reactionTime: 0,
  painChance: 0,
  damage: 3,
  spriteName: 'BAL1',
  flags: MobjFlags.missile,
);
const MobjInfo _clipInfo = MobjInfo(
  id: MobjType.clip,
  doomEdNum: 2007,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'CLIP',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _shotgunInfo = MobjInfo(
  id: MobjType.shotgun,
  doomEdNum: 2001,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'SHOT',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _chaingunInfo = MobjInfo(
  id: MobjType.chaingun,
  doomEdNum: 2002,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'MGUN',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _healthInfo = MobjInfo(
  id: MobjType.misc1,
  doomEdNum: 2011,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'STIM',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _armorInfo = MobjInfo(
  id: MobjType.misc0,
  doomEdNum: 2018,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'ARM1',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _blueKeyInfo = MobjInfo(
  id: MobjType.misc2,
  doomEdNum: 5,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'BKEY',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _yellowKeyInfo = MobjInfo(
  id: MobjType.misc3,
  doomEdNum: 6,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'YKEY',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _redKeyInfo = MobjInfo(
  id: MobjType.misc4,
  doomEdNum: 13,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'RKEY',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _healthBonusInfo = MobjInfo(
  id: MobjType.misc10,
  doomEdNum: 2014,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'BON1',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _medikitInfo = MobjInfo(
  id: MobjType.misc12,
  doomEdNum: 2012,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'MEDI',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _armorBonusInfo = MobjInfo(
  id: MobjType.misc11,
  doomEdNum: 2015,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'BON2',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _shellsInfo = MobjInfo(
  id: MobjType.misc17,
  doomEdNum: 2008,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'SHEL',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _barrelInfo = MobjInfo(
  id: MobjType.barrel,
  doomEdNum: 2035,
  spawnHealth: 20,
  radius: 10,
  height: 42,
  mass: 100,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'BAR1',
  flags: MobjFlags.solid | MobjFlags.shootable,
);
MobjInfo? _infoForEdNum(int n) => switch (n) {
  3004 => _possessedInfo,
  9 => _shotguyInfo,
  3001 => _impInfo,
  2007 => _clipInfo,
  2001 => _shotgunInfo,
  2002 => _chaingunInfo,
  2011 => _healthInfo,
  2018 => _armorInfo,
  5 => _blueKeyInfo,
  6 => _yellowKeyInfo,
  13 => _redKeyInfo,
  2014 => _healthBonusInfo,
  2012 => _medikitInfo,
  2015 => _armorBonusInfo,
  2008 => _shellsInfo,
  2035 => _barrelInfo,
  _ => null,
};
