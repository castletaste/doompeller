import 'package:doom_core/doom_core.dart';

import 'doom_replay_input.dart';

/// Owns the command cursor and terminal result of one replay attempt.
/// Callback delivery stays at the runtime boundary, after the tick driver exits.
final class DoomReplaySession {
  DoomReplaySession(this.input);

  final DoomReplayInput input;
  int _commandCount = 0;
  DoomReplayResult? _result;

  int get commandCount => _commandCount;
  DoomReplayResult? get result => _result;
  bool get hasNext => _result == null && _commandCount < input.commands.length;

  TicCmd takeCommand() {
    if (!hasNext) throw StateError('Replay has no remaining commands.');
    return input.commands[_commandCount++];
  }

  DoomReplayStatus? outcomeAfterTic(GameState game) {
    if (game.levelComplete) {
      if (_commandCount != input.commands.length) {
        return DoomReplayStatus.earlyExit;
      }
      return game.hashState() == input.expectedFinalHash
          ? DoomReplayStatus.complete
          : DoomReplayStatus.hashMismatch;
    }
    return _commandCount == input.commands.length
        ? DoomReplayStatus.earlyEnd
        : null;
  }

  /// Returns a newly captured result once; subsequent calls cannot replace it.
  DoomReplayResult? finish(DoomReplayStatus status, GameState game) {
    if (_result != null) return null;
    return _result = DoomReplayResult(
      status: status,
      commandCount: _commandCount,
      commandTotal: input.commands.length,
      gameTic: game.tic,
      levelComplete: game.levelComplete,
      expectedHash: input.expectedFinalHash,
      actualHash: game.hashState(),
    );
  }

  void reset() {
    _commandCount = 0;
    _result = null;
  }
}
