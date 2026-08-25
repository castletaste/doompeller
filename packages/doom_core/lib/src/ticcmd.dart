import 'package:meta/meta.dart';

/// Simulation tick rate. Every gameplay decision happens at exactly this rate;
/// rendering interpolates between ticks.
const int kTicRate = 35;

abstract final class Buttons {
  static const int attack = 0x01;
  static const int use = 0x02;
  static const int changeWeapon = 0x04;

  /// Weapon slot occupies bits 3..5 when [changeWeapon] is set.
  static const int weaponShift = 3;
  static const int weaponMask = 0x38;
}

/// One tick of player intent.
///
/// This is the only input the simulation accepts. Recording a stream of these
/// plus the starting seed is a complete replay, which is what makes the
/// determinism test possible.
@immutable
class TicCmd {
  const TicCmd({
    this.forwardMove = 0,
    this.sideMove = 0,
    this.angleTurn = 0,
    this.buttons = 0,
  });

  static const TicCmd empty = TicCmd();

  /// Forward/back impulse in the original's per-tic units.
  final int forwardMove;

  /// Strafe impulse.
  final int sideMove;

  /// Turn delta applied to the player angle, in BAM >> 16 units.
  final int angleTurn;

  final int buttons;

  bool get attacking => (buttons & Buttons.attack) != 0;
  bool get using => (buttons & Buttons.use) != 0;
  bool get changingWeapon => (buttons & Buttons.changeWeapon) != 0;
  int get requestedWeapon =>
      (buttons & Buttons.weaponMask) >> Buttons.weaponShift;

  TicCmd copyWith({
    int? forwardMove,
    int? sideMove,
    int? angleTurn,
    int? buttons,
  }) {
    return TicCmd(
      forwardMove: forwardMove ?? this.forwardMove,
      sideMove: sideMove ?? this.sideMove,
      angleTurn: angleTurn ?? this.angleTurn,
      buttons: buttons ?? this.buttons,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TicCmd &&
      forwardMove == other.forwardMove &&
      sideMove == other.sideMove &&
      angleTurn == other.angleTurn &&
      buttons == other.buttons;

  @override
  int get hashCode => Object.hash(forwardMove, sideMove, angleTurn, buttons);

  @override
  String toString() =>
      'TicCmd(fwd: $forwardMove, side: $sideMove, turn: $angleTurn, btn: $buttons)';
}
