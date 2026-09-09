import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

const int _genMidiBytes = 8 + 175 * 36 + 175 * 32;

Uint8List _mus(
  List<int> score, {
  List<int> instruments = const <int>[],
  int padding = 0,
}) {
  final int scoreStart = 16 + instruments.length * 2 + padding;
  final Uint8List result = Uint8List(scoreStart + score.length);
  result.setRange(0, 4, const <int>[0x4d, 0x55, 0x53, 0x1a]);
  final ByteData data = ByteData.sublistView(result);
  data.setUint16(4, score.length, Endian.little);
  data.setUint16(6, scoreStart, Endian.little);
  data.setUint16(8, 3, Endian.little);
  data.setUint16(10, 1, Endian.little);
  data.setUint16(12, instruments.length, Endian.little);
  for (var i = 0; i < instruments.length; i++) {
    data.setUint16(16 + i * 2, instruments[i], Endian.little);
  }
  result.setRange(scoreStart, result.length, score);
  return result;
}

Uint8List _genMidi() {
  final Uint8List result = Uint8List(_genMidiBytes);
  result.setRange(0, 8, '#OPL_II#'.codeUnits);
  final ByteData data = ByteData.sublistView(result);

  void writeInstrument(int index, {required int rawFine, required int offset}) {
    final int start = 8 + index * 36;
    data.setUint16(start, 0x0005, Endian.little);
    result[start + 2] = rawFine;
    result[start + 3] = 61;
    result.setRange(start + 4, start + 10, const <int>[1, 2, 3, 4, 5, 6]);
    result[start + 10] = 7;
    result.setRange(start + 11, start + 17, const <int>[8, 9, 10, 11, 12, 13]);
    data.setInt16(start + 18, offset, Endian.little);
    final int name = 8 + 175 * 36 + index * 32;
    result.setRange(name, name + 4, 'TEST'.codeUnits);
  }

  writeInstrument(0, rawFine: 127, offset: -1234);
  writeInstrument(174, rawFine: 255, offset: 2345);
  return result;
}

void main() {
  group('parseMus', () {
    test('decodes absolute ticks, velocity reuse and padded score offsets', () {
      final MusSong song = parseMus(
        _mus(
          <int>[
            0x90,
            60 | 0x80,
            100,
            0x0e,
            0x91,
            61,
            0x00,
            0xa0,
            128,
            0x81,
            0x00,
            0xc0,
            3,
            200,
            0x01,
            0x80,
            60,
            0x07,
            0x60,
          ],
          instruments: const <int>[4, 133],
          padding: 3,
        ),
      );

      expect(song.durationTicks, 150);
      expect(song.primaryChannels, 3);
      expect(song.secondaryChannels, 1);
      expect(song.declaredInstrumentNumbers, <int>[4, 133]);
      expect(song.events.length, 5);
      expect(song.events.map((MusEvent e) => e.tick), <int>[
        0,
        14,
        14,
        142,
        143,
      ]);
      expect(song.events[0].type, MusEventType.noteOn);
      expect(song.events[0].data2, 100);
      expect(song.events[1].data2, 127);
      expect(song.events[2].data1, 128);
      expect(song.events[3].data2, 127, reason: 'controller values clamp');
      expect(() => song.events.add(song.events.first), throwsUnsupportedError);
      expect(
        () => song.declaredInstrumentNumbers.add(7),
        throwsUnsupportedError,
      );
    });

    test('skips the reserved header word before declared instruments', () {
      // Authored bytes keep the on-disk boundary independent of the builder.
      final Uint8List bytes = Uint8List.fromList(<int>[
        0x4d, 0x55, 0x53, 0x1a,
        1, 0, 20, 0, 1, 0, 0, 0, 2, 0,
        0x34, 0x12, // Reserved; not instrument 0x1234.
        29, 0, 181, 0,
        0x60,
      ]);
      final MusSong song = parseMus(bytes);
      expect(song.declaredInstrumentNumbers, <int>[29, 181]);
      expect(song.events, isEmpty);
      expect(song.durationTicks, 0);
    });

    test('rejects malformed structure and missing end', () {
      expect(() => parseMus(Uint8List(13)), throwsA(isA<DoomFormatFailure>()));
      expect(() => parseMus(Uint8List(15)), throwsA(isA<DoomFormatFailure>()));
      final Uint8List badMagic = _mus(const <int>[0x60])..[0] = 0;
      expect(() => parseMus(badMagic), throwsA(isA<DoomFormatFailure>()));
      expect(
        () => parseMus(_mus(const <int>[0x90, 60])),
        throwsA(isA<DoomFormatFailure>()),
      );
      final Uint8List badOffset = _mus(
        const <int>[0x60],
        instruments: const <int>[1],
      );
      ByteData.sublistView(badOffset).setUint16(6, 16, Endian.little);
      expect(() => parseMus(badOffset), throwsA(isA<DoomFormatFailure>()));
    });

    test('enforces byte, event, instrument and tick budgets', () {
      expect(
        () => parseMus(
          _mus(const <int>[0x60]),
          limits: const DoomLimits(maxMusicBytes: 10),
        ),
        throwsA(isA<DoomLimitFailure>()),
      );
      expect(
        () => parseMus(
          _mus(const <int>[0x10, 60, 0x60]),
          limits: const DoomLimits(maxMusEvents: 0),
        ),
        throwsA(isA<DoomLimitFailure>()),
      );
      expect(
        () => parseMus(
          _mus(const <int>[0x60], instruments: const <int>[1, 2]),
          limits: const DoomLimits(maxMusInstruments: 1),
        ),
        throwsA(isA<DoomLimitFailure>()),
      );
      expect(
        () => parseMus(
          _mus(const <int>[0x90, 60, 0x0b, 0x60]),
          limits: const DoomLimits(maxMusTicks: 10),
        ),
        throwsA(isA<DoomLimitFailure>()),
      );
    });
  });

  group('parseGenMidi', () {
    test('decodes fixed records, signed offsets, raw tuning and names', () {
      final GenMidiBank bank = parseGenMidi(_genMidi());
      expect(bank.mainInstruments.length, 128);
      expect(bank.percussionInstruments.length, 47);
      final GenMidiInstrument first = bank.mainInstruments.first;
      expect(first.flags, 5);
      expect(first.isFixedPitch, isTrue);
      expect(first.isDoubleVoice, isTrue);
      expect(first.rawFineTuning, 127);
      expect(first.centeredFineTuning, -1);
      expect(first.secondaryVoiceFineTuningSteps, -1);
      expect(first.fixedNote, 61);
      expect(first.name, 'TEST');
      expect(first.voices.first.baseNoteOffset, -1234);
      expect(first.voices.first.modulator.characteristics, 1);
      expect(first.voices.first.carrier.outputLevel, 13);
      expect(bank.percussionInstruments.last.voices.first.baseNoteOffset, 2345);
      expect(() => bank.mainInstruments.add(first), throwsUnsupportedError);
      expect(
        () => first.voices.add(first.voices.first),
        throwsUnsupportedError,
      );
    });

    test('rejects bad magic, truncation and configured size limit', () {
      expect(
        () => parseGenMidi(Uint8List(_genMidiBytes - 1)),
        throwsA(isA<DoomFormatFailure>()),
      );
      final Uint8List badMagic = _genMidi()..[0] = 0;
      expect(() => parseGenMidi(badMagic), throwsA(isA<DoomFormatFailure>()));
      expect(
        () => parseGenMidi(
          _genMidi(),
          limits: const DoomLimits(maxGenMidiBytes: 100),
        ),
        throwsA(isA<DoomLimitFailure>()),
      );
    });
  });

  test('WadResources memoises typed music and GENMIDI resources', () {
    final WadSet set = WadSet(<WadFile>[
      WadFile.parse(
        buildWad(<LumpSource>[
          LumpSource('PLAYPAL', buildFixturePlaypal()),
          LumpSource('COLORMAP', buildFixtureColormap()),
          LumpSource('D_TEST', _mus(const <int>[0x60])),
          LumpSource('GENMIDI', _genMidi()),
        ]),
      ),
    ]);
    final WadResources resources = WadResources.load(set);
    expect(
      identical(resources.musicSong('d_test'), resources.musicSong('D_TEST')),
      isTrue,
    );
    expect(identical(resources.genMidiBank, resources.genMidiBank), isTrue);
    expect(resources.musicSong('NOTMUS'), isNull);
  });

  test(
    'WadResources does not turn a failed GENMIDI decode into cached null',
    () {
      final WadResources resources = WadResources.load(
        WadSet(<WadFile>[
          WadFile.parse(
            buildWad(<LumpSource>[
              LumpSource('PLAYPAL', buildFixturePlaypal()),
              LumpSource('COLORMAP', buildFixtureColormap()),
              LumpSource('GENMIDI', Uint8List(8)),
            ]),
          ),
        ]),
      );
      expect(() => resources.genMidiBank, throwsA(isA<DoomFormatFailure>()));
      expect(() => resources.genMidiBank, throwsA(isA<DoomFormatFailure>()));
    },
  );
}
