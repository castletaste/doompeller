import 'package:doom_core/doom_core.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
