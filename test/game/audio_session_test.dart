import 'package:doompeller/game/audio_session.dart';
import 'package:doompeller/game/audio_session_factory_stub.dart' as stub;
import 'package:doompeller/game/sound_playback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('volume validation clamps finite values and rejects invalid ones', () {
    expect(clampAudioVolume(-1), 0);
    expect(clampAudioVolume(0.4), 0.4);
    expect(clampAudioVolume(2), 1);
    expect(() => clampAudioVolume(double.nan), throwsArgumentError);
    expect(() => clampAudioVolume(double.infinity), throwsArgumentError);
  });

  test(
    'unsupported session has stable capabilities and bounded lifetime',
    () async {
      final DoomAudioSession session = stub.createDoomAudioSession();
      expect(session.controlsAvailable, isFalse);
      expect(session.musicAvailable, isFalse);
      expect(session.errorMessage, isNull);
      expect(session.musicVolume, 1);
      expect(session.effectsVolume, 1);

      session.setMusicVolume(0.5);
      session.setEffectsVolume(0.25);
      final AudioBackend backend = session.acquireLevel();
      expect(backend, isA<NoAudioBackend>());
      await backend.dispose();

      session.dispose();
      expect(session.acquireLevel, throwsStateError);
      session.dispose();
    },
  );
}
