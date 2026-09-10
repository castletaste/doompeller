import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'sound_playback.dart';

/// App-lifetime ownership boundary for audio transports.
///
/// A level owns only the backend returned by [acquireLevel]. The session may
/// therefore keep browser audio resources alive while retiring every command
/// from a replaced level.
abstract class DoomAudioSession extends ChangeNotifier {
  double get musicVolume;
  double get effectsVolume;

  /// Stable platform capability used to decide whether volume controls exist.
  bool get controlsAvailable;

  /// Whether the music pipeline is currently usable.
  bool get musicAvailable;

  /// Last persistent music capability or worker failure, if any.
  String? get errorMessage;

  AudioBackend acquireLevel();

  void setMusicVolume(double value);
  void setEffectsVolume(double value);
}

/// Optional music controls implemented by level backends that share a session.
abstract interface class MusicAudioBackend implements AudioBackend {
  void playMusic({
    required String track,
    required Uint8List mus,
    required Uint8List genMidi,
  });

  void setPaused(bool paused);
  void setFocused(bool focused);
  void stopMusic();
}

double clampAudioVolume(double value) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'must be finite');
  }
  return value.clamp(0.0, 1.0).toDouble();
}
