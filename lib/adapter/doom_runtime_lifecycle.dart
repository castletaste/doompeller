part of 'doom_runtime_game.dart';

/// Keeps the lifecycle sequence beside the runtime without adding a second
/// owner object that forwards every operation back to [DoomRuntimeGame].
extension _DoomRuntimeLifecycle on DoomRuntimeGame {
  void _restartLifecycle() {
    if (_disposed) return;
    _damageFlashTics = 0;
    _pickupFlashTics = 0;
    _paletteIndex = DoomPaletteVariant.normal;
    scene.setPaletteIndex(_paletteIndex);
    scene.materials.setFixedColorMap(-1);
    _devices.clear();
    _wheelWeaponSlot = null;
    _soundOutput.stop();
    gameState = level.createGame();
    tickDriver = FixedTickDriver(
      maxTicsPerFrame: gameState.config.maxCatchUpTics,
    );
    _soundJournal = DoomCoreSoundJournal(gameState);
    _paused = false;
    _playLevelMusic();
    _setMusicPaused(false);
    _completionReported = false;
    _replay?.reset();
    _pendingReplayTerminal = null;
    _fractionalMicros = 0;
    _previousPlayer = gameState.player;
    _currentPlayer = gameState.player;
    var sector = 0;
    for (final runtimeSector in gameState.sectors) {
      _sectorFloors[sector] = fixedToDouble(runtimeSector.floorHeight);
      _sectorCeilings[sector] = fixedToDouble(runtimeSector.ceilingHeight);
      sector++;
    }
    scene.resetDynamicState(level.map);
    _automap.reset(_currentPlayer);
    _weaponFlashSprite?.setVisible(false);
    _syncActors();
    _syncWeapon(force: true);
    _syncCamera(0);
    _publishHud();
  }

  void _disposeLifecycle() {
    if (_disposed) return;
    _disposed = true;
    _withMusic((backend) => backend.stopMusic());
    _devices.clear();
    _soundOutput.dispose();
    _movementRevision.dispose();
    onPauseRequested = null;
    _hud.dispose();
    _automap.dispose();
  }
}
