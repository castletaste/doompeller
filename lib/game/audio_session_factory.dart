import 'audio_session.dart';
import 'audio_session_factory_stub.dart'
    if (dart.library.io) 'audio_session_factory_io.dart'
    if (dart.library.js_interop) 'audio_session_factory_web.dart'
    as platform;

DoomAudioSession createDoomAudioSession() => platform.createDoomAudioSession();
