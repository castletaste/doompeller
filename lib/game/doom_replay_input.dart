import 'package:doom_core/doom_core.dart';
import 'package:flutter/foundation.dart';

import 'doom_input.dart';

/// Terminal outcome for an exclusive input-only runtime replay.
enum DoomReplayStatus {
  complete('complete'),
  earlyEnd('early_end'),
  earlyExit('early_exit'),
  hashMismatch('hash_mismatch');

  const DoomReplayStatus(this.label);

  final String label;
}

/// Immutable terminal evidence emitted once by a [DoomReplayInput].
@immutable
final class DoomReplayResult {
  const DoomReplayResult({
    required this.status,
    required this.commandCount,
    required this.commandTotal,
    required this.gameTic,
    required this.levelComplete,
    required this.expectedHash,
    required this.actualHash,
  });

  final DoomReplayStatus status;
  final int commandCount;
  final int commandTotal;
  final int gameTic;
  final bool levelComplete;
  final int expectedHash;
  final int actualHash;

  bool get passed => status == DoomReplayStatus.complete;
}

/// Developer/test command stream sampled instead of device input.
///
/// The runtime copies [commands], supplies exactly one command to each actual
/// simulation tic, and stops at the first terminal outcome. Passing both this
/// and a custom [DoomInputState] is rejected so the two sources cannot mix.
final class DoomReplayInput {
  DoomReplayInput({
    required Iterable<TicCmd> commands,
    required this.expectedFinalHash,
    this.onFinished,
  }) : commands = List<TicCmd>.unmodifiable(commands);

  final List<TicCmd> commands;
  final int expectedFinalHash;
  final ValueChanged<DoomReplayResult>? onFinished;
}
