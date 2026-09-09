/// Event kinds stored in a parsed Doom MUS score.
enum MusEventType { noteOff, noteOn, pitchWheel, systemEvent, controller }

/// One immutable MUS event at an absolute score tick.
///
/// Doom MUS converts with MIDI division 70 and a 500,000 microsecond beat,
/// which yields 140 ticks per second at the default tempo.
final class MusEvent {
  const MusEvent({
    required this.tick,
    required this.channel,
    required this.type,
    required this.data1,
    this.data2 = 0,
  });

  final int tick;
  final int channel;
  final MusEventType type;
  final int data1;
  final int data2;
}

/// A bounded, immutable Doom MUS score.
final class MusSong {
  MusSong({
    required List<MusEvent> events,
    required this.durationTicks,
    required this.primaryChannels,
    required this.secondaryChannels,
    required List<int> declaredInstrumentNumbers,
  }) : events = List<MusEvent>.unmodifiable(events),
       declaredInstrumentNumbers = List<int>.unmodifiable(
         declaredInstrumentNumbers,
       );

  final List<MusEvent> events;
  final int durationTicks;
  final int primaryChannels;
  final int secondaryChannels;
  final List<int> declaredInstrumentNumbers;
}

/// Six raw GENMIDI bytes written to one OPL2 operator.
final class GenMidiOperator {
  const GenMidiOperator({
    required this.characteristics,
    required this.attackDecay,
    required this.sustainRelease,
    required this.waveform,
    required this.keyScaleLevel,
    required this.outputLevel,
  });

  final int characteristics;
  final int attackDecay;
  final int sustainRelease;
  final int waveform;
  final int keyScaleLevel;
  final int outputLevel;
}

/// One of the two possible operator pairs in a GENMIDI instrument.
final class GenMidiVoice {
  const GenMidiVoice({
    required this.modulator,
    required this.carrier,
    required this.feedback,
    required this.baseNoteOffset,
  });

  final GenMidiOperator modulator;
  final GenMidiOperator carrier;
  final int feedback;

  /// Signed on-disk note offset used only by non-fixed-pitch instruments.
  final int baseNoteOffset;
}

/// One packed 36-byte GENMIDI instrument.
final class GenMidiInstrument {
  GenMidiInstrument({
    required this.flags,
    required this.rawFineTuning,
    required this.fixedNote,
    required List<GenMidiVoice> voices,
    required this.name,
  }) : voices = List<GenMidiVoice>.unmodifiable(voices);

  final int flags;

  /// Unsigned on-disk byte in the range 0..255.
  final int rawFineTuning;

  /// Informational signed form of [rawFineTuning], in the range -128..127.
  int get centeredFineTuning => rawFineTuning - 128;

  /// Doom 1.9's sub-voice-1 frequency-table offset.
  ///
  /// This must be computed from the raw byte. Dividing
  /// [centeredFineTuning] would round negative odd values differently.
  int get secondaryVoiceFineTuningSteps => rawFineTuning ~/ 2 - 64;

  /// Unsigned on-disk note byte used when [isFixedPitch] is true.
  final int fixedNote;
  final List<GenMidiVoice> voices;
  final String name;

  bool get isFixedPitch => (flags & 0x0001) != 0;
  bool get isDoubleVoice => (flags & 0x0004) != 0;
}

/// The 128 melodic and 47 percussion instruments in a GENMIDI lump.
final class GenMidiBank {
  GenMidiBank({
    required List<GenMidiInstrument> mainInstruments,
    required List<GenMidiInstrument> percussionInstruments,
  }) : mainInstruments = List<GenMidiInstrument>.unmodifiable(mainInstruments),
       percussionInstruments = List<GenMidiInstrument>.unmodifiable(
         percussionInstruments,
       );

  final List<GenMidiInstrument> mainInstruments;
  final List<GenMidiInstrument> percussionInstruments;
}
