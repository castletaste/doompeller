import 'config.dart';
import 'views.dart';

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
const List<_WeaponFlashState> _rocketFlash = <_WeaponFlashState>[
  _WeaponFlashState(0, 8),
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
const List<_WeaponFireState> _rocketLauncherStates = <_WeaponFireState>[
  _WeaponFireState(0, 8),
  _WeaponFireState(1, 1, action: _WeaponAction.fire, flash: _rocketFlash),
  _WeaponFireState(0, 12),
  _WeaponFireState(0, 0, action: _WeaponAction.refire),
];
const List<_WeaponFireState> _chainsawStates = <_WeaponFireState>[
  _WeaponFireState(0, 4, action: _WeaponAction.fire),
  _WeaponFireState(1, 4, action: _WeaponAction.fire),
  _WeaponFireState(1, 0, action: _WeaponAction.refire),
];

/// Owns weapon timing and presentation cursors. Ammo, RNG and combat remain
/// in GameState; callbacks preserve their exact consumption order.
final class PlayerWeaponState {
  PlayerWeaponState({
    required this.readAmmo,
    required this.fire,
    required this.raised,
  });
  final Ammo Function() readAmmo;
  final void Function() fire;
  final void Function() raised;
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

  Weapon get current => _weapon;
  Weapon? get pending => _pendingWeapon;
  WeaponPhase get phase => _weaponPhase;
  int get stateIndex => _weaponState;
  int get frame => _weaponFrame;
  int get tics => _weaponTics;
  int get y => _weaponY;
  int get flashFrame => _flashFrame;

  /// Entry inventory restore is silent and leaves the initial ready pose.
  void restoreCurrent(Weapon weapon) => _weapon = weapon;

  void cancelOnDeath() {
    _pendingWeapon = null;
    _weaponPhase = WeaponPhase.ready;
    _weaponState = 0;
    _weaponFrame = 0;
    _weaponTics = -1;
    _flashFrame = -1;
    _flashTics = 0;
    _flashSequence = const <_WeaponFlashState>[];
  }

  void queue(Weapon requested) {
    if (requested == _weapon || requested == _pendingWeapon) {
      return;
    }
    _pendingWeapon = requested;
    if (_weaponPhase == WeaponPhase.ready) {
      _weaponPhase = WeaponPhase.lowering;
      _weaponTics = 1;
    }
  }

  void equip(Weapon requested) {
    if (requested == _weapon) return;
    _weapon = requested;
    raised();
  }

  void tick(bool attacking) {
    _tickWeaponFlash();
    switch (_weaponPhase) {
      case WeaponPhase.lowering:
        _weaponY += _weaponMovePerTic;
        if (_weaponY >= _weaponBottom) {
          final Weapon next = _pendingWeapon ?? _weapon;
          _pendingWeapon = null;
          equip(next);
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
    if (_weapon == Weapon.shotgun && readAmmo().shells == 0) {
      _pendingWeapon = Weapon.pistol;
      _weaponPhase = WeaponPhase.lowering;
      return;
    }
    if (_weapon == Weapon.rocketLauncher && readAmmo().rockets == 0) {
      _pendingWeapon = readAmmo().bullets > 0 ? Weapon.pistol : Weapon.fist;
      _weaponPhase = WeaponPhase.lowering;
      return;
    }
    if ((_weapon == Weapon.pistol || _weapon == Weapon.chaingun) &&
        readAmmo().bullets == 0) {
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
    Weapon.rocketLauncher => _rocketLauncherStates,
    Weapon.chainsaw => _chainsawStates,
  };

  void _enterWeaponState(int index, {required bool attacking}) {
    final _WeaponFireState state = _weaponFireStates(_weapon)[index];
    _weaponState = index;
    _weaponFrame = state.frame;
    _weaponTics = state.tics;
    switch (state.action) {
      case _WeaponAction.fire:
        _startWeaponFlash(state.flash);
        fire();
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
}
