import 'dart:typed_data';

import 'package:doompeller/game/sound_playback.dart';
import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter_test/flutter_test.dart';

PcmSound sound([int value = 0x80]) => PcmSound(
  sampleRate: 11025,
  pcm: Uint8List.fromList(<int>[value, value ^ 0xff]),
);

SoundDefinition definition(int priority) =>
    SoundDefinition(sound: sound(), priority: priority);

core.SoundEvent event({
  String soundId = 'DSPISTOL',
  core.SoundOrigin origin = core.SoundOrigin.world,
  int x = 0,
  int y = 0,
  int z = 0,
  int sourceId = 1,
  int tic = 1,
}) => core.SoundEvent(
  soundId: soundId,
  origin: origin,
  sourceId: sourceId,
  tic: tic,
  x: x,
  y: y,
  z: z,
);

void main() {
  test('WAV header is canonical little-endian mono unsigned PCM', () {
    final Uint8List wav = encodeDoomPcmAsWav(
      sampleRate: 11025,
      pcm: Uint8List.fromList(<int>[0, 127, 255]),
    );
    final ByteData bytes = ByteData.sublistView(wav);

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(wav, hasLength(48));
    expect(bytes.getUint32(4, Endian.little), 40);
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(bytes.getUint32(16, Endian.little), 16);
    expect(bytes.getUint16(20, Endian.little), 1);
    expect(bytes.getUint16(22, Endian.little), 1);
    expect(bytes.getUint32(24, Endian.little), 11025);
    expect(bytes.getUint32(28, Endian.little), 11025);
    expect(bytes.getUint16(32, Endian.little), 1);
    expect(bytes.getUint16(34, Endian.little), 8);
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(bytes.getUint32(40, Endian.little), 3);
    expect(wav.sublist(44), <int>[0, 127, 255, 0]);
  });

  test('spatializer attenuates distance and separates all cardinal cases', () {
    const AudioListener listener = AudioListener(
      position: AudioPosition(0, 0),
      angle: 0,
    );
    final SpatializedSound left = DoomSoundSpatializer.calculate(
      source: const AudioPosition(0, 10),
      listener: listener,
      maxDistance: 100,
    );
    final SpatializedSound right = DoomSoundSpatializer.calculate(
      source: const AudioPosition(0, -10),
      listener: listener,
      maxDistance: 100,
    );
    final SpatializedSound behind = DoomSoundSpatializer.calculate(
      source: const AudioPosition(-10, 0),
      listener: listener,
      maxDistance: 100,
    );
    final SpatializedSound far = DoomSoundSpatializer.calculate(
      source: const AudioPosition(200, 0),
      listener: listener,
      maxDistance: 100,
    );

    expect(left.pan, closeTo(-1, 1e-12));
    expect(right.pan, closeTo(1, 1e-12));
    expect(behind.pan, closeTo(0, 1e-12));
    expect(left.volume, closeTo(0.9, 1e-12));
    expect(far.volume, 0);
  });

  test(
    'mixer merges duplicate source sounds and evicts only lower priority',
    () async {
      final FakeAudioBackend backend = FakeAudioBackend();
      final SoundPlaybackManager mixer = SoundPlaybackManager(
        backend: backend,
        catalog: MapSoundCatalog(<String, SoundDefinition>{
          'DSPISTOL': definition(1),
          'DSPLASMA': definition(2),
        }),
        maxChannels: 1,
      );

      await mixer.consumeEvents(
        events: <core.SoundEvent>[event(), event()],
        listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
        gameTic: 1,
      );
      expect(backend.playCalls, hasLength(1));

      await mixer.consumeEvents(
        events: <core.SoundEvent>[
          event(soundId: 'DSPISTOL', sourceId: 2, tic: 2),
        ],
        listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
        gameTic: 1,
      );
      expect(backend.playCalls, hasLength(1));
      expect(backend.stopCalls, isEmpty);

      await mixer.consumeEvents(
        events: <core.SoundEvent>[
          event(soundId: 'DSPLASMA', sourceId: 3, tic: 3),
        ],
        listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
        gameTic: 1,
      );
      expect(backend.playCalls, hasLength(2));
      expect(backend.stopCalls, <int>[0]);
      expect(backend.playCalls.last.soundId, 'DSPLASMA');
    },
  );

  test(
    'event journal reaches fake backend with calculated playback fields',
    () async {
      final FakeAudioBackend backend = FakeAudioBackend();
      final SoundPlaybackManager mixer = SoundPlaybackManager(
        backend: backend,
        catalog: MapSoundCatalog(<String, SoundDefinition>{
          'DSPISTOL': definition(3),
        }),
      );
      final _FakeJournal journal = _FakeJournal(<core.SoundEvent>[
        event(y: 10 * 65536),
      ]);

      await mixer.consumeJournal(
        journal: journal,
        listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
        gameTic: 1,
      );

      expect(journal.consumed, isTrue);
      expect(backend.playCalls, hasLength(1));
      expect(backend.playCalls.single.soundId, 'DSPISTOL');
      expect(backend.playCalls.single.volume, closeTo(1190 / 1200, 1e-12));
      expect(backend.playCalls.single.pan, closeTo(-1, 1e-12));
      expect(backend.playCalls.single.wavBytes.sublist(0, 4), <int>[
        82,
        73,
        70,
        70,
      ]);
    },
  );

  test('playback does not change the simulation replay hash', () async {
    final core.GameState game = core.GameState.start(
      MapData.load(DoomFixtures.wadSet(), 'MAP01'),
      const core.GameConfig(),
      seed: 7,
    );
    final int before = game.hashState();
    final SoundPlaybackManager mixer = SoundPlaybackManager(
      backend: FakeAudioBackend(),
      catalog: MapSoundCatalog(<String, SoundDefinition>{
        'DSPISTOL': definition(1),
      }),
    );

    await mixer.consumeEvents(
      events: <core.SoundEvent>[event(origin: core.SoundOrigin.player)],
      listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
      gameTic: 1,
    );

    expect(game.hashState(), before);
  });

  test('expired short sounds free two channels for a third play', () async {
    final FakeAudioBackend backend = FakeAudioBackend();
    final SoundPlaybackManager mixer = SoundPlaybackManager(
      backend: backend,
      catalog: MapSoundCatalog(<String, SoundDefinition>{
        'DSPISTOL': SoundDefinition(
          sound: PcmSound(sampleRate: 11025, pcm: Uint8List(1)),
        ),
      }),
      maxChannels: 2,
    );
    const AudioListener listener = AudioListener(
      position: AudioPosition(0, 0),
      angle: 0,
    );

    await mixer.consumeEvents(
      events: <core.SoundEvent>[event(sourceId: 1, tic: 1)],
      listener: listener,
      gameTic: 1,
    );
    await mixer.consumeEvents(
      events: <core.SoundEvent>[event(sourceId: 2, tic: 1)],
      listener: listener,
      gameTic: 1,
    );
    await mixer.consumeEvents(
      events: <core.SoundEvent>[event(sourceId: 3, tic: 2)],
      listener: listener,
      gameTic: 2,
    );

    expect(backend.playCalls, hasLength(3));
    expect(mixer.activeChannelCount, 1);
  });

  test(
    'backend completion releases only its own playback generation',
    () async {
      final FakeAudioBackend backend = FakeAudioBackend();
      final SoundPlaybackManager mixer = SoundPlaybackManager(
        backend: backend,
        catalog: MapSoundCatalog(<String, SoundDefinition>{
          'DSPISTOL': definition(1),
          'DSPLASMA': definition(2),
        }),
        maxChannels: 1,
      );
      await mixer.consumeEvents(
        events: <core.SoundEvent>[event()],
        listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
        gameTic: 1,
      );
      final int oldPlayback = backend.playCalls.single.playbackId;
      await mixer.consumeEvents(
        events: <core.SoundEvent>[
          event(soundId: 'DSPLASMA', sourceId: 2, tic: 2),
        ],
        listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
        gameTic: 1,
      );
      final int currentPlayback = backend.playCalls.last.playbackId;

      backend.complete(oldPlayback);
      expect(mixer.activeChannelCount, 1);
      backend.complete(currentPlayback);
      expect(mixer.activeChannelCount, 0);
    },
  );

  test('dedup keeps distinct sources and tics at the same position', () async {
    final FakeAudioBackend backend = FakeAudioBackend();
    final SoundPlaybackManager mixer = SoundPlaybackManager(
      backend: backend,
      catalog: MapSoundCatalog(<String, SoundDefinition>{
        'DSPISTOL': definition(1),
      }),
      maxChannels: 3,
    );

    await mixer.consumeEvents(
      events: <core.SoundEvent>[
        event(sourceId: 10, tic: 4),
        event(sourceId: 11, tic: 4),
        event(sourceId: 10, tic: 5),
      ],
      listener: const AudioListener(position: AudioPosition(0, 0), angle: 0),
      gameTic: 4,
    );

    expect(backend.playCalls, hasLength(3));
  });

  test('failed replacement leaves no stopped ghost channel', () async {
    final _FailingAudioBackend backend = _FailingAudioBackend();
    final SoundPlaybackManager mixer = SoundPlaybackManager(
      backend: backend,
      catalog: MapSoundCatalog(<String, SoundDefinition>{
        'DSPISTOL': definition(1),
        'DSPLASMA': definition(2),
      }),
      maxChannels: 1,
    );
    const AudioListener listener = AudioListener(
      position: AudioPosition(0, 0),
      angle: 0,
    );
    await mixer.consumeEvents(
      events: <core.SoundEvent>[event()],
      listener: listener,
      gameTic: 1,
    );
    backend.failNext = true;

    await expectLater(
      mixer.consumeEvents(
        events: <core.SoundEvent>[
          event(soundId: 'DSPLASMA', sourceId: 2, tic: 2),
        ],
        listener: listener,
        gameTic: 1,
      ),
      throwsStateError,
    );
    expect(mixer.activeChannelCount, 0);
  });
}

class _FakeJournal implements SoundJournal {
  _FakeJournal(this._events);

  final List<core.SoundEvent> _events;
  bool consumed = false;

  @override
  Iterable<core.SoundEvent> consumeSoundJournal() {
    consumed = true;
    final List<core.SoundEvent> result = List<core.SoundEvent>.unmodifiable(
      _events,
    );
    _events.clear();
    return result;
  }
}

class _FailingAudioBackend extends FakeAudioBackend {
  bool failNext = false;

  @override
  Future<void> play(
    AudioPlayRequest request, {
    void Function()? onComplete,
  }) async {
    if (failNext) {
      failNext = false;
      throw StateError('synthetic play failure');
    }
    await super.play(request, onComplete: onComplete);
  }
}
