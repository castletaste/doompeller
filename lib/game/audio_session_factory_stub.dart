import 'audio_session.dart';
import 'sound_playback.dart';

DoomAudioSession createDoomAudioSession() => _UnsupportedAudioSession();

final class _UnsupportedAudioSession extends DoomAudioSession {
  bool _disposed = false;

  @override
  double get musicVolume => 1;

  @override
  double get effectsVolume => 1;

  @override
  bool get controlsAvailable => false;

  @override
  bool get musicAvailable => false;

  @override
  String? get errorMessage => null;

  @override
  AudioBackend acquireLevel() {
    if (_disposed) throw StateError('The audio session has been disposed.');
    return const NoAudioBackend();
  }

  @override
  void setMusicVolume(double value) => clampAudioVolume(value);

  @override
  void setEffectsVolume(double value) => clampAudioVolume(value);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
