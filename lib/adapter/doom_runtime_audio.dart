part of 'doom_runtime_game.dart';

extension _DoomRuntimeAudio on DoomRuntimeGame {
  void _consumeSoundJournal() {
    final List<SoundEvent> events = _soundJournal.consumeSoundJournal().toList(
      growable: false,
    );
    if (events.any((event) => event.soundId == 'DSITEMUP')) {
      _pickupFlashTics = 6;
    }
    final AudioListener listener = audioListenerFromPlayer(_currentPlayer);
    final int gameTic = gameState.tic;
    final sources = <int, AudioPosition>{};
    if (_soundPlayback.supportsSpatialUpdates) {
      final needed = _soundPlayback.activePositionalSources
          .where((source) => source > 0)
          .toSet();
      if (needed.isNotEmpty) {
        for (final actor in gameState.mobjs) {
          if (!needed.remove(actor.id)) continue;
          sources[actor.id] = AudioPosition(
            actor.x / 65536,
            actor.y / 65536,
            actor.z / 65536,
          );
          if (needed.isEmpty) break;
        }
      }
    }
    _soundOutput.add(
      events: events,
      listener: listener,
      gameTic: gameTic,
      sources: sources,
    );
  }

  void _playLevelMusic() {
    _completionMusicStarted = false;
    _playMusic('D_${level.map.name}');
  }

  void _playMusic(String track) {
    final backend = _audioBackend;
    if (_disposed || backend is! MusicAudioBackend) return;
    try {
      final mus = level.content.wads.read(track);
      final bank = level.content.wads.read('GENMIDI');
      if (level.content.isFixture && mus == null && bank == null) {
        backend.stopMusic();
        return;
      }
      backend.playMusic(
        track: track,
        mus: mus ?? Uint8List(0),
        genMidi: bank ?? Uint8List(0),
      );
    } catch (error, stackTrace) {
      _recordSoundPlaybackError(error, stackTrace);
    }
  }

  void _setMusicPaused(bool paused) {
    _withMusic((backend) => backend.setPaused(paused));
  }

  void _withMusic(void Function(MusicAudioBackend) operation) {
    final backend = _audioBackend;
    if (backend is! MusicAudioBackend) return;
    try {
      operation(backend);
    } catch (error, stackTrace) {
      _recordSoundPlaybackError(error, stackTrace);
    }
  }
}
