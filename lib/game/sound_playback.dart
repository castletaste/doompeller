import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_wad/doom_wad.dart' as wad;

import 'doom_sound_policy.dart';

/// A Doom sound sample: unsigned, mono, 8-bit PCM.
///
/// This is deliberately a small app-layer type. The WAD package can expose a
/// richer [DoomSound] later and the integration point can map it to this
/// representation without making the playback layer depend on a backend.
class PcmSound {
  const PcmSound({required this.sampleRate, required this.pcm});

  final int sampleRate;
  final Uint8List pcm;
}

PcmSound pcmSoundFromDoom(wad.DoomSound sound) =>
    PcmSound(sampleRate: sound.sampleRate, pcm: sound.pcm);

/// Encodes Doom's unsigned 8-bit mono PCM into a canonical RIFF/WAVE file.
///
/// The bytes are kept in memory here. A backend may choose how to submit them;
/// this class itself never opens a file or performs I/O.
Uint8List encodeDoomPcmAsWav({
  required int sampleRate,
  required Uint8List pcm,
}) {
  if (sampleRate <= 0 || sampleRate > 0xffffffff) {
    throw ArgumentError.value(sampleRate, 'sampleRate', 'must fit uint32');
  }
  final int padding = pcm.length.isOdd ? 1 : 0;
  if (pcm.length > 0xffffffff - 36 - padding) {
    throw ArgumentError.value(pcm.length, 'pcm', 'WAV data chunk is too large');
  }

  final Uint8List wav = Uint8List(44 + pcm.length + padding);
  final ByteData header = ByteData.sublistView(wav);
  void ascii(int offset, String value) {
    for (int i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length + padding, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM format.
  header.setUint16(22, 1, Endian.little); // Mono.
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate, Endian.little); // byteRate = rate * 1 * 8/8.
  header.setUint16(32, 1, Endian.little); // blockAlign = channels * bits / 8.
  header.setUint16(34, 8, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  wav.setRange(44, 44 + pcm.length, pcm);
  return wav;
}

/// A world-space point used by the sound layer. Coordinates are map units.
class AudioPosition {
  const AudioPosition(this.x, this.y, [this.z = 0]);

  final double x;
  final double y;
  final double z;
}

/// Listener orientation uses Doom's binary angle measurement (full turn =
/// 2^32), matching [doom_core]'s public PlayerView without importing the core
/// package into this independent playback implementation.
class AudioListener {
  const AudioListener({required this.position, required this.angle});

  final AudioPosition position;
  final int angle;
}

AudioListener audioListenerFromPlayer(core.PlayerView player) => AudioListener(
  position: AudioPosition(
    player.x / 65536,
    player.y / 65536,
    player.viewZ / 65536,
  ),
  angle: player.angle,
);

class SpatializedSound {
  const SpatializedSound({required this.volume, required this.pan});

  /// Linear gain in [0, 1].
  final double volume;

  /// Stereo balance: -1 is left, 0 is centre, +1 is right.
  final double pan;
}

/// Computes classic-style 2D sound attenuation and stereo separation.
abstract final class DoomSoundSpatializer {
  static SpatializedSound calculate({
    required AudioPosition source,
    required AudioListener listener,
    double maxDistance = 1200,
    bool bossArena = false,
  }) {
    if (!maxDistance.isFinite || maxDistance <= 0) {
      throw ArgumentError.value(maxDistance, 'maxDistance', 'must be positive');
    }
    final double dx = source.x - listener.position.x;
    final double dy = source.y - listener.position.y;
    // Doom's approximate distance, full-volume radius and stereo swing.
    // The output layer uses normalized gains; simulation remains integer-only.
    final double distance =
        dx.abs() + dy.abs() - math.min(dx.abs(), dy.abs()) / 2;
    final double closeDistance = math.min(160, maxDistance);
    final double minimum = bossArena ? 15 / 127 : 0;
    final double volume = distance < closeDistance
        ? 1
        : distance >= maxDistance
        ? minimum
        : minimum +
              (1 - minimum) *
                  ((maxDistance - distance).floor() /
                      (maxDistance - closeDistance));
    if (distance == 0) {
      return SpatializedSound(volume: volume, pan: 0);
    }

    final double radians =
        (listener.angle & 0xffffffff) * (2 * math.pi / 0x100000000);
    // Doom's map Y axis is the positive sine direction. The right vector for
    // a forward vector (cos, sin) is therefore (sin, -cos).
    final double right = -math.sin(math.atan2(dy, dx) - radians) * 0.75;
    return SpatializedSound(
      volume: _clamp01(volume),
      pan: right.clamp(-1.0, 1.0).toDouble(),
    );
  }

  static double _clamp01(double value) => value.clamp(0.0, 1.0).toDouble();
}

/// A separate journal contract. It must be backed by doom_core's sound journal
/// and must not be implemented by [GameState.consumeChangeJournal].
abstract interface class SoundJournal {
  Iterable<core.SoundEvent> consumeSoundJournal();
}

class SoundDefinition {
  const SoundDefinition({
    required this.sound,
    this.priority = 0,
    this.wavBytes,
  });

  final PcmSound sound;
  final int priority;

  /// Optional immutable encoding owned by a catalog with stable PCM samples.
  final Uint8List? wavBytes;
}

abstract interface class SoundCatalog {
  SoundDefinition? definitionFor(String soundId);
}

class MapSoundCatalog implements SoundCatalog {
  MapSoundCatalog(Map<String, SoundDefinition> definitions)
    : _definitions = Map<String, SoundDefinition>.unmodifiable(definitions);

  final Map<String, SoundDefinition> _definitions;

  @override
  SoundDefinition? definitionFor(String soundId) => _definitions[soundId];
}

/// In-memory catalog backed by the WAD parser. [WadResources.sound] returns
/// decoded PCM without writing it anywhere; the playback backend is still the
/// only component that decides how (or whether) to submit WAV bytes.
class WadSoundCatalog implements SoundCatalog {
  WadSoundCatalog(this.resources, {this.priorityFor});

  final wad.WadResources resources;
  final int Function(String soundId)? priorityFor;
  final _encoded = <String, ({PcmSound sound, Uint8List wav})>{};

  @override
  SoundDefinition? definitionFor(String soundId) {
    final key = soundId.toUpperCase();
    var encoded = _encoded[key];
    if (encoded == null) {
      final sound = resources.sound(key);
      if (sound == null) return null;
      encoded = (
        sound: pcmSoundFromDoom(sound),
        wav: encodeDoomPcmAsWav(
          sampleRate: sound.sampleRate,
          pcm: sound.pcm,
        ).asUnmodifiableView(),
      );
      _encoded[key] = encoded;
    }
    return SoundDefinition(
      sound: encoded.sound,
      wavBytes: encoded.wav,
      priority: priorityFor?.call(soundId) ?? doomSoundPriority(soundId),
    );
  }
}

/// Adapter for the output-only journal owned by [core.GameState]. Keeping this
/// separate from [GameState.consumeChangeJournal] is intentional: the sector
/// journal has exactly one renderer consumer.
class DoomCoreSoundJournal implements SoundJournal {
  DoomCoreSoundJournal(this.game);

  final core.GameState game;

  @override
  Iterable<core.SoundEvent> consumeSoundJournal() => game.consumeSoundJournal();
}

class AudioPlayRequest {
  const AudioPlayRequest({
    required this.channelId,
    required this.playbackId,
    required this.soundId,
    required this.wavBytes,
    required this.volume,
    required this.pan,
    required this.sourceId,
    required this.fromPlayer,
    this.pcmSound,
  });

  final int channelId;
  final int playbackId;
  final String soundId;
  final Uint8List wavBytes;

  /// Original PCM for backends that do not need a WAV container.
  final PcmSound? pcmSound;
  final double volume;
  final double pan;
  final int sourceId;
  final bool fromPlayer;
}

/// Playback boundary for a future native or package-backed implementation.
abstract interface class AudioBackend {
  /// [onComplete] lets a capable backend release a channel earlier than the
  /// deterministic game-tic duration fallback.
  Future<void> play(AudioPlayRequest request, {void Function()? onComplete});
  Future<void> stop(int channelId);
  Future<void> dispose();
}

/// Optional synchronous spatial updates, fenced by the current playback ID.
/// A zero volume retires that playback and invokes its completion callback.
abstract interface class SpatialAudioBackend {
  void updateSpatial({
    required int channelId,
    required int playbackId,
    required double volume,
    required double pan,
  });
}

class NoAudioBackend implements AudioBackend {
  const NoAudioBackend();

  @override
  Future<void> play(
    AudioPlayRequest request, {
    void Function()? onComplete,
  }) async {}

  @override
  Future<void> stop(int channelId) async {}

  @override
  Future<void> dispose() async {}
}

/// A deterministic backend for tests and diagnostics.
class FakeAudioBackend implements AudioBackend {
  final List<AudioPlayRequest> playCalls = <AudioPlayRequest>[];
  final List<int> stopCalls = <int>[];
  bool disposed = false;
  final Map<int, void Function()> _completionByPlayback =
      <int, void Function()>{};

  @override
  Future<void> play(
    AudioPlayRequest request, {
    void Function()? onComplete,
  }) async {
    playCalls.add(request);
    if (onComplete != null) {
      _completionByPlayback[request.playbackId] = onComplete;
    }
  }

  void complete(int playbackId) =>
      _completionByPlayback.remove(playbackId)?.call();

  @override
  Future<void> stop(int channelId) async {
    stopCalls.add(channelId);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _ActiveChannel {
  _ActiveChannel({
    required this.request,
    required this.priority,
    required this.expiresAtTic,
    required this.position,
  });

  final AudioPlayRequest request;
  final int priority;
  final int expiresAtTic;

  /// Null for player-local and non-positional sounds.
  AudioPosition? position;
}

/// Fixed-channel Doom-style mixer.
///
/// Rules are intentionally explicit: a duplicate (sound, stable source, tic)
/// in one consumed journal batch is collapsed; an absent sound or zero-gain event
/// is dropped. A source replaces its prior sound; otherwise use the first free
/// channel, or the first channel with a numerically equal/lower importance.
/// Lower numeric priorities are more important, matching Doom's sound table.
class SoundPlaybackManager {
  SoundPlaybackManager({
    required AudioBackend backend,
    required SoundCatalog catalog,
    int maxChannels = 8,
    this.maxDistance = 1200,
    this.bossArena = false,
  }) : _channels = List<_ActiveChannel?>.filled(maxChannels, null) {
    _backend = backend;
    _catalog = catalog;
    if (maxChannels <= 0) {
      throw ArgumentError.value(maxChannels, 'maxChannels', 'must be positive');
    }
    if (!maxDistance.isFinite || maxDistance <= 0) {
      throw ArgumentError.value(maxDistance, 'maxDistance', 'must be positive');
    }
  }

  late final AudioBackend _backend;
  late final SoundCatalog _catalog;
  final List<_ActiveChannel?> _channels;
  final double maxDistance;
  final bool bossArena;
  AudioListener? _latestListener;
  Map<int, AudioPosition> _latestSources = const {};
  int _sequence = 0;
  int _generation = 0;
  bool _disposed = false;

  int get maxChannels => _channels.length;
  int get activeChannelCount => _channels.whereType<_ActiveChannel>().length;
  bool get supportsSpatialUpdates => _backend is SpatialAudioBackend;

  Iterable<int> get activePositionalSources sync* {
    for (final channel in _channels) {
      if (channel?.position != null) yield channel!.request.sourceId;
    }
  }

  /// Only the latest positions are retained; empty tics never queue work.
  void updateSpatial({
    required AudioListener listener,
    Map<int, AudioPosition> sources = const {},
  }) {
    if (_disposed || _backend is! SpatialAudioBackend) return;
    _latestListener = listener;
    _latestSources = sources;
    final spatialBackend = _backend as SpatialAudioBackend;
    for (var i = 0; i < _channels.length; i++) {
      final active = _channels[i];
      if (active == null || active.position == null) continue;
      final request = active.request;
      active.position = sources[request.sourceId] ?? active.position;
      final spatial = DoomSoundSpatializer.calculate(
        source: active.position!,
        listener: listener,
        maxDistance: maxDistance,
        bossArena: bossArena,
      );
      spatialBackend.updateSpatial(
        channelId: i,
        playbackId: request.playbackId,
        volume: spatial.volume,
        pan: spatial.pan,
      );
      // Release the mixer slot immediately even if the backend completes
      // asynchronously. This is idempotent after a synchronous onComplete.
      if (spatial.volume <= 0) _complete(i, request.playbackId);
    }
  }

  /// Stops an in-flight batch at its next async boundary without losing the
  /// active channel IDs needed by the subsequent stop/dispose operation.
  void cancelPendingEvents() => _generation++;

  /// Advances the deterministic mixer clock even when this tic emitted no
  /// events, allowing completed channels to become observable immediately.
  void advanceToTic(int gameTic) => _releaseExpired(gameTic);

  Future<void> consumeJournal({
    required SoundJournal journal,
    required AudioListener listener,
    required int gameTic,
  }) async {
    await consumeEvents(
      events: journal.consumeSoundJournal(),
      listener: listener,
      gameTic: gameTic,
    );
  }

  Future<void> consumeEvents({
    required Iterable<core.SoundEvent> events,
    required AudioListener listener,
    required int gameTic,
  }) async {
    if (_disposed) return;
    final generation = _generation;
    advanceToTic(gameTic);
    final List<core.SoundEvent> pending = List<core.SoundEvent>.of(events);
    if (pending.isEmpty) return;
    final Set<String> batchKeys = <String>{};

    for (final core.SoundEvent event in pending) {
      if (_disposed || generation != _generation) return;
      final String duplicateKey =
          '${event.soundId}:${event.sourceId}:${event.tic}';
      if (!batchKeys.add(duplicateKey)) continue;

      final SoundDefinition? definition = _catalog.definitionFor(event.soundId);
      if (definition == null) continue;
      final SpatializedSound spatial = !event.isPositional || event.fromPlayer
          ? const SpatializedSound(volume: 1, pan: 0)
          : DoomSoundSpatializer.calculate(
              source:
                  _latestSources[event.sourceId] ??
                  AudioPosition(
                    event.x / 65536,
                    event.y / 65536,
                    event.z / 65536,
                  ),
              listener: _latestListener ?? listener,
              maxDistance: maxDistance,
              bossArena: bossArena,
            );
      if (spatial.volume <= 0) continue;

      final int channel = _chooseChannel(definition.priority, event.sourceId);
      if (channel < 0) continue;
      final _ActiveChannel? victim = _channels[channel];
      if (victim != null) {
        await _backend.stop(channel);
        if (_disposed || generation != _generation) return;
        _channels[channel] = null;
      }
      final int playbackId = _sequence++;
      final AudioPlayRequest request = AudioPlayRequest(
        channelId: channel,
        playbackId: playbackId,
        soundId: event.soundId,
        pcmSound: definition.sound,
        wavBytes:
            definition.wavBytes ??
            encodeDoomPcmAsWav(
              sampleRate: definition.sound.sampleRate,
              pcm: definition.sound.pcm,
            ),
        volume: spatial.volume,
        pan: spatial.pan,
        sourceId: event.sourceId,
        fromPlayer: event.fromPlayer,
      );
      _channels[channel] = _ActiveChannel(
        request: request,
        priority: definition.priority,
        expiresAtTic: gameTic + _durationTics(definition.sound),
        position: event.isPositional && !event.fromPlayer
            ? AudioPosition(event.x / 65536, event.y / 65536, event.z / 65536)
            : null,
      );
      try {
        await _backend.play(
          request,
          onComplete: () => _complete(channel, playbackId),
        );
      } on Object {
        if (_channels[channel]?.request.playbackId == playbackId) {
          _channels[channel] = null;
        }
        rethrow;
      }
    }
  }

  void _releaseExpired(int gameTic) {
    for (int i = 0; i < _channels.length; i++) {
      final _ActiveChannel? active = _channels[i];
      if (active != null && active.expiresAtTic <= gameTic) {
        _channels[i] = null;
      }
    }
  }

  static int _durationTics(PcmSound sound) {
    final int roundedUp =
        (sound.pcm.length * core.kTicRate + sound.sampleRate - 1) ~/
        sound.sampleRate;
    return math.max(1, roundedUp);
  }

  void _complete(int channel, int playbackId) {
    if (_channels[channel]?.request.playbackId == playbackId) {
      _channels[channel] = null;
    }
  }

  int _chooseChannel(int incomingPriority, int sourceId) {
    // A real origin owns at most one voice. UI/non-positional events have no
    // shared physical origin and may overlap.
    if (sourceId != core.SoundEvent.nonPositionalSourceId) {
      for (var i = 0; i < _channels.length; i++) {
        if (_channels[i]?.request.sourceId == sourceId) return i;
      }
    }
    for (int i = 0; i < _channels.length; i++) {
      if (_channels[i] == null) return i;
    }
    for (var i = 0; i < _channels.length; i++) {
      if (_channels[i]!.priority >= incomingPriority) return i;
    }
    return -1;
  }

  Future<void> stopAll() async {
    cancelPendingEvents();
    _latestListener = null;
    _latestSources = const {};
    Object? firstError;
    StackTrace? firstStack;
    for (int i = 0; i < _channels.length; i++) {
      if (_channels[i] != null) {
        _channels[i] = null;
        try {
          await _backend.stop(i);
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStack ??= stackTrace;
        }
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await stopAll();
    } finally {
      await _backend.dispose();
    }
  }
}
