import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_wad/doom_wad.dart' as wad;

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
  }) {
    if (!maxDistance.isFinite || maxDistance <= 0) {
      throw ArgumentError.value(maxDistance, 'maxDistance', 'must be positive');
    }
    final double dx = source.x - listener.position.x;
    final double dy = source.y - listener.position.y;
    final double distance = math.sqrt(dx * dx + dy * dy);
    final double volume = _clamp01(1 - distance / maxDistance);
    if (distance == 0) {
      return SpatializedSound(volume: volume, pan: 0);
    }

    final double radians =
        (listener.angle & 0xffffffff) * (2 * math.pi / 0x100000000);
    // Doom's map Y axis is the positive sine direction. The right vector for
    // a forward vector (cos, sin) is therefore (sin, -cos).
    final double right =
        (dx * math.sin(radians) - dy * math.cos(radians)) / distance;
    return SpatializedSound(
      volume: volume,
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
  const SoundDefinition({required this.sound, this.priority = 0});

  final PcmSound sound;
  final int priority;
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

  @override
  SoundDefinition? definitionFor(String soundId) {
    final wad.DoomSound? sound = resources.sound(soundId);
    if (sound == null) return null;
    return SoundDefinition(
      sound: pcmSoundFromDoom(sound),
      priority: priorityFor?.call(soundId) ?? 0,
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
  });

  final int channelId;
  final int playbackId;
  final String soundId;
  final Uint8List wavBytes;
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
  const _ActiveChannel({
    required this.request,
    required this.priority,
    required this.sequence,
    required this.expiresAtTic,
  });

  final AudioPlayRequest request;
  final int priority;
  final int sequence;
  final int expiresAtTic;
}

/// Fixed-channel Doom-style mixer.
///
/// Rules are intentionally explicit: a duplicate (sound, stable source, tic)
/// in one consumed journal batch is collapsed; an absent sound or zero-gain event
/// is dropped; when full, an incoming sound must have strictly greater
/// priority than the oldest active sound at the lowest priority, otherwise it
/// is dropped. Ties preserve the currently playing sound.
class SoundPlaybackManager {
  SoundPlaybackManager({
    required AudioBackend backend,
    required SoundCatalog catalog,
    int maxChannels = 8,
    this.maxDistance = 1200,
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
  int _sequence = 0;

  int get maxChannels => _channels.length;
  int get activeChannelCount => _channels.whereType<_ActiveChannel>().length;

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
    advanceToTic(gameTic);
    final List<core.SoundEvent> pending = List<core.SoundEvent>.of(events);
    if (pending.isEmpty) return;
    final Set<String> batchKeys = <String>{};

    for (final core.SoundEvent event in pending) {
      final String duplicateKey =
          '${event.soundId}:${event.sourceId}:${event.tic}';
      if (!batchKeys.add(duplicateKey)) continue;

      final SoundDefinition? definition = _catalog.definitionFor(event.soundId);
      if (definition == null) continue;
      final SpatializedSound spatial = !event.isPositional || event.fromPlayer
          ? const SpatializedSound(volume: 1, pan: 0)
          : DoomSoundSpatializer.calculate(
              source: AudioPosition(
                event.x / 65536,
                event.y / 65536,
                event.z / 65536,
              ),
              listener: listener,
              maxDistance: maxDistance,
            );
      if (spatial.volume <= 0) continue;

      final int channel = _chooseChannel(definition.priority);
      if (channel < 0) continue;
      final _ActiveChannel? victim = _channels[channel];
      if (victim != null) {
        await _backend.stop(channel);
        _channels[channel] = null;
      }
      final int playbackId = _sequence++;
      final AudioPlayRequest request = AudioPlayRequest(
        channelId: channel,
        playbackId: playbackId,
        soundId: event.soundId,
        wavBytes: encodeDoomPcmAsWav(
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
        sequence: playbackId,
        expiresAtTic: gameTic + _durationTics(definition.sound),
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

  int _chooseChannel(int incomingPriority) {
    for (int i = 0; i < _channels.length; i++) {
      if (_channels[i] == null) return i;
    }
    int victimIndex = 0;
    _ActiveChannel victim = _channels.first!;
    for (int i = 1; i < _channels.length; i++) {
      final _ActiveChannel candidate = _channels[i]!;
      if (candidate.priority < victim.priority ||
          (candidate.priority == victim.priority &&
              candidate.sequence < victim.sequence)) {
        victimIndex = i;
        victim = candidate;
      }
    }
    return incomingPriority > victim.priority ? victimIndex : -1;
  }

  Future<void> stopAll() async {
    for (int i = 0; i < _channels.length; i++) {
      if (_channels[i] != null) {
        await _backend.stop(i);
        _channels[i] = null;
      }
    }
  }

  Future<void> dispose() async {
    await stopAll();
    await _backend.dispose();
  }
}
