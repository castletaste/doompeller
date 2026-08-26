import 'dart:io' show Platform;

import 'macos_audio_backend.dart';
import 'sound_playback.dart';

AudioBackend createDefaultAudioBackend() =>
    Platform.isMacOS ? MacOsAudioBackend() : const NoAudioBackend();
