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

const int _opl2SampleRate = 49716;
const int _musicBlockFrames = 4096;
const int _musicQueueBlocks = 8;

/// Browser implementation shared by every level view in one app lifetime.
final class WebAudioSession extends DoomAudioSession {
  WebAudioSession() {
    unawaited(_initializeContext());
  }

  final Completer<void> _contextReady = Completer<void>();
  final Map<PcmSound, web.AudioBuffer> _pcmBuffers =
      <PcmSound, web.AudioBuffer>{};
  final Map<int, _ActiveVoice> _voices = <int, _ActiveVoice>{};

  web.AudioContext? _context;
  web.GainNode? _musicGain;
  web.GainNode? _effectsGain;
  web.AudioWorkletNode? _musicNode;
  web.Worker? _musicWorker;
  web.AbortController? _listeners;
  Timer? _telemetryTimer;
  Map<Object?, Object?> _latestMusicStats = const <Object?, Object?>{};

  double _musicVolume = 1;
  double _effectsVolume = 1;
  String? _errorMessage;
  bool _disposed = false;
  bool _unlocked = false;
  bool _paused = false;
  bool _levelFocused = true;
  bool _documentFocused = true;
  bool _statsPending = false;
  bool _notificationScheduled = false;
  int _levelGeneration = 0;
  int _musicEpoch = 0;
  int _retirePosts = 0;
  int _configurationPosts = 0;
  final AudioContextCommandState _contextCommands = AudioContextCommandState();
  final AudioTransportLifecycleState _musicLifecycle =
      AudioTransportLifecycleState();
  final MusicAdmissionState<_MusicConfiguration> _musicAdmission =
      MusicAdmissionState<_MusicConfiguration>();

  /// Read-only state used by the local production-transport QA harness.
  WebAudioDiagnostics get diagnostics {
    final context = _context;
    return WebAudioDiagnostics(
      contextState: context?.state ?? 'unavailable',
      contextSampleRate: context?.sampleRate,
      activeEffects: _voices.length,
      cachedEffects: _pcmBuffers.length,
      levelGeneration: _levelGeneration,
      musicEpoch: _musicEpoch,
      retireInFlight: _musicAdmission.retireInFlight,
      pendingRetireEpoch: _musicAdmission.pendingRetireEpoch,
      configurationInFlight: _musicAdmission.configurationInFlight,
      retirePosts: _retirePosts,
      configurationPosts: _configurationPosts,
      hasPendingConfiguration: _musicAdmission.pendingConfiguration != null,
      resumePending: _contextCommands.resumePending,
      suspendPending: _contextCommands.suspendPending,
      queuedMusicBlocks: (_latestMusicStats['queuedBlocks'] as num?)?.toInt(),
      playedMusicFrames: (_latestMusicStats['playedFrames'] as num?)?.toInt(),
      musicUnderruns: (_latestMusicStats['underruns'] as num?)?.toInt(),
      musicAvailable: _musicLifecycle.available,
      errorMessage: _errorMessage,
      disposed: _disposed,
    );
  }

  /// Causes a real uncaught worker failure in QA builds only.
  void debugCrashMusicWorker() {
    if (!const bool.fromEnvironment('DOOMPELLER_AUDIO_HARNESS')) {
      throw UnsupportedError('The audio harness is not enabled.');
    }
    _musicWorker?.postMessage(<String, Object?>{'type': 'debugCrash'}.jsify());
  }

  @override
  double get musicVolume => _musicVolume;

  @override
  double get effectsVolume => _effectsVolume;

  @override
  bool get controlsAvailable => true;

  @override
  bool get musicAvailable => _musicLifecycle.available;

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
        nativeRate: _opl2SampleRate,
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
      _musicGain = musicGain;
      _effectsGain = effectsGain;
      _installDocumentListeners();
      _contextReady.complete();
      unawaited(_initializeMusic(context, musicGain));
    } on Object catch (error, stackTrace) {
      if (!_contextReady.isCompleted) _contextReady.complete();
      _setError('Web Audio could not be initialized.', error, stackTrace);
    }
  }

  Future<void> _initializeMusic(
    web.AudioContext context,
    web.GainNode musicGain,
  ) async {
    final int transportGeneration = _musicLifecycle.beginInitialization();
    if (context.sampleRate.round() != _opl2SampleRate) {
      _failMusic(
        'Music needs a $_opl2SampleRate Hz AudioContext; the browser provided '
        '${context.sampleRate.round()} Hz.',
      );
      return;
    }
    web.Worker? worker;
    web.AudioWorkletNode? node;
    try {
      await context.audioWorklet
          .addModule(Uri.base.resolve('doom_music_worklet.js').toString())
          .toDart;
      if (_disposed) return;

      node = web.AudioWorkletNode(
        context,
        'doompeller-music-output',
        web.AudioWorkletNodeOptions(
          numberOfInputs: 0,
          numberOfOutputs: 1,
          outputChannelCount: <JSNumber>[2.toJS].toJS,
        ),
      );
      node.connect(musicGain);
      _musicNode = node;
      node.onprocessorerror = ((web.Event _) {
        _disableMusic('The browser audio output processor failed.');
      }).toJS;
      node.port.onmessage = ((web.MessageEvent event) {
        _onMusicMessage(event.data);
      }).toJS;
      node.port.onmessageerror = ((web.Event _) {
        _disableMusic('The music output channel received an invalid message.');
      }).toJS;
      node.port.start();

      final Completer<void> workerReady = Completer<void>();
      worker = web.Worker(
        Uri.base.resolve('doom_music_worker_loader.mjs').toString().toJS,
        web.WorkerOptions(type: 'module'),
      );
      _musicWorker = worker;
      worker.onmessage = ((web.MessageEvent event) {
        final Map<Object?, Object?>? message = _messageMap(event.data);
        if (message?['type'] == 'ready' && !workerReady.isCompleted) {
          workerReady.complete();
        } else {
          if (message?['type'] == 'fault' &&
              message?['fatal'] == true &&
              !workerReady.isCompleted) {
            workerReady.completeError(
              message?['message']?.toString() ?? 'The music worker failed.',
            );
          }
          _onMusicMessage(event.data);
        }
      }).toJS;
      worker.onerror = ((web.ErrorEvent event) {
        final message = event.message.isEmpty
            ? 'The music worker failed.'
            : 'The music worker failed: ${event.message}';
        if (!workerReady.isCompleted) workerReady.completeError(message);
        _disableMusic(message);
      }).toJS;
      worker.onmessageerror = ((web.Event _) {
        const message = 'The music worker received an invalid message.';
        if (!workerReady.isCompleted) workerReady.completeError(message);
        _disableMusic(message);
      }).toJS;

      await workerReady.future.timeout(const Duration(seconds: 10));
      if (_disposed ||
          !identical(_musicNode, node) ||
          !identical(_musicWorker, worker) ||
          !_musicLifecycle.completeInitialization(transportGeneration)) {
        return;
      }
      final channel = web.MessageChannel();
      node.port.postMessage(
        <String, Object?>{'type': 'attach', 'port': channel.port1}.jsify(),
        <JSObject>[channel.port1].toJS,
      );
      worker.postMessage(
        <String, Object?>{
          'type': 'attach',
          'port': channel.port2,
          'blockFrames': _musicBlockFrames,
          'queueBlocks': _musicQueueBlocks,
        }.jsify(),
        <JSObject>[channel.port2].toJS,
      );
      _errorMessage = null;
      _telemetryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_disposed || _statsPending) return;
        final currentNode = _musicNode;
        if (currentNode == null) return;
        _statsPending = true;
        currentNode.port.postMessage(
          <String, Object?>{'type': 'stats'}.jsify(),
        );
      });
      _notifyListeners();
      _sendPendingRetire();
    } on Object catch (error, stackTrace) {
      node?.disconnect();
      worker?.terminate();
      if (_disposed) return;
      if (identical(_musicNode, node)) _musicNode = null;
      if (identical(_musicWorker, worker)) _musicWorker = null;
      _setError(
        'OPL2 music is unavailable in this browser.',
        error,
        stackTrace,
      );
      _failMusic(_errorMessage!);
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
    const DoomLimits limits = DoomLimits.defaults;
    if (mus.lengthInBytes > limits.maxMusicBytes ||
        genMidi.lengthInBytes > limits.maxGenMidiBytes) {
      _errorMessage = 'The selected WAD music exceeds the safe size limit.';
      _retireMusic();
      _notifyListeners();
      return;
    }
    final int epoch = ++_musicEpoch;
    final config = _MusicConfiguration(
      epoch: epoch,
      track: track,
      mus: Uint8List.fromList(mus),
      genMidi: Uint8List.fromList(genMidi),
    );
    _musicAdmission.replaceConfiguration(epoch, config);
    _queueMusicRetire(epoch);
    _sendPendingConfiguration();
    _tryResume();
  }

  void _sendPendingConfiguration() {
    if (_disposed || !_musicLifecycle.available) return;
    final worker = _musicWorker;
    final config = _musicAdmission.takeConfiguration(
      transportReady: worker != null,
    );
    if (worker == null || config == null) return;
    _configurationPosts++;
    final JSUint8Array mus = config.mus.toJS;
    final JSUint8Array genMidi = config.genMidi.toJS;
    worker.postMessage(
      <String, Object?>{
        'type': 'configure',
        'epoch': config.epoch,
        'track': config.track,
        'mus': mus,
        'genMidi': genMidi,
      }.jsify(),
      <JSObject>[
        _ArrayBufferView._(mus).buffer,
        _ArrayBufferView._(genMidi).buffer,
      ].toJS,
    );
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
    _retireMusic();
  }

  Future<void> _disposeLevel(int generation) async {
    if (!_owns(generation)) return;
    _levelGeneration++;
    _dropEffects(complete: true);
    _pcmBuffers.clear();
    _retireMusic();
  }

  bool _owns(int generation) => !_disposed && generation == _levelGeneration;

  void _retireMusic() {
    final int epoch = ++_musicEpoch;
    _musicAdmission.discardPendingConfiguration();
    _queueMusicRetire(epoch);
  }

  void _queueMusicRetire(int epoch) {
    _musicAdmission.queueRetire(epoch);
    _sendPendingRetire();
  }

  void _sendPendingRetire() {
    if (_disposed || !_musicLifecycle.available) return;
    final node = _musicNode;
    final int? epoch = _musicAdmission.takeRetire(transportReady: node != null);
    if (node == null || epoch == null) return;
    _retirePosts++;
    node.port.postMessage(
      <String, Object?>{'type': 'retire', 'epoch': epoch}.jsify(),
    );
  }

  void _onMusicMessage(JSAny? data) {
    if (_disposed || !_musicLifecycle.acceptsMessages) return;
    final Map<Object?, Object?>? message = _messageMap(data);
    if (message == null) return;
    switch (message['type']) {
      case 'retired':
        final int? epoch = (message['epoch'] as num?)?.toInt();
        _musicAdmission.acknowledgeRetire(epoch);
        _sendPendingRetire();
        _sendPendingConfiguration();
      case 'configured':
        final int? epoch = (message['epoch'] as num?)?.toInt();
        _musicAdmission.acknowledgeConfiguration(epoch);
        if (epoch == _musicEpoch) {
          _errorMessage = null;
          _notifyListeners();
        }
        _sendPendingConfiguration();
      case 'fault':
        final String messageText =
            message['message']?.toString() ?? 'The OPL2 music worker failed.';
        if (message['fatal'] == true) {
          _disableMusic(messageText);
        } else {
          final int? epoch = (message['epoch'] as num?)?.toInt();
          _musicAdmission.acknowledgeConfiguration(epoch);
          if (epoch == _musicEpoch) {
            _errorMessage = messageText;
            _notifyListeners();
          }
          _sendPendingConfiguration();
        }
      case 'stats':
        _statsPending = false;
        _latestMusicStats = Map<Object?, Object?>.unmodifiable(message);
        if (const bool.fromEnvironment('DOOMPELLER_FRAME_PROBE')) {
          final Object? workerValue = message['worker'];
          final Map<Object?, Object?> worker =
              workerValue is Map<Object?, Object?>
              ? workerValue
              : const <Object?, Object?>{};
          web.console.log(
            'doompeller-web-audio: '
                    'epoch=${message['epoch']} '
                    'queued=${message['queuedBlocks']} '
                    'played=${message['playedFrames']} '
                    'underruns=${message['underruns']} '
                    'rendered=${worker['renderedFrames']} '
                    'loop=${worker['loopCount']}'
                .toJS,
          );
        }
    }
  }

  static Map<Object?, Object?>? _messageMap(JSAny? data) {
    final Object? value = data?.dartify();
    return value is Map<Object?, Object?> ? value : null;
  }

  void _applyContextState() {
    final context = _context;
    if (_disposed || context == null) return;
    final AudioContextCommand? command = _contextCommands.takeNext(
      unlocked: _unlocked,
      shouldRun: _shouldRun,
      contextState: context.state,
    );
    switch (command) {
      case AudioContextCommand.resume:
        _observeContextTransition(
          context.resume(),
          command: AudioContextCommand.resume,
        );
      case AudioContextCommand.suspend:
        // This can be queued behind a pending resume while the reported state
        // is still suspended, so a later pause or blur always wins.
        _observeContextTransition(
          context.suspend(),
          command: AudioContextCommand.suspend,
        );
      case null:
        return;
    }
  }

  void _tryResume() {
    _applyContextState();
  }

  void _observeContextTransition(
    JSPromise<JSAny?> promise, {
    required AudioContextCommand command,
  }) {
    unawaited(
      promise.toDart.then<void>(
        (_) {
          _contextCommands.settle(command);
          _applyContextState();
        },
        onError: (_) {
          _contextCommands.settle(command);
          if (command == AudioContextCommand.resume) {
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

  void _failMusic(String message) {
    _musicLifecycle.disable();
    _errorMessage = message;
    _statsPending = false;
    _latestMusicStats = const <Object?, Object?>{};
    _notifyListeners();
  }

  void _disableMusic(String message) {
    if (_disposed) return;
    _musicLifecycle.disable();
    _errorMessage = message;
    _statsPending = false;
    _latestMusicStats = const <Object?, Object?>{};
    _musicAdmission.clear();
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _musicWorker?.terminate();
    _musicWorker = null;
    _musicNode?.port.close();
    _musicNode?.disconnect();
    _musicNode = null;
    _notifyListeners();
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
    _musicLifecycle.dispose();
    _levelGeneration++;
    _musicEpoch++;
    _telemetryTimer?.cancel();
    _statsPending = false;
    _latestMusicStats = const <Object?, Object?>{};
    _listeners?.abort();
    _dropEffects(complete: true);
    _musicAdmission.clear();
    _contextCommands.clear();
    _musicNode?.port.postMessage(
      <String, Object?>{'type': 'retire', 'epoch': _musicEpoch}.jsify(),
    );
    _musicNode?.port.close();
    _musicNode?.disconnect();
    _musicWorker?.terminate();
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

final class _MusicConfiguration {
  const _MusicConfiguration({
    required this.epoch,
    required this.track,
    required this.mus,
    required this.genMidi,
  });

  final int epoch;
  final String track;
  final Uint8List mus;
  final Uint8List genMidi;
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
