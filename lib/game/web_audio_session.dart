import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/foundation.dart'
    show ErrorDescription, FlutterError, FlutterErrorDetails;
import 'package:web/web.dart' as web;

import '../web/audio_transport_state.dart';
import 'audio_session.dart';
import 'sound_playback.dart';

part 'web_music_transport.dart';

/// Browser implementation shared by every level view in one app lifetime.
final class WebAudioSession extends DoomAudioSession {
  WebAudioSession() {
    _musicTransport = _WebMusicTransport(
      onMessage: _setMusicMessage,
      onError: _setError,
    );
    unawaited(_initializeContext());
  }

  final Completer<void> _contextReady = Completer<void>();
  final Map<PcmSound, web.AudioBuffer> _pcmBuffers =
      <PcmSound, web.AudioBuffer>{};
  final Map<int, _ActiveVoice> _voices = <int, _ActiveVoice>{};

  web.AudioContext? _context;
  web.GainNode? _musicGain;
  web.GainNode? _effectsGain;
  web.AbortController? _listeners;
  late final _WebMusicTransport _musicTransport;

  double _musicVolume = 1;
  double _effectsVolume = 1;
  String? _errorMessage;
  bool _disposed = false;
  bool _unlocked = false;
  bool _paused = false;
  bool _levelFocused = true;
  bool _documentFocused = true;
  bool _notificationScheduled = false;
  int _levelGeneration = 0;
  final AudioContextCommandState _contextCommands = AudioContextCommandState();

  /// Read-only state used by the local production-transport QA harness.
  WebAudioDiagnostics get diagnostics {
    final context = _context;
    final music = _musicTransport.diagnostics;
    return WebAudioDiagnostics(
      contextState: context?.state ?? 'unavailable',
      contextSampleRate: context?.sampleRate,
      activeEffects: _voices.length,
      cachedEffects: _pcmBuffers.length,
      levelGeneration: _levelGeneration,
      musicEpoch: music.musicEpoch,
      retireInFlight: music.retireInFlight,
      pendingRetireEpoch: music.pendingRetireEpoch,
      configurationInFlight: music.configurationInFlight,
      retirePosts: music.retirePosts,
      configurationPosts: music.configurationPosts,
      hasPendingConfiguration: music.hasPendingConfiguration,
      resumePending: _contextCommands.resumePending,
      suspendPending: _contextCommands.suspendPending,
      queuedMusicBlocks: music.queuedMusicBlocks,
      playedMusicFrames: music.playedMusicFrames,
      musicUnderruns: music.musicUnderruns,
      musicAvailable: music.musicAvailable,
      errorMessage: _errorMessage,
      disposed: _disposed,
    );
  }

  /// Causes a real uncaught worker failure in QA builds only.
  void debugCrashMusicWorker() {
    _musicTransport.debugCrashMusicWorker();
  }

  @override
  double get musicVolume => _musicVolume;

  @override
  double get effectsVolume => _effectsVolume;

  @override
  bool get controlsAvailable => true;

  @override
  bool get musicAvailable => _musicTransport.available;

  @override
  String? get errorMessage => _errorMessage;

  @override
  AudioBackend acquireLevel() {
    if (_disposed) throw StateError('The audio session has been disposed.');
    _levelGeneration++;
    _paused = false;
    _levelFocused = true;
    _documentFocused = !web.document.hidden && web.document.hasFocus();
    _dropEffects(complete: true);
    _pcmBuffers.clear();
    _retireMusic();
    _applyContextState();
    return _WebLevelAudioBackend(this, _levelGeneration);
  }

  @override
  void setMusicVolume(double value) {
    final double next = clampAudioVolume(value);
    if (next == _musicVolume) return;
    _musicVolume = next;
    _musicGain?.gain.value = next;
    _notifyListeners();
  }

  @override
  void setEffectsVolume(double value) {
    final double next = clampAudioVolume(value);
    if (next == _effectsVolume) return;
    _effectsVolume = next;
    _effectsGain?.gain.value = next;
    _notifyListeners();
  }

  Future<void> _initializeContext() async {
    try {
      final context = createAudioContextWithFallback(
        (rate) => rate == null
            ? web.AudioContext()
            : web.AudioContext(web.AudioContextOptions(sampleRate: rate)),
        nativeRate: _WebMusicTransport.sampleRate,
      );
      if (_disposed) {
        _ignorePromise(context.close());
        return;
      }
      final musicGain = context.createGain()..gain.value = _musicVolume;
      final effectsGain = context.createGain()..gain.value = _effectsVolume;
      musicGain.connect(context.destination);
      effectsGain.connect(context.destination);
      _context = context;
      context.onstatechange = ((web.Event _) => _applyContextState()).toJS;
      _musicGain = musicGain;
      _effectsGain = effectsGain;
      _installDocumentListeners();
      _contextReady.complete();
      unawaited(_musicTransport.initialize(context, musicGain));
    } on Object catch (error, stackTrace) {
      if (!_contextReady.isCompleted) _contextReady.complete();
      _setError('Web Audio could not be initialized.', error, stackTrace);
    }
  }

  void _installDocumentListeners() {
    final controller = web.AbortController();
    _listeners = controller;
    final options = web.AddEventListenerOptions(
      capture: true,
      passive: true,
      signal: controller.signal,
    );
    final JSFunction unlock = ((web.Event event) {
      if (!event.isTrusted || _disposed) return;
      _unlocked = true;
      _applyContextState();
    }).toJS;
    web.window.addEventListener('keydown', unlock, options);
    web.window.addEventListener('pointerdown', unlock, options);
    web.window.addEventListener('touchend', unlock, options);
    web.window.addEventListener(
      'blur',
      ((web.Event _) {
        _documentFocused = false;
        _dropEffects(complete: true);
        _applyContextState();
      }).toJS,
      options,
    );
    web.window.addEventListener(
      'focus',
      ((web.Event _) {
        _documentFocused = !web.document.hidden;
        _applyContextState();
      }).toJS,
      options,
    );
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        _documentFocused = !web.document.hidden && web.document.hasFocus();
        if (!_documentFocused) _dropEffects(complete: true);
        _applyContextState();
      }).toJS,
      options,
    );
  }

  Future<void> _play(
    int generation,
    AudioPlayRequest request,
    void Function()? onComplete,
  ) async {
    await _contextReady.future;
    if (!_owns(generation)) return;
    final context = _context;
    final effectsGain = _effectsGain;
    if (context == null || effectsGain == null) {
      onComplete?.call();
      return;
    }
    if (!_unlocked || !_shouldRun) {
      onComplete?.call();
      return;
    }

    web.AudioBuffer? buffer;
    final PcmSound? pcm = request.pcmSound;
    if (pcm != null) {
      buffer = _pcmBuffers[pcm];
      if (buffer == null) {
        buffer = context.createBuffer(1, pcm.pcm.length, pcm.sampleRate);
        final samples = Float32List(pcm.pcm.length);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = (pcm.pcm[i] - 128) / 128;
        }
        buffer.copyToChannel(samples.toJS, 0);
        _pcmBuffers[pcm] = buffer;
      }
    } else {
      final bytes = Uint8List.fromList(request.wavBytes).toJS;
      buffer = await context
          .decodeAudioData(_ArrayBufferView._(bytes).buffer)
          .toDart;
      if (!_owns(generation)) return;
      if (!_unlocked || !_shouldRun) {
        onComplete?.call();
        return;
      }
    }

    _stopVoice(request.channelId, complete: false);
    final source = context.createBufferSource()..buffer = buffer;
    final panner = context.createStereoPanner()..pan.value = _pan(request.pan);
    final voiceGain = context.createGain()..gain.value = _gain(request.volume);
    source.connect(panner);
    panner.connect(voiceGain);
    voiceGain.connect(effectsGain);
    final voice = _ActiveVoice(
      generation: generation,
      playbackId: request.playbackId,
      source: source,
      panner: panner,
      gain: voiceGain,
      onComplete: onComplete,
    );
    _voices[request.channelId] = voice;
    source.onended = ((web.Event _) {
      _finishVoice(
        request.channelId,
        generation,
        request.playbackId,
        complete: true,
      );
    }).toJS;
    source.start();
    _tryResume();
  }

  Future<void> _stop(int generation, int channelId) async {
    if (!_owns(generation)) return;
    _stopVoice(channelId, complete: false);
  }

  void _updateSpatial({
    required int generation,
    required int channelId,
    required int playbackId,
    required double volume,
    required double pan,
  }) {
    if (!_owns(generation)) return;
    final voice = _voices[channelId];
    if (voice == null || voice.playbackId != playbackId) return;
    if (volume <= 0) {
      _stopVoice(channelId, complete: true);
      return;
    }
    voice.gain.gain.value = _gain(volume);
    voice.panner.pan.value = _pan(pan);
  }

  void _playMusic(
    int generation, {
    required String track,
    required Uint8List mus,
    required Uint8List genMidi,
  }) {
    if (!_owns(generation)) return;
    _musicTransport.configure(track: track, mus: mus, genMidi: genMidi);
    _tryResume();
  }

  void _setPaused(int generation, bool paused) {
    if (!_owns(generation) || _paused == paused) return;
    _paused = paused;
    if (paused) _dropEffects(complete: true);
    _applyContextState();
  }

  void _setFocused(int generation, bool focused) {
    if (!_owns(generation) || _levelFocused == focused) return;
    _levelFocused = focused;
    if (!focused) _dropEffects(complete: true);
    _applyContextState();
  }

  void _stopMusic(int generation) {
    if (!_owns(generation)) return;
    _musicTransport.retire();
  }

  Future<void> _disposeLevel(int generation) async {
    if (!_owns(generation)) return;
    _levelGeneration++;
    _dropEffects(complete: true);
    _pcmBuffers.clear();
    _musicTransport.retire();
  }

  bool _owns(int generation) => !_disposed && generation == _levelGeneration;

  void _retireMusic() {
    _musicTransport.retire();
  }

  void _applyContextState() {
    final context = _context;
    if (_disposed || context == null) return;
    final request = _contextCommands.takeNext(
      unlocked: _unlocked,
      shouldRun: _shouldRun,
      contextState: context.state,
    );
    switch (request?.command) {
      case AudioContextCommand.resume:
        _observeContextTransition(context.resume(), request: request!);
      case AudioContextCommand.suspend:
        // This can be queued behind a pending resume while the reported state
        // is still suspended, so a later pause or blur always wins.
        _observeContextTransition(context.suspend(), request: request!);
      case null:
        return;
    }
  }

  void _tryResume() {
    _applyContextState();
  }

  void _observeContextTransition(
    JSPromise<JSAny?> promise, {
    required AudioContextRequest request,
  }) {
    unawaited(
      promise.toDart.then<void>(
        (_) {
          _contextCommands.settle(request);
          _applyContextState();
        },
        onError: (_) {
          if (!_contextCommands.settle(request, succeeded: false)) return;
          if (request.command == AudioContextCommand.resume) {
            // A rejected autoplay attempt waits for another trusted gesture.
            _unlocked = false;
          }
        },
      ),
    );
  }

  void _finishVoice(
    int channelId,
    int generation,
    int playbackId, {
    required bool complete,
  }) {
    final voice = _voices[channelId];
    if (voice == null ||
        voice.generation != generation ||
        voice.playbackId != playbackId) {
      return;
    }
    _voices.remove(channelId);
    voice.disconnect();
    if (complete) voice.complete();
  }

  void _stopVoice(int channelId, {required bool complete}) {
    final voice = _voices.remove(channelId);
    if (voice == null) return;
    voice.source.onended = null;
    try {
      voice.source.stop();
    } on Object {
      // A source that ended naturally is already silent.
    }
    voice.disconnect();
    if (complete) voice.complete();
  }

  void _dropEffects({required bool complete}) {
    for (final int channel in _voices.keys.toList(growable: false)) {
      _stopVoice(channel, complete: complete);
    }
  }

  void _setError(String message, Object error, StackTrace stackTrace) {
    _errorMessage = message;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'doompeller web audio',
        context: ErrorDescription(message),
      ),
    );
    _notifyListeners();
  }

  void _setMusicMessage(String? message) {
    _errorMessage = message;
    _notifyListeners();
  }

  void _notifyListeners() {
    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    scheduleMicrotask(() {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  static double _gain(double value) => value.clamp(0.0, 1.0).toDouble();
  static double _pan(double value) => value.clamp(-1.0, 1.0).toDouble();
  bool get _shouldRun => !_paused && _levelFocused && _documentFocused;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _levelGeneration++;
    _listeners?.abort();
    _dropEffects(complete: true);
    _musicTransport.dispose();
    _contextCommands.clear();
    _context?.onstatechange = null;
    _musicGain?.disconnect();
    _effectsGain?.disconnect();
    final context = _context;
    if (context != null) _ignorePromise(context.close());
    _pcmBuffers.clear();
    super.dispose();
  }
}

final class _WebLevelAudioBackend
    implements AudioBackend, SpatialAudioBackend, MusicAudioBackend {
  _WebLevelAudioBackend(this._session, this._generation);

  final WebAudioSession _session;
  final int _generation;
  bool _disposed = false;

  @override
  Future<void> play(AudioPlayRequest request, {void Function()? onComplete}) {
    if (_disposed) return Future<void>.value();
    return _session._play(_generation, request, onComplete);
  }

  @override
  Future<void> stop(int channelId) {
    if (_disposed) return Future<void>.value();
    return _session._stop(_generation, channelId);
  }

  @override
  void updateSpatial({
    required int channelId,
    required int playbackId,
    required double volume,
    required double pan,
  }) {
    if (_disposed) return;
    _session._updateSpatial(
      generation: _generation,
      channelId: channelId,
      playbackId: playbackId,
      volume: volume,
      pan: pan,
    );
  }

  @override
  void playMusic({
    required String track,
    required Uint8List mus,
    required Uint8List genMidi,
  }) {
    if (_disposed) return;
    _session._playMusic(_generation, track: track, mus: mus, genMidi: genMidi);
  }

  @override
  void setPaused(bool paused) {
    if (!_disposed) _session._setPaused(_generation, paused);
  }

  @override
  void setFocused(bool focused) {
    if (!_disposed) _session._setFocused(_generation, focused);
  }

  @override
  void stopMusic() {
    if (!_disposed) _session._stopMusic(_generation);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _session._disposeLevel(_generation);
  }
}

final class _ActiveVoice {
  _ActiveVoice({
    required this.generation,
    required this.playbackId,
    required this.source,
    required this.panner,
    required this.gain,
    required this.onComplete,
  });

  final int generation;
  final int playbackId;
  final web.AudioBufferSourceNode source;
  final web.StereoPannerNode panner;
  final web.GainNode gain;
  final void Function()? onComplete;
  bool _completed = false;

  void complete() {
    if (_completed) return;
    _completed = true;
    onComplete?.call();
  }

  void disconnect() {
    source.disconnect();
    panner.disconnect();
    gain.disconnect();
  }
}

/// Immutable snapshot; reading it does not request or mutate browser state.
final class WebAudioDiagnostics {
  const WebAudioDiagnostics({
    required this.contextState,
    required this.contextSampleRate,
    required this.activeEffects,
    required this.cachedEffects,
    required this.levelGeneration,
    required this.musicEpoch,
    required this.retireInFlight,
    required this.pendingRetireEpoch,
    required this.configurationInFlight,
    required this.retirePosts,
    required this.configurationPosts,
    required this.hasPendingConfiguration,
    required this.resumePending,
    required this.suspendPending,
    required this.queuedMusicBlocks,
    required this.playedMusicFrames,
    required this.musicUnderruns,
    required this.musicAvailable,
    required this.errorMessage,
    required this.disposed,
  });

  final String contextState;
  final double? contextSampleRate;
  final int activeEffects;
  final int cachedEffects;
  final int levelGeneration;
  final int musicEpoch;
  final int? retireInFlight;
  final int? pendingRetireEpoch;
  final int? configurationInFlight;
  final int retirePosts;
  final int configurationPosts;
  final bool hasPendingConfiguration;
  final bool resumePending;
  final bool suspendPending;
  final int? queuedMusicBlocks;
  final int? playedMusicFrames;
  final int? musicUnderruns;
  final bool musicAvailable;
  final String? errorMessage;
  final bool disposed;

  Map<String, Object?> toJson() => <String, Object?>{
    'contextState': contextState,
    'contextSampleRate': contextSampleRate,
    'activeEffects': activeEffects,
    'cachedEffects': cachedEffects,
    'levelGeneration': levelGeneration,
    'musicEpoch': musicEpoch,
    'retireInFlight': retireInFlight,
    'pendingRetireEpoch': pendingRetireEpoch,
    'configurationInFlight': configurationInFlight,
    'retirePosts': retirePosts,
    'configurationPosts': configurationPosts,
    'hasPendingConfiguration': hasPendingConfiguration,
    'resumePending': resumePending,
    'suspendPending': suspendPending,
    'queuedMusicBlocks': queuedMusicBlocks,
    'playedMusicFrames': playedMusicFrames,
    'musicUnderruns': musicUnderruns,
    'musicAvailable': musicAvailable,
    'errorMessage': errorMessage,
    'disposed': disposed,
  };
}

extension type _ArrayBufferView._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}

void _ignorePromise(JSPromise<JSAny?> promise) {
  unawaited(promise.toDart.then<void>((_) {}, onError: (_) {}));
}
