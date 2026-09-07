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

/// Owns device latches; the runtime interprets navigation and game actions.
final class DoomDeviceInput {
  DoomDeviceInput(this.input);

  final DoomInputState input;
  final Map<PhysicalKeyboardKey, DoomControl> _keyboardControls = {};
  bool _pointerAttackPressed = false;

  void clear() {
    _keyboardControls.clear();
    _pointerAttackPressed = false;
    input.clear();
  }

  void setPointerAttack(bool pressed) {
    _pointerAttackPressed = pressed;
    _syncDeviceControl(DoomControl.attack);
  }

  DoomDeviceAction handle(KeyEvent event, {required bool playerDead}) {
    final bool down = event is KeyDownEvent || event is KeyRepeatEvent;
    final bool up = event is KeyUpEvent;
    final key = event.logicalKey;
    final physicalKey = event.physicalKey;
    if (down &&
        event is! KeyRepeatEvent &&
        playerDead &&
        (key == LogicalKeyboardKey.controlLeft ||
            key == LogicalKeyboardKey.controlRight ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.keyE ||
            physicalKey == PhysicalKeyboardKey.keyE)) {
      return DoomDeviceAction.restart;
    }
    if (up) {
      // The logical key may change with the active keyboard layout between
      // down and up. The physical-key mapping captured on key-down therefore
      // takes precedence over resolving the release event again.
      final DoomControl? mapped = _keyboardControls.remove(physicalKey);
      if (mapped != null) {
        _syncDeviceControl(mapped);
        return DoomDeviceAction.handled;
      }
    }
    final DoomControl? control = _resolveKeyboardControl(key, physicalKey);
    if (control != null) {
      if (down) {
        final DoomControl? previous = _keyboardControls[physicalKey];
        _keyboardControls[physicalKey] = control;
        if (previous != null && previous != control) {
          _syncDeviceControl(previous);
        }
        _syncDeviceControl(control);
      }
      if (up) _syncDeviceControl(control);
      return DoomDeviceAction.handled;
    }
    if (down && event is! KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.keyE ||
          physicalKey == PhysicalKeyboardKey.keyE) {
        input.triggerUse();
        return DoomDeviceAction.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        input.triggerPause();
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
        key == LogicalKeyboardKey.controlRight) {
      return DoomControl.attack;
    }
    return null;
  }

  void _syncDeviceControl(DoomControl control) {
    final bool pressed =
        _keyboardControls.containsValue(control) ||
        (control == DoomControl.attack && _pointerAttackPressed);
    if (pressed) {
      input.press(control);
    } else {
      input.release(control);
    }
  }
}
