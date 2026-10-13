part of 'doom_runtime_game.dart';

extension _DoomRuntimeReplay on DoomRuntimeGame {
  int _advanceMicros(int elapsedMicros) {
    final replay = _replay;
    if (replay == null) {
      return tickDriver.advanceMicros(
        elapsedMicros,
        (_) => _runDueTic(),
        TicCmd.empty,
      );
    }
    if (!replay.hasNext) {
      _stageReplayTerminal(DoomReplayStatus.earlyEnd);
      _deliverReplayTerminal();
      return 0;
    }
    final FixedTickDriver activeDriver = tickDriver;
    final int executed = activeDriver.advanceMicrosWhile(elapsedMicros, (_) {
      _runDueTic();
      return replayResult == null;
    }, TicCmd.empty);
    _deliverReplayTerminal();
    return executed;
  }

  void _runDueTic() {
    if (!_simulationActive) return;
    final replay = _replay;
    if (replay == null) {
      _runTic(input.consume().command);
      return;
    }
    if (!replay.hasNext) {
      _stageReplayTerminal(DoomReplayStatus.earlyEnd);
      return;
    }
    _runTic(replay.takeCommand());
    final status = replay.outcomeAfterTic(gameState);
    if (status != null) _stageReplayTerminal(status);
  }

  void _stageReplayTerminal(DoomReplayStatus status) {
    final replay = _replay!;
    final result = replay.finish(status, gameState);
    if (result == null) return;
    if (status == DoomReplayStatus.complete) {
      _completionReported = true;
    }
    _pendingReplayTerminal = _ReplayTerminalDelivery(
      result: result,
      secretExit: gameState.usedSecretExit,
      onFinished: replay.input.onFinished,
      onLevelComplete: status == DoomReplayStatus.complete
          ? _onLevelComplete
          : null,
    );
  }

  /// Delivers a successful level callback before the replay callback.
  ///
  /// The delivery is detached first so either callback may restart the game
  /// without changing the completed run's captured result or exit kind.
  void _deliverReplayTerminal() {
    final _ReplayTerminalDelivery? delivery = _pendingReplayTerminal;
    if (delivery == null) return;
    _pendingReplayTerminal = null;
    try {
      delivery.onLevelComplete?.call(delivery.secretExit);
    } finally {
      delivery.onFinished?.call(delivery.result);
    }
  }
}
