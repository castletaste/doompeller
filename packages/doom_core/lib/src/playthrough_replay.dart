import 'replay.dart';
import 'ticcmd.dart';

/// The deterministic input stream for [DoomPlaythroughFixture].
///
/// Commands use the same movement values as [DoomInputState] in the Flutter
/// runtime so this exact stream can be sampled through the production input
/// boundary as well as sent directly to [GameState].
abstract final class DoomPlaythroughReplay {
  static const int seed = 0x1971;

  static final List<TicCmd> commands = List<TicCmd>.unmodifiable(<TicCmd>[
    ..._travelTaps(2),
    const TicCmd(buttons: Buttons.use), // Locked-door denial before the key.
    const TicCmd(angleTurn: 32768), // Face west into the guarded key room.
    ..._repeat(140, const TicCmd(buttons: Buttons.attack)),
    ..._travelTaps(3),
    const TicCmd(angleTurn: 32768), // Return east after key and secret.
    ..._travelTaps(3),
    const TicCmd(buttons: Buttons.use),
    ..._repeat(20, TicCmd.empty),
    const TicCmd(forwardMove: 25),
    ..._repeat(20, TicCmd.empty),
    const TicCmd(buttons: Buttons.use), // Lower the lift.
    ..._repeat(12, TicCmd.empty),
    const TicCmd(forwardMove: 25),
    ..._repeat(15, TicCmd.empty),
    ..._repeat(60, TicCmd.empty), // Ride through down/wait/up.
    const TicCmd(forwardMove: 25),
    ..._repeat(20, TicCmd.empty),
    const TicCmd(buttons: Buttons.use),
  ]);

  static CommandReplay replay() =>
      CommandReplay(seed: seed, commands: commands);
}

List<TicCmd> _repeat(int count, TicCmd command) =>
    List<TicCmd>.filled(count, command, growable: false);

List<TicCmd> _travelTaps(int count) => <TicCmd>[
  for (var tap = 0; tap < count; tap++) ...<TicCmd>[
    const TicCmd(forwardMove: 25),
    ..._repeat(20, TicCmd.empty),
  ],
];
