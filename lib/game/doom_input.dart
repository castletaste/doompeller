import 'package:doom_core/doom_core.dart';

enum DoomControl {
  forward,
  backward,
  strafeLeft,
  strafeRight,
  turnLeft,
  turnRight,
  runLeft,
  runRight,
  attack,
}

final class DoomInputFrame {
  const DoomInputFrame({required this.command, required this.togglePause});

  final TicCmd command;
  final bool togglePause;
}

/// Mutable device state sampled into one deterministic [TicCmd] per game tic.
final class DoomInputState {
  static const int moveSpeed = 25;
  static const int runMoveSpeed = 50;
  static const int strafeSpeed = 24;
  static const int runStrafeSpeed = 40;
  static const int turnSpeed = 640;

  final Set<DoomControl> _held = <DoomControl>{};
  bool _attackPending = false;
  bool _usePending = false;
  bool _pausePending = false;
  int? _weaponPending;
  int _pointerTurnPending = 0;

  void press(DoomControl control) {
    final bool newlyHeld = _held.add(control);
    if (newlyHeld && control == DoomControl.attack) {
      _attackPending = true;
    }
  }

  void release(DoomControl control) => _held.remove(control);

  void triggerUse() => _usePending = true;

  void triggerPause() => _pausePending = true;

  void selectWeapon(int slot) {
    if (slot < 0 || slot > 5) {
      throw RangeError.range(slot, 0, 5, 'slot');
    }
    _weaponPending = slot;
  }

  void addPointerTurn(int angleTurn) => _pointerTurnPending += angleTurn;

  bool takePauseToggle() {
    final bool pending = _pausePending;
    _pausePending = false;
    return pending;
  }

  DoomInputFrame consume() {
    final bool running =
        _held.contains(DoomControl.runLeft) ||
        _held.contains(DoomControl.runRight);
    final int forwardSpeed = running ? runMoveSpeed : moveSpeed;
    final int sideSpeed = running ? runStrafeSpeed : strafeSpeed;
    final int forward =
        (_held.contains(DoomControl.forward) ? forwardSpeed : 0) -
        (_held.contains(DoomControl.backward) ? forwardSpeed : 0);
    final int side =
        (_held.contains(DoomControl.strafeRight) ? sideSpeed : 0) -
        (_held.contains(DoomControl.strafeLeft) ? sideSpeed : 0);
    final int turn =
        (_held.contains(DoomControl.turnLeft) ? turnSpeed : 0) -
        (_held.contains(DoomControl.turnRight) ? turnSpeed : 0) +
        _pointerTurnPending;
    var buttons = _held.contains(DoomControl.attack) || _attackPending
        ? Buttons.attack
        : 0;
    if (_usePending) {
      buttons |= Buttons.use;
    }
    final int? weapon = _weaponPending;
    if (weapon != null) {
      buttons |= Buttons.changeWeapon | (weapon << Buttons.weaponShift);
    }
    final frame = DoomInputFrame(
      command: TicCmd(
        forwardMove: forward,
        sideMove: side,
        angleTurn: turn,
        buttons: buttons,
      ),
      togglePause: takePauseToggle(),
    );
    _attackPending = false;
    _usePending = false;
    _weaponPending = null;
    _pointerTurnPending = 0;
    return frame;
  }

  /// Clears every device-derived intent after focus or lifecycle loss.
  ///
  /// Nothing queued before the loss may leak into a later simulation tic.
  void clear() {
    _held.clear();
    _attackPending = false;
    _usePending = false;
    _pausePending = false;
    _weaponPending = null;
    _pointerTurnPending = 0;
  }
}
