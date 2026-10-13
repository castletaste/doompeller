part of 'web_audio_session.dart';

const int _opl2SampleRate = 49716;
const int _musicBlockFrames = 4096;
const int _musicQueueBlocks = 8;

typedef _MusicMessageHandler = void Function(String? message);
typedef _MusicErrorHandler =
    void Function(String message, Object error, StackTrace stackTrace);

/// Owns the browser worker and AudioWorklet used by OPL2 music.
///
/// Effects and AudioContext focus remain in [WebAudioSession]. This class
/// owns only the music transport protocol: initialization identity, latest
/// configuration admission, retire acknowledgements and worker telemetry.
final class _WebMusicTransport {
  static const int sampleRate = _opl2SampleRate;

  _WebMusicTransport({
    required this._onMessage,
    required this._onError,
  });

  final _MusicMessageHandler _onMessage;
  final _MusicErrorHandler _onError;
  final AudioTransportLifecycleState _lifecycle =
      AudioTransportLifecycleState();
  final MusicAdmissionState<_MusicConfiguration> _admission =
      MusicAdmissionState<_MusicConfiguration>();

  web.AudioWorkletNode? _node;
  web.Worker? _worker;
  Timer? _telemetryTimer;
  Map<Object?, Object?> _latestStats = const <Object?, Object?>{};
  bool _disposed = false;
  bool _statsPending = false;
  int _epoch = 0;
  int _retirePosts = 0;
  int _configurationPosts = 0;

  bool get available => _lifecycle.available;

  _WebMusicDiagnostics get diagnostics {
    return _WebMusicDiagnostics(
      musicEpoch: _epoch,
      retireInFlight: _admission.retireInFlight,
      pendingRetireEpoch: _admission.pendingRetireEpoch,
      configurationInFlight: _admission.configurationInFlight,
      retirePosts: _retirePosts,
      configurationPosts: _configurationPosts,
      hasPendingConfiguration: _admission.pendingConfiguration != null,
      queuedMusicBlocks: (_latestStats['queuedBlocks'] as num?)?.toInt(),
      playedMusicFrames: (_latestStats['playedFrames'] as num?)?.toInt(),
      musicUnderruns: (_latestStats['underruns'] as num?)?.toInt(),
      musicAvailable: _lifecycle.available,
    );
  }

  /// Causes a real uncaught worker failure in QA builds only.
  void debugCrashMusicWorker() {
    if (!const bool.fromEnvironment('DOOMPELLER_AUDIO_HARNESS')) {
      throw UnsupportedError('The audio harness is not enabled.');
    }
    _worker?.postMessage(<String, Object?>{'type': 'debugCrash'}.jsify());
  }

  Future<void> initialize(
    web.AudioContext context,
    web.GainNode musicGain,
  ) async {
    final int transportGeneration = _lifecycle.beginInitialization();
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
      _node = node;
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
      _worker = worker;
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
          !identical(_node, node) ||
          !identical(_worker, worker) ||
          !_lifecycle.completeInitialization(transportGeneration)) {
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
      _onMessage(null);
      _telemetryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_disposed || _statsPending) return;
        final currentNode = _node;
        if (currentNode == null) return;
        _statsPending = true;
        currentNode.port.postMessage(
          <String, Object?>{'type': 'stats'}.jsify(),
        );
      });
      _sendPendingRetire();
    } on Object catch (error, stackTrace) {
      node?.disconnect();
      worker?.terminate();
      if (_disposed) return;
      if (identical(_node, node)) _node = null;
      if (identical(_worker, worker)) _worker = null;
      _onError('OPL2 music is unavailable in this browser.', error, stackTrace);
      _failMusic('OPL2 music is unavailable in this browser.');
    }
  }

  void configure({
    required String track,
    required Uint8List mus,
    required Uint8List genMidi,
  }) {
    if (_disposed) return;
    const DoomLimits limits = DoomLimits.defaults;
    if (mus.lengthInBytes > limits.maxMusicBytes ||
        genMidi.lengthInBytes > limits.maxGenMidiBytes) {
      _retire();
      _onMessage('The selected WAD music exceeds the safe size limit.');
      return;
    }
    final int epoch = ++_epoch;
    _admission.replaceConfiguration(
      epoch,
      _MusicConfiguration(
        epoch: epoch,
        track: track,
        mus: Uint8List.fromList(mus),
        genMidi: Uint8List.fromList(genMidi),
      ),
    );
    _queueRetire(epoch);
    _sendPendingConfiguration();
  }

  void retire() {
    if (_disposed) return;
    _retire();
  }

  void _retire() {
    final int epoch = ++_epoch;
    _admission.discardPendingConfiguration();
    _queueRetire(epoch);
  }

  void _queueRetire(int epoch) {
    _admission.queueRetire(epoch);
    _sendPendingRetire();
  }

  void _sendPendingConfiguration() {
    if (_disposed || !_lifecycle.available) return;
    final worker = _worker;
    final config = _admission.takeConfiguration(transportReady: worker != null);
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
        _MusicArrayBufferView._(mus).buffer,
        _MusicArrayBufferView._(genMidi).buffer,
      ].toJS,
    );
  }

  void _sendPendingRetire() {
    if (_disposed || !_lifecycle.available) return;
    final node = _node;
    final int? epoch = _admission.takeRetire(transportReady: node != null);
    if (node == null || epoch == null) return;
    _retirePosts++;
    node.port.postMessage(
      <String, Object?>{'type': 'retire', 'epoch': epoch}.jsify(),
    );
  }

  void _onMusicMessage(JSAny? data) {
    if (_disposed || !_lifecycle.acceptsMessages) return;
    final Map<Object?, Object?>? message = _messageMap(data);
    if (message == null) return;
    switch (message['type']) {
      case 'retired':
        final int? epoch = (message['epoch'] as num?)?.toInt();
        _admission.acknowledgeRetire(epoch);
        _sendPendingRetire();
        _sendPendingConfiguration();
      case 'configured':
        final int? epoch = (message['epoch'] as num?)?.toInt();
        _admission.acknowledgeConfiguration(epoch);
        if (epoch == _epoch) _onMessage(null);
        _sendPendingConfiguration();
      case 'fault':
        final String messageText =
            message['message']?.toString() ?? 'The OPL2 music worker failed.';
        if (message['fatal'] == true) {
          _disableMusic(messageText);
        } else {
          final int? epoch = (message['epoch'] as num?)?.toInt();
          _admission.acknowledgeConfiguration(epoch);
          if (epoch == _epoch) _onMessage(messageText);
          _sendPendingConfiguration();
        }
      case 'stats':
        _statsPending = false;
        _latestStats = Map<Object?, Object?>.unmodifiable(message);
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

  void _failMusic(String message) {
    _lifecycle.disable();
    _statsPending = false;
    _latestStats = const <Object?, Object?>{};
    _onMessage(message);
  }

  void _disableMusic(String message) {
    if (_disposed) return;
    _lifecycle.disable();
    _statsPending = false;
    _latestStats = const <Object?, Object?>{};
    _admission.clear();
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _worker?.terminate();
    _worker = null;
    _node?.port.close();
    _node?.disconnect();
    _node = null;
    _onMessage(message);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle.dispose();
    _epoch++;
    _telemetryTimer?.cancel();
    _statsPending = false;
    _latestStats = const <Object?, Object?>{};
    _admission.clear();
    _node?.port.postMessage(
      <String, Object?>{'type': 'retire', 'epoch': _epoch}.jsify(),
    );
    _node?.port.close();
    _node?.disconnect();
    _worker?.terminate();
    _node = null;
    _worker = null;
  }

  static Map<Object?, Object?>? _messageMap(JSAny? data) {
    final Object? value = data?.dartify();
    return value is Map<Object?, Object?> ? value : null;
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

final class _WebMusicDiagnostics {
  const _WebMusicDiagnostics({
    required this.musicEpoch,
    required this.retireInFlight,
    required this.pendingRetireEpoch,
    required this.configurationInFlight,
    required this.retirePosts,
    required this.configurationPosts,
    required this.hasPendingConfiguration,
    required this.queuedMusicBlocks,
    required this.playedMusicFrames,
    required this.musicUnderruns,
    required this.musicAvailable,
  });

  final int musicEpoch;
  final int? retireInFlight;
  final int? pendingRetireEpoch;
  final int? configurationInFlight;
  final int retirePosts;
  final int configurationPosts;
  final bool hasPendingConfiguration;
  final int? queuedMusicBlocks;
  final int? playedMusicFrames;
  final int? musicUnderruns;
  final bool musicAvailable;
}

extension type _MusicArrayBufferView._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}
