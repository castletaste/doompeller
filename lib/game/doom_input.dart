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
  static const int axisScale = 1000;
  static const int moveSpeed = 25;
  static const int runMoveSpeed = 50;
  static const int strafeSpeed = 24;
  static const int runStrafeSpeed = 40;
  static const int turnSpeed = 640;

  static final Object _defaultOwner = Object();

  final Map<DoomControl, Set<Object>> _heldOwners =
      <DoomControl, Set<Object>>{};
  final Map<Object, int> _attackPendingByOwner = <Object, int>{};
  bool _usePending = false;
  bool _pausePending = false;
  int? _weaponPending;
  int _pointerTurnPending = 0;
  int _analogForwardAxis = 0;
  int _analogSideAxis = 0;

  void press(DoomControl control) => pressOwned(_defaultOwner, control);

  /// Holds [control] for one device owner without clobbering other owners.
  void pressOwned(Object owner, DoomControl control) {
    final Set<Object> owners = _heldOwners.putIfAbsent(
      control,
      () => <Object>{},
    );
    final bool newlyHeld = owners.add(owner);
    if (newlyHeld && control == DoomControl.attack) {
      _attackPendingByOwner.update(
        owner,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void release(DoomControl control) => releaseOwned(_defaultOwner, control);

  /// Releases only [owner]'s hold.
  ///
  /// A normal release preserves a quick attack tap until the next tic. A
  /// cancelled pointer must discard only its own pending tap.
  void releaseOwned(
    Object owner,
    DoomControl control, {
    bool cancelled = false,
  }) {
    final Set<Object>? owners = _heldOwners[control];
    owners?.remove(owner);
    if (owners != null && owners.isEmpty) {
      _heldOwners.remove(control);
    }
    if (cancelled && control == DoomControl.attack) {
      final int pending = _attackPendingByOwner[owner] ?? 0;
      if (pending <= 1) {
        _attackPendingByOwner.remove(owner);
      } else {
        _attackPendingByOwner[owner] = pending - 1;
      }
    }
  }

  /// Sets signed touch-stick axes in the inclusive [-1000, 1000] range.
  void setAnalogAxes({required int forward, required int side}) {
    if (forward < -axisScale || forward > axisScale) {
      throw RangeError.range(forward, -axisScale, axisScale, 'forward');
    }
    if (side < -axisScale || side > axisScale) {
      throw RangeError.range(side, -axisScale, axisScale, 'side');
    }
    _analogForwardAxis = forward;
    _analogSideAxis = side;
  }

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
        _isHeld(DoomControl.runLeft) || _isHeld(DoomControl.runRight);
    final int forwardSpeed = running ? runMoveSpeed : moveSpeed;
    final int sideSpeed = running ? runStrafeSpeed : strafeSpeed;
    final int digitalForward =
        (_isHeld(DoomControl.forward) ? forwardSpeed : 0) -
        (_isHeld(DoomControl.backward) ? forwardSpeed : 0);
    final int digitalSide =
        (_isHeld(DoomControl.strafeRight) ? sideSpeed : 0) -
        (_isHeld(DoomControl.strafeLeft) ? sideSpeed : 0);
    final int forward =
        (digitalForward + _scaleAxis(_analogForwardAxis, forwardSpeed))
            .clamp(-forwardSpeed, forwardSpeed)
            .toInt();
    final int side = (digitalSide + _scaleAxis(_analogSideAxis, sideSpeed))
        .clamp(-sideSpeed, sideSpeed)
        .toInt();
    final int turn =
        (_isHeld(DoomControl.turnLeft) ? turnSpeed : 0) -
        (_isHeld(DoomControl.turnRight) ? turnSpeed : 0) +
        _pointerTurnPending;
    var buttons =
        _isHeld(DoomControl.attack) || _attackPendingByOwner.isNotEmpty
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
    _attackPendingByOwner.clear();
    _usePending = false;
    _weaponPending = null;
    _pointerTurnPending = 0;
    return frame;
  }

  /// Clears every device-derived intent after focus or lifecycle loss.
  ///
  /// Nothing queued before the loss may leak into a later simulation tic.
  void clear() {
    _heldOwners.clear();
    _attackPendingByOwner.clear();
    _usePending = false;
    _pausePending = false;
    _weaponPending = null;
    _pointerTurnPending = 0;
    _analogForwardAxis = 0;
    _analogSideAxis = 0;
  }

  bool _isHeld(DoomControl control) =>
      _heldOwners[control]?.isNotEmpty ?? false;

  static int _scaleAxis(int axis, int speed) => axis * speed ~/ axisScale;
}
