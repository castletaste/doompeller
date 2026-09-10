/// Pure state used by the browser audio transports.
///
/// Keeping admission and transition decisions independent from Web APIs makes
/// the cross-port ordering rules deterministic and directly testable on the VM.
enum AudioContextCommand { resume, suspend }

/// A browser may reject the requested native rate while supporting PCM audio
/// at its default rate. The caller still verifies the returned rate for music.
T createAudioContextWithFallback<T>(
  T Function(int? sampleRate) create, {
  required int nativeRate,
}) {
  try {
    return create(nativeRate);
  } catch (_) {
    return create(null);
  }
}

final class AudioTransportLifecycleState {
  int _generation = 0;
  bool _available = false;
  bool _disposed = false;

  bool get available => _available && !_disposed;
  bool get acceptsMessages => available;

  int beginInitialization() {
    if (_disposed) throw StateError('The audio transport is disposed.');
    _available = false;
    return ++_generation;
  }

  bool completeInitialization(int generation) {
    if (_disposed || generation != _generation) return false;
    _available = true;
    return true;
  }

  void disable() {
    if (_disposed) return;
    _available = false;
    _generation++;
  }

  void dispose() {
    _available = false;
    _disposed = true;
    _generation++;
  }
}

/// Identity of one admitted browser operation. A superseded Promise may still
/// settle; its completion must never retire a newer operation.
final class AudioContextRequest {
  AudioContextRequest._(this.command, [this.cancelledResume]);
  final AudioContextCommand command;
  final AudioContextRequest? cancelledResume;
}

final class AudioContextCommandState {
  AudioContextRequest? _resume;
  AudioContextRequest? _suspend;
  bool get resumePending => _resume != null;
  bool get suspendPending => _suspend != null;

  AudioContextRequest? takeNext({
    required bool unlocked,
    required bool shouldRun,
    required String contextState,
  }) {
    if (contextState == 'closed') return null;
    if (unlocked && shouldRun) {
      if (_resume != null || contextState == 'running') return null;
      return _resume = AudioContextRequest._(AudioContextCommand.resume);
    }
    if (_suspend != null || (contextState == 'suspended' && _resume == null)) {
      return null;
    }
    return _suspend = AudioContextRequest._(
      AudioContextCommand.suspend,
      _resume,
    );
  }

  /// A successful suspend supersedes the resume it followed, including when
  /// Chromium leaves that resume's Promise unresolved. This both bounds the
  /// Promise reconciliation loop and permits the next user gesture to resume.
  bool settle(AudioContextRequest request, {bool succeeded = true}) {
    switch (request.command) {
      case AudioContextCommand.resume:
        if (!identical(_resume, request)) return false;
        _resume = null;
      case AudioContextCommand.suspend:
        if (!identical(_suspend, request)) return false;
        _suspend = null;
        if (succeeded && identical(_resume, request.cancelledResume)) {
          _resume = null;
        }
    }
    return true;
  }

  void clear() {
    _resume = null;
    _suspend = null;
  }
}

final class MusicAdmissionState<T> {
  int? retireInFlight;
  int? pendingRetireEpoch;
  int? configurationInFlight;
  ({int epoch, T value})? _pendingConfiguration;

  T? get pendingConfiguration => _pendingConfiguration?.value;

  void replaceConfiguration(int epoch, T value) {
    _pendingConfiguration = (epoch: epoch, value: value);
  }

  void discardPendingConfiguration() {
    _pendingConfiguration = null;
  }

  void queueRetire(int epoch) {
    final int? pending = pendingRetireEpoch;
    if (pending == null || epoch > pending) pendingRetireEpoch = epoch;
  }

  int? takeRetire({required bool transportReady}) {
    if (!transportReady || retireInFlight != null) return null;
    final int? epoch = pendingRetireEpoch;
    if (epoch == null) return null;
    pendingRetireEpoch = null;
    retireInFlight = epoch;
    return epoch;
  }

  T? takeConfiguration({required bool transportReady}) {
    if (!transportReady ||
        retireInFlight != null ||
        pendingRetireEpoch != null ||
        configurationInFlight != null) {
      return null;
    }
    final pending = _pendingConfiguration;
    if (pending == null) return null;
    _pendingConfiguration = null;
    configurationInFlight = pending.epoch;
    return pending.value;
  }

  void acknowledgeRetire(int? epoch) {
    if (epoch == retireInFlight) retireInFlight = null;
  }

  void acknowledgeConfiguration(int? epoch) {
    if (epoch == configurationInFlight) configurationInFlight = null;
  }

  void clear() {
    retireInFlight = null;
    pendingRetireEpoch = null;
    configurationInFlight = null;
    _pendingConfiguration = null;
  }
}

final class PendingMusicConfigurations<T> {
  ({int epoch, T value})? _pending;

  void replace(int epoch, T value) {
    _pending = (epoch: epoch, value: value);
  }

  T? take() {
    final pending = _pending;
    _pending = null;
    return pending?.value;
  }

  int? abandonThrough(int epoch) {
    final pending = _pending;
    if (pending == null || pending.epoch > epoch) return null;
    _pending = null;
    return pending.epoch;
  }

  void clear() => _pending = null;
}
