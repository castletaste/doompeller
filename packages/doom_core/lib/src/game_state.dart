import 'package:doom_wad/doom_wad.dart';

import 'angles.dart';
import 'config.dart';
import 'fixed.dart';
import 'map_runtime.dart';
import 'mobj.dart';
import 'mobj_info.dart';
import 'mobj_states.dart';
import 'random.dart';
import 'sector_runtime.dart';
import 'sound_events.dart';
import 'specials.dart';
import 'switches.dart';
import 'ticcmd.dart';
import 'views.dart';

const int _playerRadius = 16 * kFracUnit;
const int _maxStep = 24 * kFracUnit;
const int _maxBob = 0x100000;
const int _singleAxisMaxBobMomentum = 8 * kFracUnit;
const int _bobAngleStep = (kFineAngles ~/ 20) << kAngleToFineShift;
const int _ceilingViewClearance = 4 * kFracUnit;
const int _livingViewHeight = 41 * kFracUnit;
const int _deadViewHeight = 6 * kFracUnit;
const int _deathViewDropPerTic = kFracUnit;
const int _baseMonsterThreshold = 100;
const int _weaponTop = 32;
const int _weaponBottom = 128;
const int _weaponMovePerTic = 6;

enum _WeaponAction { fire, refire }

final class _WeaponFlashState {
  const _WeaponFlashState(this.frame, this.tics);

  final int frame;
  final int tics;
}

final class _WeaponFireState {
  const _WeaponFireState(
    this.frame,
    this.tics, {
    this.action,
    this.flash = const <_WeaponFlashState>[],
  });

  final int frame;
  final int tics;
  final _WeaponAction? action;
  final List<_WeaponFlashState> flash;
}

const List<_WeaponFlashState> _pistolFlash = <_WeaponFlashState>[
  _WeaponFlashState(0, 7),
];
const List<_WeaponFlashState> _shotgunFlash = <_WeaponFlashState>[
  _WeaponFlashState(0, 4),
  _WeaponFlashState(1, 3),
];
const List<_WeaponFlashState> _chaingunFlashA = <_WeaponFlashState>[
  _WeaponFlashState(0, 5),
];
const List<_WeaponFlashState> _chaingunFlashB = <_WeaponFlashState>[
  _WeaponFlashState(1, 5),
];

const List<_WeaponFireState> _fistStates = <_WeaponFireState>[
  _WeaponFireState(1, 4),
  _WeaponFireState(2, 4, action: _WeaponAction.fire),
  _WeaponFireState(3, 5),
  _WeaponFireState(2, 4),
  _WeaponFireState(1, 5, action: _WeaponAction.refire),
];
const List<_WeaponFireState> _pistolStates = <_WeaponFireState>[
  _WeaponFireState(0, 4),
  _WeaponFireState(1, 6, action: _WeaponAction.fire, flash: _pistolFlash),
  _WeaponFireState(2, 4),
  _WeaponFireState(1, 5, action: _WeaponAction.refire),
];
const List<_WeaponFireState> _shotgunStates = <_WeaponFireState>[
  _WeaponFireState(0, 3),
  _WeaponFireState(0, 7, action: _WeaponAction.fire, flash: _shotgunFlash),
  _WeaponFireState(1, 5),
  _WeaponFireState(2, 5),
  _WeaponFireState(3, 4),
  _WeaponFireState(2, 5),
  _WeaponFireState(1, 5),
  _WeaponFireState(0, 3),
  _WeaponFireState(0, 7, action: _WeaponAction.refire),
];
const List<_WeaponFireState> _chaingunStates = <_WeaponFireState>[
  _WeaponFireState(0, 4, action: _WeaponAction.fire, flash: _chaingunFlashA),
  _WeaponFireState(1, 4, action: _WeaponAction.fire, flash: _chaingunFlashB),
  _WeaponFireState(1, 0, action: _WeaponAction.refire),
];

/// Integer-only 35 Hz game simulation. Its iteration order is spawn order;
/// removal is deferred to the end of each tic so callbacks cannot reorder it.
class GameState {
  /// Output buffering is deliberately bounded: repeated weapon/pain/item
  /// sounds are expendable before door, platform, death, and exit cues. When
  /// all buffered events are critical, an incoming non-critical event is
  /// discarded; an incoming critical event replaces the oldest critical one.
  /// Every discard increments [droppedSoundEventCount], so loss is observable.
  static const int maxSoundJournalLength = 256;

  GameState._(this._runtime, this.config, int seed)
    : _random = DoomRandom(index: seed) {
    _totalSecrets = _runtime.sectors
        .where((SectorRuntime sector) => sector.staticData.special == 9)
        .length;
    _spawnMapThings();
  }

  static GameState start(MapData map, GameConfig config, {int seed = 0}) =>
      GameState._(MapRuntime(map), config, seed);

  final MapRuntime _runtime;
  final GameConfig config;
  final DoomRandom _random;
  final List<Mobj> _mobjs = <Mobj>[];
  final List<SectorChange> _changes = <SectorChange>[];
  final List<SoundEvent> _sounds = <SoundEvent>[];
  final List<SwitchTextureChange> _switchChanges = <SwitchTextureChange>[];
  final Map<int, _PressedSwitch> _pressedSwitches = <int, _PressedSwitch>{};
  int _droppedSoundEvents = 0;
  int _tic = 0;
  int _nextId = 1;
  late Mobj _playerMobj;
  int _health = 100, _armor = 0, _bullets = 50, _shells = 0;
  Weapon _weapon = Weapon.pistol;
  Weapon? _pendingWeapon;
  WeaponPhase _weaponPhase = WeaponPhase.ready;
  int _weaponState = 0;
  int _weaponFrame = 0;
  int _weaponTics = -1;
  int _weaponY = _weaponTop;
  int _flashFrame = -1;
  int _flashState = 0;
  int _flashTics = 0;
  List<_WeaponFlashState> _flashSequence = const <_WeaponFlashState>[];
  final Set<Weapon> _ownedWeapons = <Weapon>{Weapon.fist, Weapon.pistol};
  final Set<Key> _keys = <Key>{};
  final Set<int> _foundSecrets = <int>{};
  final Set<int> _activatedOnceLines = <int>{};
  late final List<Mobj?> _sectorSoundTargets = List<Mobj?>.filled(
    _runtime.sectors.length,
    null,
  );
  late final List<int> _soundVisitGenerations = List<int>.filled(
    _runtime.sectors.length,
    0,
  );
  final List<int> _soundQueueSectors = <int>[];
  final List<int> _soundQueueBlocks = <int>[];
  int _soundVisitGeneration = 0;
  int _secrets = 0;
  int _killCount = 0;
  int _totalKills = 0;
  int _itemCount = 0;
  int _totalItems = 0;
  late final int _totalSecrets;
  bool _levelComplete = false;
  bool _secretExit = false;
  int _bob = 0;
  int _deathViewHeight = _livingViewHeight;
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

  List<SwitchTextureChange> get switchJournal =>
      List<SwitchTextureChange>.unmodifiable(_switchChanges);
  List<SwitchTextureChange> consumeSwitchJournal() {
    final List<SwitchTextureChange> result =
        List<SwitchTextureChange>.unmodifiable(_switchChanges);
    _switchChanges.clear();
    return result;
  }

  /// Ordered sound requests retained until consumed. Like [changeJournal],
  /// this is output-only and a renderer may poll less often than 35 Hz.
  List<SoundEvent> get soundJournal => List<SoundEvent>.unmodifiable(_sounds);
  List<SoundEvent> consumeSoundJournal() {
    final List<SoundEvent> result = List<SoundEvent>.unmodifiable(_sounds);
    _sounds.clear();
    return result;
  }

  /// Cumulative output-only telemetry, deliberately excluded from hashState.
  int get droppedSoundEventCount => _droppedSoundEvents;

  int get secretsFound => _secrets;
  int get killCount => _killCount;
  int get totalKills => _totalKills;
  int get itemCount => _itemCount;
  int get totalItems => _totalItems;
  int get totalSecrets => _totalSecrets;
  int get levelTime => _tic;

  /// Pure renderer selection derived from already-hashed game time.
  ///
  /// No animation cursor is stored or hashed: querying or polling animation
  /// output cannot influence a future simulation tic.
  int animationFrameIndex({
    required int frameCount,
    required int speed,
    int initialFrame = 0,
  }) {
    if (frameCount <= 0 || speed <= 0) {
      throw ArgumentError('frameCount and speed must be positive');
    }
    return (initialFrame + _tic ~/ speed) % frameCount;
  }

  /// Read-only spatial position for renderer/UI consumers. It is derived from
  /// existing gameplay state and does not add a new word to [hashState].
  int get playerSectorIndex => _playerMobj.sectorIndex;
  bool get levelComplete => _levelComplete;
  bool get usedSecretExit => _secretExit;
  PlayerView get player {
    final int ceiling = _runtime.sectors[_playerMobj.sectorIndex].ceilingHeight;
    final int viewHeight = _health > 0 ? _livingViewHeight : _deathViewHeight;
    final int bobbedViewZ = _playerMobj.z + viewHeight + _bob;
    final int highestViewZ = ceiling - _ceilingViewClearance;
    return PlayerView(
      x: _playerMobj.x,
      y: _playerMobj.y,
      z: _playerMobj.z,
      angle: _playerMobj.angle,
      viewZ: bobbedViewZ < highestViewZ ? bobbedViewZ : highestViewZ,
      health: _health,
      armor: _armor,
      ammo: Ammo(bullets: _bullets, shells: _shells),
      weapon: _weapon,
      bob: _bob,
      keys: Set<Key>.unmodifiable(_keys),
      weaponAnimation: WeaponAnimation(
        weapon: _weapon,
        phase: _weaponPhase,
        frame: _weaponFrame,
        tics: _weaponTics,
        y: _weaponY,
        flashFrame: _flashFrame,
      ),
    );
  }

  void runTic(TicCmd cmd) {
    _tic++;
    _tickSwitchButtons();
    _tickMovers();
    if (_health > 0) {
      _tickPlayer(cmd);
    } else {
      _tickDeathView();
    }
    _tickSectorEffects();
    _tickActors(runAi: config.monsters);
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
        final Mobj spawned = _add(
          info,
          thing.x,
          thing.y,
          thing.angle,
          info.spawnHealth,
        );
        spawned.ambush = (thing.flags & ThingFlags.ambush) != 0;
        if ((info.flags & MobjFlags.countKill) != 0) _totalKills++;
        if ((info.flags & MobjFlags.countItem) != 0) _totalItems++;
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
    final int? spawnState = MobjStateTable.start(info.id, MobjState.spawn);
    if (spawnState != null) _setMobjState(m, spawnState);
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
    int bob =
        (fixedMul(_playerMobj.momX, _playerMobj.momX) +
            fixedMul(_playerMobj.momY, _playerMobj.momY)) >>
        2;
    // Above eight units on either axis, the mathematical square already
    // guarantees MAXBOB. Saturate before a wrapped fixed-point square can
    // disguise that fact for the larger impulses accepted by this runtime.
    if (fixedAbs(_playerMobj.momX) >= _singleAxisMaxBobMomentum ||
        fixedAbs(_playerMobj.momY) >= _singleAxisMaxBobMomentum ||
        bob > _maxBob) {
      bob = _maxBob;
    }
    _bob = fixedMul(bob >> 1, Trig.sin(_tic * _bobAngleStep));
    if (cmd.using && !_useHeld) _useLine();
    _useHeld = cmd.using;
    _tickWeapon(cmd.attacking);
  }

  void _selectWeapon(int slot) {
    final Weapon requested = switch (slot) {
      0 => Weapon.fist,
      1 => Weapon.pistol,
      2 => Weapon.shotgun,
      3 => Weapon.chaingun,
      _ => _weapon,
    };
    _queueWeapon(requested);
  }

  void _queueWeapon(Weapon requested) {
    if (!_ownedWeapons.contains(requested) ||
        requested == _weapon ||
        requested == _pendingWeapon) {
      return;
    }
    _pendingWeapon = requested;
    if (_weaponPhase == WeaponPhase.ready) {
      _weaponPhase = WeaponPhase.lowering;
      _weaponTics = 1;
    }
  }

  void _setWeapon(Weapon requested) {
    if (requested == _weapon) return;
    _weapon = requested;
    _emitPlayerSound('DSWPNUP');
  }

  void _tickWeapon(bool attacking) {
    _tickWeaponFlash();
    switch (_weaponPhase) {
      case WeaponPhase.lowering:
        _weaponY += _weaponMovePerTic;
        if (_weaponY >= _weaponBottom) {
          final Weapon next = _pendingWeapon ?? _weapon;
          _pendingWeapon = null;
          _setWeapon(next);
          _weaponY = _weaponBottom;
          _weaponPhase = WeaponPhase.raising;
        }
        return;
      case WeaponPhase.raising:
        _weaponY -= _weaponMovePerTic;
        if (_weaponY <= _weaponTop) {
          _weaponY = _weaponTop;
          _weaponPhase = WeaponPhase.ready;
          _weaponState = 0;
          _weaponFrame = 0;
          _weaponTics = -1;
        }
        return;
      case WeaponPhase.firing:
        if (--_weaponTics > 0) return;
        _advanceWeaponFiring(attacking);
        return;
      case WeaponPhase.ready:
        if (_pendingWeapon != null) {
          _weaponPhase = WeaponPhase.lowering;
          _weaponTics = 1;
          return;
        }
        if (attacking) _beginWeaponAttack();
    }
  }

  void _beginWeaponAttack() {
    if (_weapon == Weapon.shotgun && _shells == 0) {
      _pendingWeapon = Weapon.pistol;
      _weaponPhase = WeaponPhase.lowering;
      return;
    }
    if ((_weapon == Weapon.pistol || _weapon == Weapon.chaingun) &&
        _bullets == 0) {
      _pendingWeapon = Weapon.fist;
      _weaponPhase = WeaponPhase.lowering;
      return;
    }
    _weaponPhase = WeaponPhase.firing;
    _enterWeaponState(0, attacking: false);
  }

  void _advanceWeaponFiring(bool attacking) {
    final List<_WeaponFireState> states = _weaponFireStates(_weapon);
    if (_weaponState + 1 < states.length) {
      _enterWeaponState(_weaponState + 1, attacking: attacking);
      return;
    }
    if (_pendingWeapon != null) {
      _weaponPhase = WeaponPhase.lowering;
      return;
    }
    if (attacking) {
      _beginWeaponAttack();
      return;
    }
    _weaponPhase = WeaponPhase.ready;
    _weaponState = 0;
    _weaponFrame = 0;
    _weaponTics = -1;
  }

  List<_WeaponFireState> _weaponFireStates(Weapon weapon) => switch (weapon) {
    Weapon.fist => _fistStates,
    Weapon.pistol => _pistolStates,
    Weapon.shotgun => _shotgunStates,
    Weapon.chaingun => _chaingunStates,
  };

  void _enterWeaponState(int index, {required bool attacking}) {
    final _WeaponFireState state = _weaponFireStates(_weapon)[index];
    _weaponState = index;
    _weaponFrame = state.frame;
    _weaponTics = state.tics;
    switch (state.action) {
      case _WeaponAction.fire:
        _startWeaponFlash(state.flash);
        _fireWeapon();
        break;
      case _WeaponAction.refire:
        if (_pendingWeapon != null) {
          _weaponPhase = WeaponPhase.lowering;
          _weaponTics = 1;
        } else if (attacking) {
          _beginWeaponAttack();
        } else if (_weaponTics == 0) {
          _weaponPhase = WeaponPhase.ready;
          _weaponState = 0;
          _weaponFrame = 0;
          _weaponTics = -1;
        }
        break;
      case null:
        break;
    }
  }

  void _startWeaponFlash(List<_WeaponFlashState> sequence) {
    if (sequence.isEmpty) return;
    _flashSequence = sequence;
    _flashState = 0;
    _flashFrame = sequence.first.frame;
    _flashTics = sequence.first.tics;
  }

  void _tickWeaponFlash() {
    if (_flashFrame < 0 || --_flashTics > 0) return;
    _flashState++;
    if (_flashState >= _flashSequence.length) {
      _flashFrame = -1;
      _flashTics = 0;
      _flashSequence = const <_WeaponFlashState>[];
      return;
    }
    final _WeaponFlashState state = _flashSequence[_flashState];
    _flashFrame = state.frame;
    _flashTics = state.tics;
  }

  void _fireWeapon() {
    // One alert per weapon action, never once per shotgun pellet. The bounded
    // traversal itself consumes no RNG, so it does not perturb attack rolls.
    _noiseAlert(_playerMobj);
    switch (_weapon) {
      case Weapon.fist:
        _emitPlayerSound('DSPUNCH');
        _hitscan(64 * kFracUnit, 2 + (_random.next() % 10));
      case Weapon.pistol:
        _emitPlayerSound('DSPISTOL');
        _bullets--;
        _hitscan(1024 * kFracUnit, 5 * (1 + (_random.next() % 3)));
      case Weapon.chaingun:
        _emitPlayerSound('DSPISTOL');
        _bullets--;
        _hitscan(1024 * kFracUnit, 5 * (1 + (_random.next() % 3)));
      case Weapon.shotgun:
        _emitPlayerSound('DSSHOTGN');
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

  void _tickDeathView() {
    _bob = 0;
    if (_deathViewHeight > _deadViewHeight) {
      _deathViewHeight -= _deathViewDropPerTic;
      if (_deathViewHeight < _deadViewHeight) {
        _deathViewHeight = _deadViewHeight;
      }
    }
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
    if (target != null) {
      _spawnBlood(target, damage);
      _damage(target, damage, _playerMobj);
      return;
    }
    final ({int x, int y})? impact = _nearestWallImpact(angle, range);
    if (impact != null) _spawnPuff(impact.x, impact.y);
  }

  /// Finds the nearest blocking line hit by a 16.16 ray without floating point
  /// arithmetic. It is intentionally separate from actor targeting: the actor
  /// path uses the existing sight policy, while this only supplies an honest
  /// visual impact when no shootable actor was acquired.
  ({int x, int y})? _nearestWallImpact(int angle, int range) {
    final int startX = _playerMobj.x;
    final int startY = _playerMobj.y;
    final int rayX = fixedMul(range, Trig.cos(angle));
    final int rayY = fixedMul(range, Trig.sin(angle));
    int bestT = kFracUnit + 1;
    ({int x, int y})? result;
    for (int i = 0; i < _runtime.map.linedefs.length; i++) {
      final Linedef line = _runtime.map.linedefs[i];
      if (!_hitscanLineBlocks(i, line)) continue;
      final MapVertex a = _runtime.map.vertices[line.v1];
      final MapVertex b = _runtime.map.vertices[line.v2];
      final int ax = toFixed(a.x);
      final int ay = toFixed(a.y);
      final int sx = toFixed(b.x - a.x);
      final int sy = toFixed(b.y - a.y);
      final int denom = rayX * sy - rayY * sx;
      if (denom == 0) continue;
      final int offsetX = ax - startX;
      final int offsetY = ay - startY;
      final int rayNumerator = offsetX * sy - offsetY * sx;
      final int segmentNumerator = offsetX * rayY - offsetY * rayX;
      final bool positive = denom > 0;
      if ((positive &&
              (rayNumerator < 0 ||
                  rayNumerator > denom ||
                  segmentNumerator < 0 ||
                  segmentNumerator > denom)) ||
          (!positive &&
              (rayNumerator > 0 ||
                  rayNumerator < denom ||
                  segmentNumerator > 0 ||
                  segmentNumerator < denom))) {
        continue;
      }
      final int t = (rayNumerator << kFracBits) ~/ denom;
      if (t < 0 || t > kFracUnit || t >= bestT) continue;
      bestT = t;
      result = (x: startX + fixedMul(rayX, t), y: startY + fixedMul(rayY, t));
    }
    return result;
  }

  bool _hitscanLineBlocks(int index, Linedef line) {
    if (line.blocksMovement || !line.isTwoSided) return true;
    final ({int bottom, int top})? opening = _runtime.openingFor(index);
    return opening == null ||
        opening.top <= _playerMobj.viewZ ||
        opening.bottom >= _playerMobj.viewZ;
  }

  void _spawnPuff(int x, int y) {
    final Mobj puff = _add(_puffInfo, fixedToInt(x), fixedToInt(y), 0, 1);
    puff.x = x;
    puff.y = y;
    puff.z = _playerMobj.viewZ;
  }

  void _spawnBlood(Mobj target, int damage) {
    final Mobj blood = _add(
      _bloodInfo,
      fixedToInt(target.x),
      fixedToInt(target.y),
      0,
      1,
    );
    blood.x = target.x;
    blood.y = target.y;
    blood.z = target.z + (target.height ~/ 2);
    _setMobjState(blood, MobjStateTable.bloodImpactStart(damage));
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
    if ((_isOneShotSwitchSpecial(selected.special) &&
            _activatedOnceLines.contains(selectedIndex)) ||
        _pressedSwitches.containsKey(selectedIndex)) {
      return;
    }
    if (_isDoorSpecial(selected.special)) {
      final bool activated = _tryActivateDoor(selected);
      if (activated && _isSwitchDoorSpecial(selected.special)) {
        _activateSwitchTexture(selectedIndex, selected);
        _emitPlayerSound('DSSWTCHN');
      }
    }
    if (_isUseLiftSpecial(selected.special) && _activateLift(selected)) {
      _activateSwitchTexture(selectedIndex, selected);
      _emitPlayerSound('DSSWTCHN');
    }
    if (selected.special == LineSpecial.exitSwitchOnce ||
        selected.special == LineSpecial.secretExitSwitchOnce) {
      if (!_isOnFrontSide(selected, _playerMobj.x, _playerMobj.y)) return;
      if (_completeExit(
        selectedIndex,
        secret: selected.special == LineSpecial.secretExitSwitchOnce,
      )) {
        _activateSwitchTexture(selectedIndex, selected);
      }
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

  bool _completeExit(int lineIndex, {required bool secret}) {
    if (_levelComplete) return false;
    if (!_activatedOnceLines.add(lineIndex)) return false;
    _levelComplete = true;
    _secretExit = secret;
    _emitNonPositionalSound('DSSWTCHX');
    return true;
  }

  void _activateSwitchTexture(int lineIndex, Linedef line) {
    if (_isOneShotSwitchSpecial(line.special)) {
      _activatedOnceLines.add(lineIndex);
    }
    final int sidedef = line.rightSidedef;
    if (sidedef < 0 || sidedef >= _runtime.map.sidedefs.length) return;
    final Sidedef side = _runtime.map.sidedefs[sidedef];
    final List<(SwitchTextureSlot, String)> candidates =
        <(SwitchTextureSlot, String)>[
          (SwitchTextureSlot.upper, side.upperTexture),
          (SwitchTextureSlot.middle, side.middleTexture),
          (SwitchTextureSlot.lower, side.lowerTexture),
        ];
    for (final (SwitchTextureSlot slot, String name) in candidates) {
      DoomSwitchPair? matched;
      String? next;
      for (final DoomSwitchPair pair in vanillaDoomSwitches) {
        next = pair.opposite(name);
        if (next != null) {
          matched = pair;
          break;
        }
      }
      if (matched == null || next == null) continue;
      final bool repeatable = _isRepeatableSwitchSpecial(line.special);
      _pressedSwitches[lineIndex] = _PressedSwitch(
        linedef: lineIndex,
        sidedef: sidedef,
        slot: slot,
        offName: name,
        onName: next,
        remaining: repeatable ? 35 : -1,
      );
      _switchChanges.add(
        SwitchTextureChange(
          linedef: lineIndex,
          sidedef: sidedef,
          slot: slot,
          textureName: next,
          tic: _tic,
        ),
      );
      return;
    }
  }

  void _tickSwitchButtons() {
    final List<int> reset = <int>[];
    for (final MapEntry<int, _PressedSwitch> entry
        in _pressedSwitches.entries) {
      final _PressedSwitch pressed = entry.value;
      if (pressed.remaining < 0) continue;
      pressed.remaining--;
      if (pressed.remaining > 0) continue;
      _switchChanges.add(
        SwitchTextureChange(
          linedef: pressed.linedef,
          sidedef: pressed.sidedef,
          slot: pressed.slot,
          textureName: pressed.offName,
          tic: _tic,
        ),
      );
      _emitPlayerSound('DSSWTCHN');
      reset.add(entry.key);
    }
    for (final int line in reset) {
      _pressedSwitches.remove(line);
    }
  }

  void _shootSpecialLine() {
    final int range = toFixed(1024);
    final int rayX =
        _playerMobj.x + fixedMul(range, Trig.cos(_playerMobj.angle));
    final int rayY =
        _playerMobj.y + fixedMul(range, Trig.sin(_playerMobj.angle));
    Linedef? selected;
    int selectedIndex = -1;
    int selectedDistance = 0x7fffffffffffffff;
    for (var i = 0; i < _runtime.map.linedefs.length; i++) {
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
    if (selected?.special == LineSpecial.floorRaise24 &&
        !_activatedOnceLines.contains(selectedIndex) &&
        _activateFloor(selected!)) {
      _activateSwitchTexture(selectedIndex, selected);
      _emitPlayerSound('DSSWTCHN');
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
    return _activateDoor(line);
  }

  bool _activateDoor(Linedef line) {
    // tag 0 manual doors affect the adjacent back sector; classification comes
    // from special, never from the tag.
    final int? back = _runtime.backSector(line);
    final List<int> targets = line.tag == 0
        ? (back == null ? <int>[] : <int>[back])
        : <int>[
            for (int i = 0; i < _runtime.sectors.length; i++)
              if (_runtime.sectors[i].staticData.tag == line.tag) i,
          ];
    var activated = false;
    for (final int index in targets) {
      final SectorRuntime sector = _runtime.sectors[index];
      if (sector.activeMover == null) {
        sector.activeMover = _DoorMover(
          sector,
          _doorOpenTop(index),
          closeAfterWait: !_doorStaysOpen(line.special),
          obstructed: (int nextCeiling) =>
              _sectorObstructed(index, ceiling: nextCeiling),
        );
        _emitSectorSound('DSDOROPN', index);
        activated = true;
      }
    }
    return activated;
  }

  bool _activateLift(Linedef line) {
    final int? back = _runtime.backSector(line);
    final List<int> targets = line.tag == 0
        ? (back == null ? <int>[] : <int>[back])
        : <int>[
            for (int i = 0; i < _runtime.sectors.length; i++)
              if (_runtime.sectors[i].staticData.tag == line.tag) i,
          ];
    var activated = false;
    for (final int index in targets) {
      final SectorRuntime sector = _runtime.sectors[index];
      if (sector.activeMover == null) {
        sector.activeMover = _LiftMover(sector, _lowestNeighborFloor(index));
        _emitSectorSound('DSPSTART', index);
        activated = true;
      }
    }
    return activated;
  }

  bool _activateFloor(Linedef line) {
    final List<int> targets = <int>[
      for (int i = 0; i < _runtime.sectors.length; i++)
        if (_runtime.sectors[i].staticData.tag == line.tag && line.tag != 0) i,
    ];
    var activated = false;
    for (final int index in targets) {
      final SectorRuntime sector = _runtime.sectors[index];
      final int target = switch (line.special) {
        LineSpecial.floorRaise24 => sector.floorHeight + toFixed(24),
        LineSpecial.floorRaiseToLowestCeiling =>
          _lowestNeighborCeiling(index) - toFixed(8),
        _ => sector.floorHeight,
      };
      if (sector.activeMover == null) {
        sector.activeMover = _FloorMover(
          sector,
          target,
          obstructed: (int nextFloor) =>
              _sectorObstructed(index, floor: nextFloor),
        );
        activated = true;
      }
    }
    return activated;
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
        final bool doorWasClosing = mover is _DoorMover && mover.isClosing;
        mover.tick();
        if (mover is _DoorMover && !doorWasClosing && mover.isClosing) {
          _emitSectorSound('DSDORCLS', s.index);
        }
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
          if (mover is _LiftMover) _emitSectorSound('DSPSTOP', s.index);
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

  void _noiseAlert(Mobj source) {
    if (_runtime.sectors.isEmpty) return;
    final int budget = config.maxSoundPropagationVisits;
    final int generation = ++_soundVisitGeneration;
    _soundQueueSectors
      ..clear()
      ..add(source.sectorIndex);
    _soundQueueBlocks
      ..clear()
      ..add(0);
    _soundVisitGenerations[source.sectorIndex] = generation;
    var cursor = 0;
    while (cursor < _soundQueueSectors.length && cursor < budget) {
      final int currentSector = _soundQueueSectors[cursor];
      final int currentBlocks = _soundQueueBlocks[cursor++];
      _sectorSoundTargets[currentSector] = source;
      final SectorRuntime sector = _runtime.sectors[currentSector];
      for (final int lineIndex in sector.touchingLinedefs) {
        if (_soundQueueSectors.length >= budget) break;
        final Linedef line = _runtime.map.linedefs[lineIndex];
        if (!line.isTwoSided) continue;
        final ({int bottom, int top})? opening = _runtime.openingFor(lineIndex);
        if (opening == null || opening.top <= opening.bottom) continue;
        final int front = _runtime.frontSector(line);
        final int? back = _runtime.backSector(line);
        if (back == null) continue;
        final int other = currentSector == front ? back : front;
        if (other == currentSector ||
            other < 0 ||
            other >= _runtime.sectors.length) {
          continue;
        }
        final bool blocksSound = (line.flags & LinedefFlags.soundBlock) != 0;
        final int nextBlocks = currentBlocks + (blocksSound ? 1 : 0);
        // A sound may pass one blocking boundary; a second one stops it. Doom
        // maps conventionally use blocking lines in pairs around a sound zone.
        if (nextBlocks > 1 || _soundVisitGenerations[other] == generation) {
          continue;
        }
        _soundVisitGenerations[other] = generation;
        _soundQueueSectors.add(other);
        _soundQueueBlocks.add(nextBlocks);
      }
    }
  }

  void _tickActors({required bool runAi}) {
    final List<Mobj> actors = List<Mobj>.of(_mobjs);
    for (final Mobj m in actors) {
      if (m.removed) continue;
      _advanceMobjState(m);
      if (m.removed) continue;
      if (m.isMissile) {
        _tickMissile(m);
        continue;
      }
      if (!runAi || !m.info.isMonster || m.health <= 0) continue;
      if (m.state != MobjState.spawn && m.state != MobjState.see) continue;
      if (m.reactionTime > 0) m.reactionTime--;
      if (m.threshold > 0) m.threshold--;
      if (m.target != null && (m.target!.health <= 0 || m.target!.removed)) {
        m.target = null;
        m.threshold = 0;
      }
      if (m.target == null && !_lookForTarget(m)) continue;
      final Mobj target = m.target!;
      final int distance = approxDistance(target.x - m.x, target.y - m.y);

      if ((m.flags & MobjFlags.justAttacked) != 0) {
        m.flags &= ~MobjFlags.justAttacked;
        _newChaseDir(m, target);
        continue;
      }

      if (distance < toFixed(64) &&
          MobjStateTable.start(m.info.id, MobjState.melee) != null) {
        m.angle = Trig.atan2(target.y - m.y, target.x - m.x);
        _enterMobjState(m, MobjState.melee);
        continue;
      }
      if (m.moveCount == 0 && _checkMissileRange(m, target, distance)) {
        m.angle = Trig.atan2(target.y - m.y, target.x - m.x);
        m.flags |= MobjFlags.justAttacked;
        _enterMobjState(m, MobjState.missile);
        continue;
      }
      _chaseMove(m, target);
    }
  }

  bool _lookForTarget(Mobj monster) {
    if (_health <= 0) return false;
    final Mobj? heard = _sectorSoundTargets[monster.sectorIndex];
    if (heard != null &&
        heard.health > 0 &&
        (!monster.ambush || _hasSight(monster, heard))) {
      monster.target = heard;
    } else if (_hasSight(monster, _playerMobj)) {
      monster.target = _playerMobj;
    }
    if (monster.target == null) return false;
    _enterMobjState(monster, MobjState.see);
    return true;
  }

  bool _checkMissileRange(Mobj monster, Mobj target, int distance) {
    if (monster.reactionTime > 0 || !_hasSight(monster, target)) return false;
    if (MobjStateTable.start(monster.info.id, MobjState.missile) == null) {
      return false;
    }
    int mapDistance = fixedToInt(distance) - 64;
    if (MobjStateTable.start(monster.info.id, MobjState.melee) == null) {
      mapDistance -= 128;
    }
    if (mapDistance < 0) mapDistance = 0;
    if (mapDistance > 200) mapDistance = 200;

    return _random.next() >= mapDistance;
  }

  void _chaseMove(Mobj monster, Mobj target) {
    if (monster.moveDir != kDirNone && monster.moveCount > 0) {
      if (_tryMonsterDirection(monster, monster.moveDir)) {
        monster.moveCount--;
        return;
      }
    }
    _newChaseDir(monster, target);
  }

  void _newChaseDir(Mobj monster, Mobj target) {
    final int oldDir = monster.moveDir;
    final int turnaround = oldDir == kDirNone ? kDirNone : (oldDir + 4) & 7;
    final int dx = target.x - monster.x;
    final int dy = target.y - monster.y;
    final int xDir = dx > toFixed(10)
        ? kDirEast
        : dx < -toFixed(10)
        ? kDirWest
        : kDirNone;
    final int yDir = dy > toFixed(10)
        ? kDirNorth
        : dy < -toFixed(10)
        ? kDirSouth
        : kDirNone;
    if (xDir != kDirNone && yDir != kDirNone) {
      final int diagonal = switch ((xDir, yDir)) {
        (kDirEast, kDirNorth) => kDirNorthEast,
        (kDirWest, kDirNorth) => kDirNorthWest,
        (kDirWest, kDirSouth) => kDirSouthWest,
        _ => kDirSouthEast,
      };
      if (diagonal != turnaround && _tryChaseDirection(monster, diagonal)) {
        return;
      }
    }
    int firstAxis = xDir;
    int secondAxis = yDir;
    if (_random.next() > 200 || dy.abs() > dx.abs()) {
      final int swap = firstAxis;
      firstAxis = secondAxis;
      secondAxis = swap;
    }
    if (firstAxis == turnaround) firstAxis = kDirNone;
    if (secondAxis == turnaround) secondAxis = kDirNone;
    if (firstAxis != kDirNone && _tryChaseDirection(monster, firstAxis)) {
      return;
    }
    if (secondAxis != kDirNone && _tryChaseDirection(monster, secondAxis)) {
      return;
    }
    if (oldDir != kDirNone && _tryChaseDirection(monster, oldDir)) return;

    if ((_random.next() & 1) != 0) {
      for (var direction = 0; direction < 8; direction++) {
        if (direction != turnaround && _tryChaseDirection(monster, direction)) {
          return;
        }
      }
    } else {
      for (var direction = 7; direction >= 0; direction--) {
        if (direction != turnaround && _tryChaseDirection(monster, direction)) {
          return;
        }
      }
    }
    if (turnaround != kDirNone && _tryChaseDirection(monster, turnaround)) {
      return;
    }
    monster.moveDir = kDirNone;
    monster.moveCount = 0;
  }

  bool _tryChaseDirection(Mobj monster, int direction) {
    monster.moveDir = direction;
    if (!_tryMonsterDirection(monster, direction)) return false;
    monster.moveCount = _random.next() & 15;
    return true;
  }

  bool _tryMonsterDirection(Mobj monster, int direction) {
    monster.angle = kDirAngles[direction];
    final int speed = toFixed(monster.info.speed);
    return _tryMove(
      monster,
      fixedMul(speed, Trig.cos(monster.angle)),
      fixedMul(speed, Trig.sin(monster.angle)),
      allowSlide: false,
    );
  }

  void _enterMobjState(Mobj m, MobjState phase) {
    int? state = MobjStateTable.start(m.info.id, phase);
    if (state == null && phase == MobjState.gibbedDeath) {
      state = MobjStateTable.start(m.info.id, MobjState.death);
    }
    if (state != null) _setMobjState(m, state);
  }

  void _setMobjState(Mobj m, int stateId) {
    final MobjFrameState state = MobjStateTable.state(stateId)!;
    m.frameState = state.id;
    m.state = state.phase;
    m.spriteName = state.sprite;
    m.spriteFrame = state.frame;
    m.fullBright = state.fullBright;
    m.stateTics = state.tics;
    _runMobjStateAction(m, state.action);
  }

  void _runMobjStateAction(Mobj m, MobjStateAction? action) {
    final Mobj? target = m.target;
    switch (action) {
      case MobjStateAction.monsterHitscan:
        if (target == null || target.health <= 0 || !_hasSight(m, target)) {
          return;
        }
        m.angle = Trig.atan2(target.y - m.y, target.x - m.x);
        final Mobj? struck = _monsterHitscanTarget(m, m.angle);
        if (struck == null) return;
        final int pellets = m.info.id == MobjType.shotguy ? 3 : 1;
        for (int i = 0; i < pellets; i++) {
          final int damage = 3 * (1 + (_random.next() % 5));
          if (identical(struck, _playerMobj)) {
            _damagePlayer(damage, source: m);
          } else if (struck.health > 0) {
            _spawnBlood(struck, damage);
            _damage(struck, damage, m);
          }
        }
      case MobjStateAction.monsterMelee:
        if (target == null || target.health <= 0) return;
        m.angle = Trig.atan2(target.y - m.y, target.x - m.x);
        if (approxDistance(target.x - m.x, target.y - m.y) < toFixed(64)) {
          final int damage = 3 + (_random.next() % 8);
          if (identical(target, _playerMobj)) {
            _damagePlayer(damage, source: m);
          } else {
            _damage(target, damage, m);
          }
        }
      case MobjStateAction.monsterMissile:
        if (target == null || target.health <= 0) return;
        m.angle = Trig.atan2(target.y - m.y, target.x - m.x);
        _spawnImpShot(m);
      case MobjStateAction.barrelExplode:
        _explodeBarrel(m, target ?? _playerMobj);
      case null:
        return;
    }
  }

  Mobj? _monsterHitscanTarget(Mobj shooter, int angle) {
    Mobj? result;
    int best = toFixed(2048);
    for (final Mobj candidate in _mobjs) {
      if (identical(candidate, shooter) ||
          candidate.removed ||
          !candidate.isShootable) {
        continue;
      }
      final int dx = candidate.x - shooter.x;
      final int dy = candidate.y - shooter.y;
      final int distance = approxDistance(dx, dy);
      if (distance > best) continue;
      final int delta = angleDelta(Trig.atan2(dy, dx), angle).abs();
      if (delta < 0x06000000 && _hasSight(shooter, candidate)) {
        result = candidate;
        best = distance;
      }
    }
    return result;
  }

  void _advanceMobjState(Mobj m) {
    if (m.frameState < 0 || m.stateTics < 0) return;
    if (--m.stateTics > 0) return;
    final MobjFrameState current = MobjStateTable.state(m.frameState)!;
    final int? next = current.next;
    if (next != null) {
      _setMobjState(m, next);
    } else if (current.removeOnExpiry) {
      m.removed = true;
    } else {
      m.stateTics = -1;
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
    final Mobj? struck = _missileImpactTarget(m);
    if (struck != null) {
      final int damage = m.info.damage * (1 + (_random.next() % 8));
      final Mobj source = m.owner ?? m;
      if (identical(struck, _playerMobj)) {
        _damagePlayer(damage, source: source);
      } else {
        _damage(struck, damage, source);
      }
      _explodeMissile(m);
      return;
    }
    if (!_tryMove(m, m.momX, m.momY)) {
      _explodeMissile(m);
      return;
    }
  }

  Mobj? _missileImpactTarget(Mobj missile) {
    final int nextX = wrap32(missile.x + missile.momX);
    final int nextY = wrap32(missile.y + missile.momY);
    for (final Mobj candidate in _mobjs) {
      if (identical(candidate, missile) ||
          identical(candidate, missile.owner) ||
          candidate.removed ||
          !candidate.isShootable ||
          missile.z >= candidate.z + candidate.height ||
          candidate.z >= missile.z + missile.height) {
        continue;
      }
      final int combined = missile.radius + candidate.radius;
      final int dx = nextX - candidate.x;
      final int dy = nextY - candidate.y;
      if (dx * dx + dy * dy < combined * combined &&
          _hasSight(missile, candidate)) {
        return candidate;
      }
    }
    return null;
  }

  void _explodeMissile(Mobj m) {
    m.momX = 0;
    m.momY = 0;
    m.momZ = 0;
    m.flags &= ~MobjFlags.missile;
    _enterMobjState(m, MobjState.death);
    if (m.state != MobjState.death) m.removed = true;
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
    final int remainingHealth = target.health - damage;
    target.health = remainingHealth;
    final bool sameSpecies =
        target.info.isMonster &&
        source.info.isMonster &&
        target.info.id == source.info.id;
    if (!identical(target, source) &&
        (!sameSpecies || target.threshold == 0) &&
        source.health > 0) {
      target.target = source;
      target.threshold = _baseMonsterThreshold;
      if (target.state == MobjState.spawn) {
        _enterMobjState(target, MobjState.see);
      }
    }
    if (target.health <= 0) {
      target.health = 0;
      if ((target.info.flags & MobjFlags.countKill) != 0) _killCount++;
      final MobjState deathState = remainingHealth < -target.info.spawnHealth
          ? MobjState.gibbedDeath
          : MobjState.death;
      target.flags |= MobjFlags.corpse | MobjFlags.dropOff;
      target.flags &= ~(MobjFlags.shootable | MobjFlags.solid);
      target.height ~/= 4;
      _enterMobjState(target, deathState);
      _emitMobjSound('DSPODTH1', target);
    } else if (_random.chance(target.info.painChance)) {
      _enterMobjState(target, MobjState.pain);
    }
  }

  void _damagePlayer(int damage, {Mobj? source}) {
    final bool wasAlive = _health > 0;
    if (!wasAlive) return;
    final int possibleSave = damage ~/ 3;
    final int saved = _armor < possibleSave ? _armor : possibleSave;
    _armor -= saved;
    _health -= damage - saved;
    if (_health < 0) {
      _health = 0;
    }
    _playerMobj.health = _health;
    if (wasAlive) _emitPlayerSound('DSPLPAIN');
    if (_health == 0) {
      _playerMobj.flags &= ~MobjFlags.shootable;
      _playerMobj.state = MobjState.death;
      _playerMobj.momX = 0;
      _playerMobj.momY = 0;
      _bob = 0;
      _deathViewHeight = _livingViewHeight;
      _pendingWeapon = null;
      _weaponPhase = WeaponPhase.ready;
      _weaponState = 0;
      _weaponFrame = 0;
      _weaponTics = -1;
      _flashFrame = -1;
      _flashTics = 0;
      _flashSequence = const <_WeaponFlashState>[];
      for (final Mobj monster in _mobjs) {
        if (identical(monster.target, _playerMobj)) {
          monster.target = null;
          monster.threshold = 0;
        }
      }
      for (var sector = 0; sector < _sectorSoundTargets.length; sector++) {
        if (identical(_sectorSoundTargets[sector], _playerMobj)) {
          _sectorSoundTargets[sector] = null;
        }
      }
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
          _queueWeapon(Weapon.shotgun);
        case MobjType.chaingun:
          _bullets += 20;
          _ownedWeapons.add(Weapon.chaingun);
          _queueWeapon(Weapon.chaingun);
        case MobjType.megaHealth:
          _health = (_health + 100 > 200) ? 200 : _health + 100;
        case MobjType.soulSphere:
          _health = (_health + 100 > 200) ? 200 : _health + 100;
        case MobjType.megaSphere:
          _health = 200;
          _armor = 200;
        case MobjType.backpack:
          _bullets += 10;
          _shells += 4;
        case MobjType.berserk:
          if (_health < 100) _health = 100;
          _setWeapon(Weapon.fist);
        case MobjType.invulnerability ||
            MobjType.invisibility ||
            MobjType.radiationSuit ||
            MobjType.computerMap ||
            MobjType.lightAmplification:
          // Their timed/UI effects are outside the current E1M1 runtime
          // subset, but they are still collectable special artifacts.
          break;
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
      if ((m.info.flags & MobjFlags.countItem) != 0) _itemCount++;
      _emitPlayerSound('DSITEMUP');
      m.removed = true;
    }
  }

  MobjView _view(Mobj m) => MobjView(
    id: m.id,
    x: m.x,
    y: m.y,
    z: m.z,
    angle: m.angle,
    sprite: m.spriteName,
    frame: m.spriteFrame,
    flags: m.flags,
    health: m.health,
    height: m.height,
    fullBright: m.fullBright,
    lightLevel: _runtime.sectors[m.sectorIndex].lightLevel,
  );

  void _emitPlayerSound(String soundId) {
    _appendSound(
      SoundEvent(
        soundId: soundId,
        origin: SoundOrigin.player,
        sourceId: SoundEvent.playerSourceId,
        tic: _tic,
        x: _playerMobj.x,
        y: _playerMobj.y,
        z: _playerMobj.z,
      ),
    );
  }

  void _emitMobjSound(String soundId, Mobj m) {
    _appendSound(
      SoundEvent(
        soundId: soundId,
        origin: SoundOrigin.world,
        sourceId: m.id,
        tic: _tic,
        x: m.x,
        y: m.y,
        z: m.z,
      ),
    );
  }

  void _emitSectorSound(String soundId, int sectorIndex) {
    final SectorRuntime sector = _runtime.sectors[sectorIndex];
    if (sector.touchingLinedefs.isEmpty) {
      _appendSound(
        SoundEvent(
          soundId: soundId,
          origin: SoundOrigin.world,
          sourceId: SoundEvent.sectorSourceId(sectorIndex),
          tic: _tic,
          x: 0,
          y: 0,
          z: sector.floorHeight,
        ),
      );
      return;
    }
    final Linedef line = _runtime.map.linedefs[sector.touchingLinedefs.first];
    final MapVertex a = _runtime.map.vertices[line.v1];
    final MapVertex b = _runtime.map.vertices[line.v2];
    _appendSound(
      SoundEvent(
        soundId: soundId,
        origin: SoundOrigin.world,
        sourceId: SoundEvent.sectorSourceId(sectorIndex),
        tic: _tic,
        x: toFixed(a.x + b.x) ~/ 2,
        y: toFixed(a.y + b.y) ~/ 2,
        z: sector.floorHeight,
      ),
    );
  }

  void _emitNonPositionalSound(String soundId) {
    _appendSound(
      SoundEvent(
        soundId: soundId,
        origin: SoundOrigin.nonPositional,
        sourceId: SoundEvent.nonPositionalSourceId,
        tic: _tic,
        x: 0,
        y: 0,
        z: 0,
      ),
    );
  }

  void _appendSound(SoundEvent event) {
    if (_sounds.length < maxSoundJournalLength) {
      _sounds.add(event);
      return;
    }

    final int expendable = _sounds.indexWhere(
      (SoundEvent pending) => !_isCriticalSound(pending.soundId),
    );
    if (expendable >= 0) {
      _sounds.removeAt(expendable);
      _sounds.add(event);
      _droppedSoundEvents++;
      return;
    }
    if (_isCriticalSound(event.soundId)) {
      _sounds.removeAt(0);
      _sounds.add(event);
    }
    _droppedSoundEvents++;
  }

  static bool _isCriticalSound(String soundId) => switch (soundId) {
    'DSDOROPN' ||
    'DSDORCLS' ||
    'DSPSTART' ||
    'DSPSTOP' ||
    'DSPODTH1' ||
    'DSSWTCHX' => true,
    _ => false,
  };

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
    add(config.maxSoundPropagationVisits);
    add(_nextId);
    add(_useHeld ? 1 : 0);
    add(_health);
    add(_armor);
    add(_bullets);
    add(_shells);
    add(_weapon.index);
    add(_pendingWeapon?.index ?? -1);
    add(_weaponPhase.index);
    add(_weaponState);
    add(_weaponFrame);
    add(_weaponTics);
    add(_weaponY);
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
    // Preserve the established replay schema for the overwhelmingly common
    // no-button state, while making every active future-affecting button timer
    // distinguishable. The sentinel prevents aliasing with preceding words.
    if (_pressedSwitches.isNotEmpty) {
      add(0x53574954); // "SWIT"
      add(_pressedSwitches.length);
      for (final int line in _pressedSwitches.keys.toList()..sort()) {
        final _PressedSwitch pressed = _pressedSwitches[line]!;
        add(line);
        add(pressed.sidedef);
        add(pressed.slot.index);
        add(pressed.remaining);
      }
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
      add(_sectorSoundTargets[s.index]?.id ?? 0);
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
      add(m.frameState);
      add(m.flags);
      add(m.spriteFrame);
      add(m.momX);
      add(m.momY);
      add(m.momZ);
      add(m.sectorIndex);
      add(m.floorZ);
      add(m.ceilingZ);
      add(m.dropOffZ);
      add(m.height);
      add(m.stateTics);
      add(m.reactionTime);
      add(m.threshold);
      add(m.moveDir);
      add(m.moveCount);
      add(m.target?.id ?? 0);
      add(m.owner?.id ?? 0);
      add(m.ambush ? 1 : 0);
      add(m.removed ? 1 : 0);
    }
    // _bob is a pure function of already-hashed tic and player momentum.
    // _deathViewHeight is renderer-only camera descent and cannot influence a
    // future tic, so it is deliberately excluded with the output journals.
    // _changes, _sounds and _switchChanges are output journals: consuming them cannot affect simulation
    // state or future tics, so including it would make replay hashes depend on
    // renderer polling rather than seed + TicCmd stream.
    return h;
  }
}

class _PressedSwitch {
  _PressedSwitch({
    required this.linedef,
    required this.sidedef,
    required this.slot,
    required this.offName,
    required this.onName,
    required this.remaining,
  });

  final int linedef;
  final int sidedef;
  final SwitchTextureSlot slot;
  final String offName;
  final String onName;
  int remaining;
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
  bool get isClosing => _closing;
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
bool _isSwitchDoorSpecial(int special) =>
    <int>{61, 99, 103, 134}.contains(special);
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
bool _isRepeatableSwitchSpecial(int special) =>
    <int>{61, 62, 99, 123, 134}.contains(special);
bool _isOneShotSwitchSpecial(int special) =>
    <int>{11, 21, 24, 51, 103, 122}.contains(special);

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
const MobjInfo _puffInfo = MobjInfo(
  id: MobjType.puff,
  doomEdNum: -1,
  spawnHealth: 1,
  radius: 0,
  height: 0,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'PUFF',
  flags: MobjFlags.noSector | MobjFlags.noBlockmap | MobjFlags.noGravity,
);
const MobjInfo _bloodInfo = MobjInfo(
  id: MobjType.blood,
  doomEdNum: -1,
  spawnHealth: 1,
  radius: 0,
  height: 0,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'BLUD',
  flags: MobjFlags.noSector | MobjFlags.noBlockmap | MobjFlags.noGravity,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
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
  flags: MobjFlags.special,
);
const MobjInfo _soulSphereInfo = MobjInfo(
  id: MobjType.soulSphere,
  doomEdNum: 2013,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'SOUL',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _megaSphereInfo = MobjInfo(
  id: MobjType.megaSphere,
  doomEdNum: 83,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'MEGA',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _backpackInfo = MobjInfo(
  id: MobjType.backpack,
  doomEdNum: 8,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'BPAK',
  flags: MobjFlags.special,
);
const MobjInfo _invulnerabilityInfo = MobjInfo(
  id: MobjType.invulnerability,
  doomEdNum: 2022,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'PINV',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _berserkInfo = MobjInfo(
  id: MobjType.berserk,
  doomEdNum: 2023,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'PSTR',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _invisibilityInfo = MobjInfo(
  id: MobjType.invisibility,
  doomEdNum: 2024,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'PINS',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _radiationSuitInfo = MobjInfo(
  id: MobjType.radiationSuit,
  doomEdNum: 2025,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'SUIT',
  flags: MobjFlags.special,
);
const MobjInfo _computerMapInfo = MobjInfo(
  id: MobjType.computerMap,
  doomEdNum: 2026,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'PMAP',
  flags: MobjFlags.special | MobjFlags.countItem,
);
const MobjInfo _lightAmplificationInfo = MobjInfo(
  id: MobjType.lightAmplification,
  doomEdNum: 2045,
  spawnHealth: 1,
  radius: 20,
  height: 16,
  mass: 0,
  speed: 0,
  reactionTime: 0,
  painChance: 0,
  damage: 0,
  spriteName: 'PVIS',
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
  2013 => _soulSphereInfo,
  83 => _megaSphereInfo,
  8 => _backpackInfo,
  2022 => _invulnerabilityInfo,
  2023 => _berserkInfo,
  2024 => _invisibilityInfo,
  2025 => _radiationSuitInfo,
  2026 => _computerMapInfo,
  2045 => _lightAmplificationInfo,
  2035 => _barrelInfo,
  _ => null,
};
