import 'package:doom_core/doom_core.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rocket and chainsaw slots remain one-shot TicCmd inputs', () {
    for (final int slot in <int>[4, 5]) {
      final input = DoomInputState()..selectWeapon(slot);
      final command = input.consume().command;
      expect(command.changingWeapon, isTrue);
      expect(command.requestedWeapon, slot);
      expect(input.consume().command, TicCmd.empty);
    }
    expect(() => DoomInputState().selectWeapon(6), throwsRangeError);
  });
  test('held movement and attack become the sole TicCmd input', () {
    final input = DoomInputState()
      ..press(DoomControl.forward)
      ..press(DoomControl.strafeLeft)
      ..press(DoomControl.turnRight)
      ..press(DoomControl.attack);

    final first = input.consume();
    expect(first.command.forwardMove, DoomInputState.moveSpeed);
    expect(first.command.sideMove, -DoomInputState.strafeSpeed);
    expect(first.command.angleTurn, -DoomInputState.turnSpeed);
    expect(first.command.attacking, isTrue);

    input.release(DoomControl.attack);
    expect(input.consume().command.attacking, isFalse);
  });

  test('attack press and release before a tic is consumed exactly once', () {
    final input = DoomInputState()
      ..press(DoomControl.attack)
      ..release(DoomControl.attack);

    expect(input.consume().command.attacking, isTrue);
    expect(input.consume().command.attacking, isFalse);
  });

  test('owned holds release independently and cancelled taps do not leak', () {
    final input = DoomInputState();
    final keyboard = Object();
    final mouse = Object();
    final touch = Object();

    input
      ..pressOwned(keyboard, DoomControl.attack)
      ..pressOwned(mouse, DoomControl.attack)
      ..releaseOwned(mouse, DoomControl.attack, cancelled: true)
      ..releaseOwned(keyboard, DoomControl.attack);
    expect(input.consume().command.attacking, isTrue);
    expect(input.consume().command.attacking, isFalse);

    input
      ..pressOwned(touch, DoomControl.attack)
      ..releaseOwned(touch, DoomControl.attack, cancelled: true);
    expect(input.consume().command.attacking, isFalse);

    input
      ..pressOwned(mouse, DoomControl.attack)
      ..releaseOwned(mouse, DoomControl.attack)
      ..pressOwned(mouse, DoomControl.attack)
      ..releaseOwned(mouse, DoomControl.attack, cancelled: true);
    expect(
      input.consume().command.attacking,
      isTrue,
      reason: 'cancelling a later press cannot erase an earlier normal tap',
    );
    expect(input.consume().command.attacking, isFalse);

    input
      ..pressOwned(keyboard, DoomControl.forward)
      ..pressOwned(touch, DoomControl.forward)
      ..releaseOwned(touch, DoomControl.forward);
    expect(input.consume().command.forwardMove, DoomInputState.moveSpeed);
    input.releaseOwned(keyboard, DoomControl.forward);
    expect(input.consume().command.forwardMove, 0);
  });

  test('use, weapon, pointer turn and pause are one-shot', () {
    final input = DoomInputState()
      ..triggerUse()
      ..selectWeapon(2)
      ..addPointerTurn(77)
      ..triggerPause();

    final first = input.consume();
    expect(first.command.using, isTrue);
    expect(first.command.changingWeapon, isTrue);
    expect(first.command.requestedWeapon, 2);
    expect(first.command.angleTurn, 77);
    expect(first.togglePause, isTrue);

    final second = input.consume();
    expect(second.command, TicCmd.empty);
    expect(second.togglePause, isFalse);
  });

  test('opposite held directions cancel without leaving latent input', () {
    final input = DoomInputState()
      ..press(DoomControl.forward)
      ..press(DoomControl.backward)
      ..press(DoomControl.turnLeft)
      ..press(DoomControl.turnRight);
    expect(input.consume().command, TicCmd.empty);
  });

  test('either Shift selects run speeds until both are released', () {
    final input = DoomInputState()
      ..press(DoomControl.forward)
      ..press(DoomControl.strafeRight)
      ..press(DoomControl.runLeft);

    final leftShift = input.consume().command;
    expect(
      (leftShift.forwardMove, leftShift.sideMove),
      (DoomInputState.runMoveSpeed, DoomInputState.runStrafeSpeed),
    );

    input
      ..press(DoomControl.runRight)
      ..release(DoomControl.runLeft);
    final rightShift = input.consume().command;
    expect(rightShift.forwardMove, DoomInputState.runMoveSpeed);
    expect(rightShift.sideMove, DoomInputState.runStrafeSpeed);

    input.release(DoomControl.runRight);
    final walking = input.consume().command;
    expect(walking.forwardMove, DoomInputState.moveSpeed);
    expect(walking.sideMove, DoomInputState.strafeSpeed);
  });

  test('integer analog axes combine, oppose, clamp, and scale with run', () {
    final input = DoomInputState()..setAnalogAxes(forward: 500, side: -250);
    final analog = input.consume().command;
    expect((analog.forwardMove, analog.sideMove), (12, -6));

    input
      ..press(DoomControl.backward)
      ..setAnalogAxes(forward: 1000, side: 0);
    expect(input.consume().command.forwardMove, 0);
    input
      ..release(DoomControl.backward)
      ..press(DoomControl.forward)
      ..setAnalogAxes(forward: 1000, side: 1000);
    final clamped = input.consume().command;
    expect(clamped.forwardMove, DoomInputState.moveSpeed);
    expect(clamped.sideMove, DoomInputState.strafeSpeed);

    input.press(DoomControl.runLeft);
    final running = input.consume().command;
    expect(running.forwardMove, DoomInputState.runMoveSpeed);
    expect(running.sideMove, DoomInputState.runStrafeSpeed);
  });

  test('analog axes reject invalid values and clear with device state', () {
    final input = DoomInputState();
    expect(
      () => input.setAnalogAxes(forward: DoomInputState.axisScale + 1, side: 0),
      throwsRangeError,
    );
    expect(
      () =>
          input.setAnalogAxes(forward: 0, side: -DoomInputState.axisScale - 1),
      throwsRangeError,
    );

    input
      ..setAnalogAxes(forward: -1000, side: 1000)
      ..clear();
    expect(input.consume().command, TicCmd.empty);
  });

  test('focus loss clears held and queued input before the next tic', () {
    final input = DoomInputState()
      ..press(DoomControl.forward)
      ..press(DoomControl.runRight)
      ..press(DoomControl.attack)
      ..triggerUse()
      ..selectWeapon(3)
      ..addPointerTurn(99)
      ..triggerPause()
      ..clear();

    final frame = input.consume();
    expect(frame.command, TicCmd.empty);
    expect(frame.togglePause, isFalse);
  });
}
