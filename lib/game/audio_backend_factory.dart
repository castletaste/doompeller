import 'audio_backend_factory_stub.dart'
    if (dart.library.io) 'audio_backend_factory_io.dart'
    as platform;
import 'sound_playback.dart';

/// Chooses the production audio transport without exposing `dart:io` to web.
AudioBackend createDefaultAudioBackend() =>
    platform.createDefaultAudioBackend();
