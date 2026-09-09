import 'dart:typed_data';

import 'failures.dart';
import 'limits.dart';
import 'music_model.dart';

// The two reserved bytes after instrumentCount belong to the header, not to
// the declared instrument list. scoreStart may include further padding.
const int kMusHeaderBytes = 16;
const int kGenMidiHeaderBytes = 8;
const int kGenMidiInstrumentBytes = 36;
const int kGenMidiMainInstrumentCount = 128;
const int kGenMidiPercussionInstrumentCount = 47;
const int kGenMidiNameBytes = 32;

/// Parses a Doom MUS lump into immutable absolute-tick events.
MusSong parseMus(Uint8List bytes, {DoomLimits limits = DoomLimits.defaults}) {
  final int length = bytes.lengthInBytes;
  DoomLimits.check(length, limits.maxMusicBytes, 'maxMusicBytes');
  if (length < kMusHeaderBytes) {
    throw DoomFormatFailure(
      'MUS is $length bytes, shorter than its $kMusHeaderBytes byte header',
    );
  }
  if (bytes[0] != 0x4d ||
      bytes[1] != 0x55 ||
      bytes[2] != 0x53 ||
      bytes[3] != 0x1a) {
    throw const DoomFormatFailure(
      'bad MUS magic, expected MUS followed by 0x1a',
    );
  }

  final ByteData data = ByteData.sublistView(bytes);
  final int scoreLength = data.getUint16(4, Endian.little);
  final int scoreStart = data.getUint16(6, Endian.little);
  final int primaryChannels = data.getUint16(8, Endian.little);
  final int secondaryChannels = data.getUint16(10, Endian.little);
  final int instrumentCount = data.getUint16(12, Endian.little);
  DoomLimits.check(
    instrumentCount,
    limits.maxMusInstruments,
    'maxMusInstruments',
  );

  final int instrumentsEnd = kMusHeaderBytes + instrumentCount * 2;
  if (instrumentsEnd > length) {
    throw DoomFormatFailure(
      'MUS instrument list ends at $instrumentsEnd beyond $length bytes',
    );
  }
  if (scoreStart < instrumentsEnd || scoreStart > length) {
    throw DoomFormatFailure(
      'MUS scoreStart $scoreStart is before instrument data or beyond $length bytes',
    );
  }
  final int scoreEnd = scoreStart + scoreLength;
  if (scoreEnd < scoreStart || scoreEnd > length) {
    throw DoomFormatFailure(
      'MUS score spans $scoreStart..$scoreEnd beyond $length bytes',
    );
  }

  final List<int> instruments = List<int>.generate(
    instrumentCount,
    (int index) => data.getUint16(kMusHeaderBytes + index * 2, Endian.little),
    growable: false,
  );
  final List<int> velocities = List<int>.filled(16, 127);
  final List<MusEvent> events = <MusEvent>[];
  var cursor = scoreStart;
  var tick = 0;
  var foundEnd = false;

  int readByte(String field) {
    if (cursor >= scoreEnd) {
      throw DoomFormatFailure(
        'truncated MUS $field at score byte ${cursor - scoreStart}',
      );
    }
    return bytes[cursor++];
  }

  void add(MusEvent event) {
    DoomLimits.check(events.length + 1, limits.maxMusEvents, 'maxMusEvents');
    events.add(event);
  }

  while (cursor < scoreEnd && !foundEnd) {
    final int descriptor = readByte('event descriptor');
    final int channel = descriptor & 0x0f;
    final int kind = descriptor & 0x70;
    switch (kind) {
      case 0x00:
        add(
          MusEvent(
            tick: tick,
            channel: channel,
            type: MusEventType.noteOff,
            data1: readByte('note-off key') & 0x7f,
          ),
        );
      case 0x10:
        final int encodedKey = readByte('note-on key');
        if ((encodedKey & 0x80) != 0) {
          velocities[channel] = readByte('note-on velocity') & 0x7f;
        }
        add(
          MusEvent(
            tick: tick,
            channel: channel,
            type: MusEventType.noteOn,
            data1: encodedKey & 0x7f,
            data2: velocities[channel],
          ),
        );
      case 0x20:
        add(
          MusEvent(
            tick: tick,
            channel: channel,
            type: MusEventType.pitchWheel,
            data1: readByte('pitch wheel'),
          ),
        );
      case 0x30:
        final int controller = readByte('system controller');
        if (controller < 10 || controller > 14) {
          throw DoomFormatFailure('invalid MUS system controller $controller');
        }
        add(
          MusEvent(
            tick: tick,
            channel: channel,
            type: MusEventType.systemEvent,
            data1: controller,
          ),
        );
      case 0x40:
        final int controller = readByte('controller number');
        final int value = readByte('controller value');
        if (controller > 9) {
          throw DoomFormatFailure('invalid MUS controller $controller');
        }
        add(
          MusEvent(
            tick: tick,
            channel: channel,
            type: MusEventType.controller,
            data1: controller,
            data2: value > 127 ? 127 : value,
          ),
        );
      case 0x60:
        foundEnd = true;
      default:
        throw DoomFormatFailure(
          'invalid MUS event type 0x${kind.toRadixString(16)}',
        );
    }

    if (!foundEnd && (descriptor & 0x80) != 0) {
      var delay = 0;
      var delayBytes = 0;
      while (true) {
        final int byte = readByte('time delay');
        delayBytes++;
        if (delayBytes > 5 || delay > (limits.maxMusTicks >> 7)) {
          throw DoomLimitFailure(
            'MUS time delay exceeds maxMusTicks',
            limitName: 'maxMusTicks',
            limit: limits.maxMusTicks,
          );
        }
        delay = delay * 128 + (byte & 0x7f);
        if ((byte & 0x80) == 0) break;
      }
      tick += delay;
      DoomLimits.check(tick, limits.maxMusTicks, 'maxMusTicks');
    }
  }

  if (!foundEnd) {
    throw const DoomFormatFailure('MUS score has no end event');
  }
  return MusSong(
    events: List<MusEvent>.unmodifiable(events),
    durationTicks: tick,
    primaryChannels: primaryChannels,
    secondaryChannels: secondaryChannels,
    declaredInstrumentNumbers: List<int>.unmodifiable(instruments),
  );
}

/// Parses the fixed Doom GENMIDI instrument bank.
GenMidiBank parseGenMidi(
  Uint8List bytes, {
  DoomLimits limits = DoomLimits.defaults,
}) {
  final int length = bytes.lengthInBytes;
  DoomLimits.check(length, limits.maxGenMidiBytes, 'maxGenMidiBytes');
  const int instrumentCount =
      kGenMidiMainInstrumentCount + kGenMidiPercussionInstrumentCount;
  const int instrumentEnd =
      kGenMidiHeaderBytes + instrumentCount * kGenMidiInstrumentBytes;
  const int requiredBytes = instrumentEnd + instrumentCount * kGenMidiNameBytes;
  if (length < requiredBytes) {
    throw DoomFormatFailure(
      'GENMIDI is $length bytes, shorter than required $requiredBytes bytes',
    );
  }
  const List<int> magic = <int>[0x23, 0x4f, 0x50, 0x4c, 0x5f, 0x49, 0x49, 0x23];
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) {
      throw const DoomFormatFailure('bad GENMIDI magic, expected #OPL_II#');
    }
  }

  final ByteData data = ByteData.sublistView(bytes);
  GenMidiOperator readOperator(int offset) => GenMidiOperator(
    characteristics: bytes[offset],
    attackDecay: bytes[offset + 1],
    sustainRelease: bytes[offset + 2],
    waveform: bytes[offset + 3],
    keyScaleLevel: bytes[offset + 4],
    outputLevel: bytes[offset + 5],
  );

  String readName(int index) {
    final int start = instrumentEnd + index * kGenMidiNameBytes;
    var end = start;
    while (end < start + kGenMidiNameBytes && bytes[end] != 0) {
      end++;
    }
    while (end > start && bytes[end - 1] == 0x20) {
      end--;
    }
    return String.fromCharCodes(<int>[
      for (var i = start; i < end; i++)
        bytes[i] >= 0x20 && bytes[i] <= 0x7e ? bytes[i] : 0x5f,
    ]);
  }

  GenMidiInstrument readInstrument(int index) {
    final int offset = kGenMidiHeaderBytes + index * kGenMidiInstrumentBytes;
    final List<GenMidiVoice> voices = <GenMidiVoice>[];
    for (var voice = 0; voice < 2; voice++) {
      final int voiceOffset = offset + 4 + voice * 16;
      voices.add(
        GenMidiVoice(
          modulator: readOperator(voiceOffset),
          feedback: bytes[voiceOffset + 6],
          carrier: readOperator(voiceOffset + 7),
          baseNoteOffset: data.getInt16(voiceOffset + 14, Endian.little),
        ),
      );
    }
    return GenMidiInstrument(
      flags: data.getUint16(offset, Endian.little),
      rawFineTuning: bytes[offset + 2],
      fixedNote: bytes[offset + 3],
      voices: List<GenMidiVoice>.unmodifiable(voices),
      name: readName(index),
    );
  }

  final List<GenMidiInstrument> all = List<GenMidiInstrument>.generate(
    instrumentCount,
    readInstrument,
    growable: false,
  );
  return GenMidiBank(
    mainInstruments: List<GenMidiInstrument>.unmodifiable(
      all.sublist(0, kGenMidiMainInstrumentCount),
    ),
    percussionInstruments: List<GenMidiInstrument>.unmodifiable(
      all.sublist(kGenMidiMainInstrumentCount),
    ),
  );
}
