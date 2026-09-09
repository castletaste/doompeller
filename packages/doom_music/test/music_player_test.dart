import 'dart:typed_data';

import 'package:doom_music/doom_music.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

GenMidiOperator _operator({int level = 0}) => GenMidiOperator(
  characteristics: 0x21,
  attackDecay: 0xf0,
  sustainRelease: 0xf3,
  waveform: 0,
  keyScaleLevel: 0,
  outputLevel: level,
);

GenMidiInstrument _instrument({
  int flags = 0,
  int rawFineTuning = 128,
  int fixedNote = 60,
  int carrierLevel = 0,
  int baseNoteOffset = 0,
}) => GenMidiInstrument(
  flags: flags,
  rawFineTuning: rawFineTuning,
  fixedNote: fixedNote,
  voices: <GenMidiVoice>[
    for (var voice = 0; voice < 2; voice++)
      GenMidiVoice(
        modulator: _operator(),
        carrier: _operator(level: carrierLevel),
        feedback: 0,
        baseNoteOffset: baseNoteOffset,
      ),
  ],
  name: 'SYNTHETIC',
);

GenMidiBank _bank({GenMidiInstrument? first, GenMidiInstrument? second}) {
  final GenMidiInstrument fallback = _instrument();
  return GenMidiBank(
    mainInstruments: <GenMidiInstrument>[
      first ?? fallback,
      second ?? fallback,
      ...List<GenMidiInstrument>.filled(126, fallback),
    ],
    percussionInstruments: List<GenMidiInstrument>.filled(47, fallback),
  );
}

MusSong _song(List<MusEvent> events, {int durationTicks = 14}) => MusSong(
  events: events,
  durationTicks: durationTicks,
  primaryChannels: 16,
  secondaryChannels: 0,
  declaredInstrumentNumbers: const <int>[],
);

typedef _Write = ({int sample, int address, int value});

void main() {
  test('emits the pinned bootstrap and a note in exact register order', () {
    final List<_Write> writes = <_Write>[];
    final DoomMusicPlayer player = DoomMusicPlayer(
      _song(<MusEvent>[
        const MusEvent(
          tick: 0,
          channel: 0,
          type: MusEventType.noteOn,
          data1: 60,
          data2: 100,
        ),
        const MusEvent(
          tick: 14,
          channel: 0,
          type: MusEventType.noteOff,
          data1: 60,
        ),
      ]),
      _bank(),
      loop: false,
      onRegisterWrite: (int sample, int address, int value) {
        writes.add((sample: sample, address: address, value: value));
      },
    );
    expect(writes.length, 239);
    expect(writes.first, (sample: 0, address: 0x40, value: 0x3f));
    expect(writes[238], (sample: 0, address: 0x08, value: 0x40));

    player.renderInto(Float32List(5000));
    expect(writes.sublist(239, 253), <_Write>[
      (sample: 0, address: 0x43, value: 0x3f),
      (sample: 0, address: 0x23, value: 0x21),
      (sample: 0, address: 0x63, value: 0xf0),
      (sample: 0, address: 0x83, value: 0xf3),
      (sample: 0, address: 0xe3, value: 0),
      (sample: 0, address: 0x40, value: 0),
      (sample: 0, address: 0x20, value: 0x21),
      (sample: 0, address: 0x60, value: 0xf0),
      (sample: 0, address: 0x80, value: 0xf3),
      (sample: 0, address: 0xe0, value: 0),
      (sample: 0, address: 0xc0, value: 0x30),
      (sample: 0, address: 0x43, value: 0x0c),
      (sample: 0, address: 0xa0, value: 0xb1),
      (sample: 0, address: 0xb0, value: 0x32),
    ]);
    expect(writes.last, (sample: 4971, address: 0xb0, value: 0x12));
  });

  test('uses a 5 ms loop gap and resets channel defaults', () {
    final List<_Write> writes = <_Write>[];
    final DoomMusicPlayer player = DoomMusicPlayer(
      _song(<MusEvent>[
        const MusEvent(
          tick: 0,
          channel: 0,
          type: MusEventType.noteOn,
          data1: 60,
          data2: 100,
        ),
        const MusEvent(
          tick: 7,
          channel: 0,
          type: MusEventType.noteOff,
          data1: 60,
        ),
      ]),
      _bank(),
      onRegisterWrite: (int sample, int address, int value) {
        writes.add((sample: sample, address: address, value: value));
      },
    );
    player.renderInto(Float32List(5300));
    expect(player.loopCount, 1);
    expect(
      writes
          .where(
            (_Write write) =>
                write.address >= 0xb0 &&
                write.address <= 0xb8 &&
                (write.value & 0x20) != 0,
          )
          .map((_Write write) => write.sample),
      <int>[0, 5220],
    );
  });

  test('whole and arbitrary chunks produce identical PCM and writes', () {
    final MusSong song = _song(<MusEvent>[
      const MusEvent(
        tick: 0,
        channel: 0,
        type: MusEventType.noteOn,
        data1: 60,
        data2: 90,
      ),
      const MusEvent(
        tick: 5,
        channel: 0,
        type: MusEventType.pitchWheel,
        data1: 192,
      ),
      const MusEvent(
        tick: 9,
        channel: 0,
        type: MusEventType.noteOff,
        data1: 60,
      ),
    ]);
    final List<_Write> wholeWrites = <_Write>[];
    final List<_Write> chunkWrites = <_Write>[];
    final DoomMusicPlayer whole = DoomMusicPlayer(
      song,
      _bank(),
      onRegisterWrite: (int sample, int address, int value) =>
          wholeWrites.add((sample: sample, address: address, value: value)),
    );
    final DoomMusicPlayer chunked = DoomMusicPlayer(
      song,
      _bank(),
      onRegisterWrite: (int sample, int address, int value) =>
          chunkWrites.add((sample: sample, address: address, value: value)),
    );
    final Float32List a = Float32List(9000);
    final Float32List b = Float32List(9000);
    whole.renderInto(a);
    var offset = 0;
    for (final int size in <int>[1, 17, 333, 2048, 7, 4096, 2498]) {
      chunked.renderInto(b, offset: offset, count: size);
      offset += size;
    }
    expect(offset, b.length);
    expect(b, a);
    expect(chunkWrites, wholeWrites);
    expect(chunked.renderedFrames, 9000);
  });

  test(
    'ignored sustain does not defer key-off and volume updates active TL',
    () {
      final List<_Write> writes = <_Write>[];
      final DoomMusicPlayer player = DoomMusicPlayer(
        _song(<MusEvent>[
          const MusEvent(
            tick: 0,
            channel: 0,
            type: MusEventType.noteOn,
            data1: 60,
            data2: 100,
          ),
          const MusEvent(
            tick: 2,
            channel: 0,
            type: MusEventType.controller,
            data1: 8,
            data2: 127,
          ),
          const MusEvent(
            tick: 3,
            channel: 0,
            type: MusEventType.controller,
            data1: 3,
            data2: 32,
          ),
          const MusEvent(
            tick: 4,
            channel: 0,
            type: MusEventType.controller,
            data1: 3,
            data2: 127,
          ),
          const MusEvent(
            tick: 5,
            channel: 0,
            type: MusEventType.noteOff,
            data1: 60,
          ),
        ], durationTicks: 5),
        _bank(),
        loop: false,
        onRegisterWrite: (int sample, int address, int value) =>
            writes.add((sample: sample, address: address, value: value)),
      );
      player.renderInto(Float32List(2000));
      expect(
        writes.where((_Write write) => write.sample == 710),
        isEmpty,
        reason: 'sustain at tick 2 has no register effect',
      );
      expect(writes, contains((sample: 1065, address: 0x43, value: 0x29)));
      expect(writes, contains((sample: 1420, address: 0x43, value: 0x06)));
      expect(writes, contains((sample: 1775, address: 0xb0, value: 0x12)));
    },
  );

  test('fixed-pitch instruments ignore their base-note offset', () {
    final List<_Write> writes = <_Write>[];
    final DoomMusicPlayer player = DoomMusicPlayer(
      _song(<MusEvent>[
        const MusEvent(
          tick: 0,
          channel: 0,
          type: MusEventType.noteOn,
          data1: 72,
          data2: 127,
        ),
      ], durationTicks: 1),
      _bank(first: _instrument(flags: 1, fixedNote: 36, baseNoteOffset: 42)),
      loop: false,
      onRegisterWrite: (int sample, int address, int value) =>
          writes.add((sample: sample, address: address, value: value)),
    );
    player.renderInto(Float32List(1));
    expect(writes, contains((sample: 0, address: 0xa0, value: 0xb1)));
    expect(writes, contains((sample: 0, address: 0xb0, value: 0x2a)));
  });

  test(
    'steals voice 8 deterministically and does not steal a double secondary',
    () {
      final List<MusEvent> events = <MusEvent>[];
      for (var channel = 0; channel < 8; channel++) {
        events.add(
          MusEvent(
            tick: 0,
            channel: channel,
            type: MusEventType.noteOn,
            data1: 48 + channel,
            data2: 100,
          ),
        );
      }
      events.addAll(const <MusEvent>[
        MusEvent(
          tick: 0,
          channel: 8,
          type: MusEventType.controller,
          data1: 0,
          data2: 1,
        ),
        MusEvent(
          tick: 0,
          channel: 8,
          type: MusEventType.noteOn,
          data1: 60,
          data2: 100,
        ),
      ]);
      final List<_Write> boundaryWrites = <_Write>[];
      final DoomMusicPlayer boundary = DoomMusicPlayer(
        _song(events, durationTicks: 1),
        _bank(second: _instrument(flags: 4)),
        loop: false,
        onRegisterWrite: (int sample, int address, int value) => boundaryWrites
            .add((sample: sample, address: address, value: value)),
      );
      boundary.renderInto(Float32List(1));
      expect(
        boundaryWrites
            .where(
              (_Write write) =>
                  write.address >= 0xb0 &&
                  write.address <= 0xb8 &&
                  (write.value & 0x20) != 0,
            )
            .length,
        9,
      );

      final List<_Write> stealWrites = <_Write>[];
      final DoomMusicPlayer steal = DoomMusicPlayer(
        _song(<MusEvent>[
          for (var channel = 0; channel < 9; channel++)
            MusEvent(
              tick: 0,
              channel: channel,
              type: MusEventType.noteOn,
              data1: 48 + channel,
              data2: 100,
            ),
          const MusEvent(
            tick: 0,
            channel: 0,
            type: MusEventType.noteOn,
            data1: 72,
            data2: 100,
          ),
        ], durationTicks: 1),
        _bank(),
        loop: false,
        onRegisterWrite: (int sample, int address, int value) =>
            stealWrites.add((sample: sample, address: address, value: value)),
      );
      steal.renderInto(Float32List(1));
      final List<_Write> voice8 = stealWrites
          .skip(239)
          .where((_Write write) => write.address == 0xb8)
          .toList();
      expect(voice8.length, 3);
      expect(voice8[1].value & 0x20, 0, reason: 'steal key-off');
      expect(voice8[2].value & 0x20, 0x20, reason: 'reused key-on');
    },
  );

  test('percussion accepts only 35 through 81', () {
    final List<_Write> writes = <_Write>[];
    final DoomMusicPlayer player = DoomMusicPlayer(
      _song(<MusEvent>[
        for (final int key in <int>[34, 35, 81, 82])
          MusEvent(
            tick: 0,
            channel: 15,
            type: MusEventType.noteOn,
            data1: key,
            data2: 100,
          ),
      ], durationTicks: 1),
      _bank(),
      loop: false,
      onRegisterWrite: (int sample, int address, int value) =>
          writes.add((sample: sample, address: address, value: value)),
    );
    player.renderInto(Float32List(1));
    expect(
      writes
          .where(
            (_Write write) =>
                write.address >= 0xb0 &&
                write.address <= 0xb8 &&
                (write.value & 0x20) != 0,
          )
          .length,
      2,
    );
  });

  test('rejects invalid render ranges and incomplete banks', () {
    expect(
      () => DoomMusicPlayer(
        _song(const <MusEvent>[]),
        GenMidiBank(
          mainInstruments: const <GenMidiInstrument>[],
          percussionInstruments: const <GenMidiInstrument>[],
        ),
      ),
      throwsA(isA<MusicFormatFailure>()),
    );
    final DoomMusicPlayer player = DoomMusicPlayer(
      _song(const <MusEvent>[]),
      _bank(),
      loop: false,
    );
    expect(
      () => player.renderInto(Float32List(4), offset: 3, count: 2),
      throwsA(isA<MusicFormatFailure>()),
    );
  });

  test('rejects malformed manually constructed song models', () {
    final GenMidiBank bank = _bank();
    for (final MusSong song in <MusSong>[
      _song(const <MusEvent>[], durationTicks: -1),
      _song(const <MusEvent>[
        MusEvent(
          tick: 2,
          channel: 0,
          type: MusEventType.noteOn,
          data1: 60,
          data2: 100,
        ),
      ], durationTicks: 1),
      _song(const <MusEvent>[
        MusEvent(
          tick: 0,
          channel: 16,
          type: MusEventType.noteOn,
          data1: 60,
          data2: 100,
        ),
      ]),
      _song(const <MusEvent>[
        MusEvent(
          tick: 0,
          channel: 0,
          type: MusEventType.noteOn,
          data1: 128,
          data2: 100,
        ),
      ]),
      _song(const <MusEvent>[
        MusEvent(
          tick: 0,
          channel: 0,
          type: MusEventType.controller,
          data1: 10,
          data2: 0,
        ),
      ]),
      _song(const <MusEvent>[
        MusEvent(
          tick: 0,
          channel: 0,
          type: MusEventType.pitchWheel,
          data1: 256,
        ),
      ]),
    ]) {
      expect(
        () => DoomMusicPlayer(song, bank),
        throwsA(isA<MusicFormatFailure>()),
      );
    }
  });
}
