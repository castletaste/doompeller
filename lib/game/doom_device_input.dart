import 'package:flutter/services.dart';

import 'doom_input.dart';

enum DoomDeviceAction {
  ignored,
  handled,
  restart,
  toggleAutomap,
  zoomIn,
  zoomOut,
}

/// Owns keyboard, mouse and touch latches. The runtime supplies gameplay gates
/// and interprets navigation actions; each device releases only its own input.
final class DoomDeviceInput {
  DoomDeviceInput(this.input);

  final DoomInputState input;
  final Map<PhysicalKeyboardKey, DoomControl> _keyboardControls = {};
  final Map<int, Set<DoomControl>> _touchControls = {};
  int? _touchMovementPointer;

  void clear() {
    _keyboardControls.clear();
    _touchControls.clear();
    _touchMovementPointer = null;
    input.clear();
  }

  void setPointerAttack(bool pressed, {bool cancelled = false}) {
    if (pressed) {
      input.pressOwned(_mouseAttackOwner, DoomControl.attack);
    } else {
      input.releaseOwned(
        _mouseAttackOwner,
        DoomControl.attack,
        cancelled: cancelled,
      );
    }
  }

  void setTouchMovement(
    int pointer, {
    required int forward,
    required int side,
    required bool enabled,
  }) {
    _validatePointer(pointer);
    if (forward < -DoomInputState.axisScale ||
        forward > DoomInputState.axisScale) {
      throw RangeError.range(
        forward,
        -DoomInputState.axisScale,
        DoomInputState.axisScale,
        'forward',
      );
    }
    if (side < -DoomInputState.axisScale || side > DoomInputState.axisScale) {
      throw RangeError.range(
        side,
        -DoomInputState.axisScale,
        DoomInputState.axisScale,
        'side',
      );
    }
    if (!enabled) return;
    final owner = _touchMovementPointer;
    if (owner != null && owner != pointer) return;
    _touchMovementPointer = pointer;
    input.setAnalogAxes(forward: forward, side: side);
  }

  DoomDeviceAction pressTouchControl(
    int pointer,
    DoomControl control, {
    required bool enabled,
    required bool playerDead,
  }) {
    _validatePointer(pointer);
    if (!enabled) return DoomDeviceAction.ignored;
    if (control == DoomControl.attack && playerDead) {
      return DoomDeviceAction.restart;
    }
    final controls = _touchControls.putIfAbsent(pointer, () => <DoomControl>{});
    if (controls.add(control)) input.pressOwned(_touchOwner(pointer), control);
    return DoomDeviceAction.handled;
  }

  void releaseTouchPointer(int pointer, {bool cancelled = false}) {
    _validatePointer(pointer);
    final controls = _touchControls.remove(pointer);
    if (controls != null) {
      final owner = _touchOwner(pointer);
      for (final control in controls) {
        input.releaseOwned(owner, control, cancelled: cancelled);
      }
    }
    if (_touchMovementPointer == pointer) {
      _touchMovementPointer = null;
      input.setAnalogAxes(forward: 0, side: 0);
    }
  }

  void clearTouchInput() {
    for (final pointer in _touchControls.keys.toList(growable: false)) {
      releaseTouchPointer(pointer, cancelled: true);
    }
    final pointer = _touchMovementPointer;
    if (pointer != null) releaseTouchPointer(pointer, cancelled: true);
  }

  DoomDeviceAction handle(
    KeyEvent event, {
    required bool playerDead,
    required bool paused,
    required bool levelComplete,
  }) {
    final bool down = event is KeyDownEvent || event is KeyRepeatEvent;
    final bool up = event is KeyUpEvent;
    final key = event.logicalKey;
    final physicalKey = event.physicalKey;
    final Object owner = _keyboardOwner(physicalKey);
    if (up) {
      // The logical key may change with the active keyboard layout between
      // down and up. The physical-key mapping captured on key-down therefore
      // takes precedence over resolving the release event again.
      final DoomControl? mapped = _keyboardControls.remove(physicalKey);
      if (mapped != null) {
        input.releaseOwned(owner, mapped);
        return DoomDeviceAction.handled;
      }
    }
    if (down &&
        event is! KeyRepeatEvent &&
        key == LogicalKeyboardKey.escape &&
        !levelComplete) {
      input.triggerPause();
      return DoomDeviceAction.handled;
    }
    if (paused || levelComplete) return DoomDeviceAction.handled;
    if (down &&
        event is! KeyRepeatEvent &&
        playerDead &&
        (_isAttackKey(key, physicalKey) ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.keyE ||
            physicalKey == PhysicalKeyboardKey.keyE)) {
      return DoomDeviceAction.restart;
    }
    final DoomControl? control = _resolveKeyboardControl(key, physicalKey);
    if (control != null) {
      if (down) {
        final DoomControl? previous = _keyboardControls[physicalKey];
        _keyboardControls[physicalKey] = control;
        if (previous != null && previous != control) {
          input.releaseOwned(owner, previous, cancelled: true);
        }
        input.pressOwned(owner, control);
      }
      return DoomDeviceAction.handled;
    }
    if (down && event is! KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.keyE ||
          physicalKey == PhysicalKeyboardKey.keyE) {
        input.triggerUse();
        return DoomDeviceAction.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        return DoomDeviceAction.toggleAutomap;
      }
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd) {
        return DoomDeviceAction.zoomIn;
      }
      if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        return DoomDeviceAction.zoomOut;
      }
      final int? slot = switch (key) {
        LogicalKeyboardKey.digit1 => 0,
        LogicalKeyboardKey.digit2 => 1,
        LogicalKeyboardKey.digit3 => 2,
        LogicalKeyboardKey.digit4 => 3,
        LogicalKeyboardKey.digit5 => 4,
        LogicalKeyboardKey.digit6 => 5,
        _ => null,
      };
      if (slot != null) {
        input.selectWeapon(slot);
        return DoomDeviceAction.handled;
      }
    }
    return DoomDeviceAction.ignored;
  }

  static DoomControl? _resolveKeyboardControl(
    LogicalKeyboardKey key,
    PhysicalKeyboardKey physicalKey,
  ) {
    // Physical WASD wins when both identities describe movement, keeping the
    // controls layout-stable. Logical keys remain aliases and cover arrows.
    if (physicalKey == PhysicalKeyboardKey.keyW) {
      return DoomControl.forward;
    }
    if (physicalKey == PhysicalKeyboardKey.keyS) {
      return DoomControl.backward;
    }
    if (physicalKey == PhysicalKeyboardKey.keyA) {
      return DoomControl.strafeLeft;
    }
    if (physicalKey == PhysicalKeyboardKey.keyD) {
      return DoomControl.strafeRight;
    }
    if (key == LogicalKeyboardKey.keyW || key == LogicalKeyboardKey.arrowUp) {
      return DoomControl.forward;
    }
    if (key == LogicalKeyboardKey.keyS || key == LogicalKeyboardKey.arrowDown) {
      return DoomControl.backward;
    }
    if (key == LogicalKeyboardKey.keyA) return DoomControl.strafeLeft;
    if (key == LogicalKeyboardKey.keyD) return DoomControl.strafeRight;
    if (key == LogicalKeyboardKey.arrowLeft) return DoomControl.turnLeft;
    if (key == LogicalKeyboardKey.arrowRight) return DoomControl.turnRight;
    if (key == LogicalKeyboardKey.shiftLeft) return DoomControl.runLeft;
    if (key == LogicalKeyboardKey.shiftRight) return DoomControl.runRight;
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        _isAttackKey(key, physicalKey)) {
      return DoomControl.attack;
    }
    return null;
  }

  static bool _isAttackKey(
    LogicalKeyboardKey key,
    PhysicalKeyboardKey physicalKey,
  ) =>
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      physicalKey == PhysicalKeyboardKey.enter ||
      physicalKey == PhysicalKeyboardKey.numpadEnter;

  static void _validatePointer(int pointer) {
    if (pointer < 0) throw RangeError.value(pointer, 'pointer');
  }

  static Object _keyboardOwner(PhysicalKeyboardKey key) =>
      (_DeviceInputKind.keyboard, key);

  static Object _touchOwner(int pointer) => (_DeviceInputKind.touch, pointer);

  static const Object _mouseAttackOwner = (_DeviceInputKind.mouse, 0);
}

enum _DeviceInputKind { keyboard, mouse, touch }
