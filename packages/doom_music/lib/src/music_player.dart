import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';

import 'dmx_tables.dart';
import 'failure.dart';
import 'opl2.dart';

typedef OplRegisterWrite = void Function(int sample, int address, int value);

/// Deterministic Doom 1.9 MUS/GENMIDI sequencer feeding one nine-voice OPL2.
final class DoomMusicPlayer {
  DoomMusicPlayer(
    this.song,
    this.bank, {
    this.loop = true,
    OplRegisterWrite? onRegisterWrite,
    // The public callback name is part of the package API, while its backing
    // field remains private.
    // ignore: prefer_initializing_formals
  }) : _onRegisterWrite = onRegisterWrite,
       _chip = Opl2Chip(),
       _events = _schedule(song) {
    _validateBank(bank);
    reset();
  }

  static const int sampleRate = Opl2Chip.sampleRate;
  static const int _tempoUsPerBeat = 500000;
  static const int _ticksPerBeat = 70;
  static const int _loopDelayUs = 5000;

  static const List<int> _modulatorSlots = <int>[
    0x00,
    0x01,
    0x02,
    0x08,
    0x09,
    0x0a,
    0x10,
    0x11,
    0x12,
  ];
  static const List<int> _carrierSlots = <int>[
    0x03,
    0x04,
    0x05,
    0x0b,
    0x0c,
    0x0d,
    0x13,
    0x14,
    0x15,
  ];

  final MusSong song;
  final GenMidiBank bank;
  final bool loop;
  final OplRegisterWrite? _onRegisterWrite;
  final Opl2Chip _chip;
  final List<_ScheduledEvent> _events;
  final List<_Channel> _channels = List<_Channel>.generate(
    16,
    _Channel.new,
    growable: false,
  );
  final List<_Voice> _voices = List<_Voice>.generate(
    9,
    _Voice.new,
    growable: false,
  );
  final List<_Voice> _free = <_Voice>[];
  final List<_Voice> _allocated = <_Voice>[];

  late int _cycleDurationUs;
  var _eventIndex = 0;
  var _cycleStartUs = 0;
  var _renderedFrames = 0;
  var _loopCount = 0;
  var _finished = false;

  int get renderedFrames => _renderedFrames;
  int get loopCount => _loopCount;

  /// Restores the chip, channel, allocator and score clock to their start state.
  void reset() {
    _chip.reset();
    _renderedFrames = 0;
    _loopCount = 0;
    _cycleStartUs = 0;
    _eventIndex = 0;
    _finished = false;
    _cycleDurationUs = _durationUs(song);
    _resetChannels();
    _allocated.clear();
    _free
      ..clear()
      ..addAll(_voices);
    for (final _Voice voice in _voices) {
      voice.reset();
    }
    _bootstrapRegisters();
  }

  /// Renders native-rate mono frames into the requested slice of [output].
  void renderInto(Float32List output, {int offset = 0, int? count}) {
    final int frameCount = count ?? output.length - offset;
    if (offset < 0 || frameCount < 0 || offset > output.length - frameCount) {
      throw MusicFormatFailure(
        'render range offset=$offset count=$frameCount exceeds ${output.length}',
      );
    }

    var destination = offset;
    final int destinationEnd = offset + frameCount;
    while (destination < destinationEnd) {
      _processDueEvents();
      final int? nextFrame = _nextActivityFrame();
      var span = destinationEnd - destination;
      if (nextFrame != null) {
        span = math.min(span, nextFrame - _renderedFrames);
      }
      if (span == 0) continue;
      _chip.renderInto(output, offset: destination, count: span);
      destination += span;
      _renderedFrames += span;
    }
  }

  void _bootstrapRegisters() {
    // Observable register sequence from Chocolate Doom 1.9's OPL2 reset.
    for (var register = 0x40; register <= 0x55; register++) {
      _write(register, 0x3f);
    }
    for (var register = 0x60; register <= 0xf5; register++) {
      _write(register, 0x00);
    }
    for (var register = 0x01; register < 0x40; register++) {
      _write(register, 0x00);
    }
    _write(0x04, 0x60);
    _write(0x04, 0x80);
    _write(0x01, 0x20);
    _write(0x08, 0x40);
  }

  void _processDueEvents() {
    while (!_finished) {
      if (_eventIndex < _events.length) {
        final _ScheduledEvent event = _events[_eventIndex];
        if (_sampleAt(_cycleStartUs + event.timeUs) > _renderedFrames) return;
        _handle(event);
        _eventIndex++;
        continue;
      }

      if (!loop) {
        _finished = true;
        return;
      }
      final int restartUs = _cycleStartUs + _cycleDurationUs + _loopDelayUs;
      if (_sampleAt(restartUs) > _renderedFrames) return;
      _cycleStartUs = restartUs;
      _eventIndex = 0;
      _loopCount++;
      _resetChannels();
    }
  }

  int? _nextActivityFrame() {
    if (_finished) return null;
    if (_eventIndex < _events.length) {
      return _sampleAt(_cycleStartUs + _events[_eventIndex].timeUs);
    }
    if (!loop) return null;
    return _sampleAt(_cycleStartUs + _cycleDurationUs + _loopDelayUs);
  }

  static int _sampleAt(int microseconds) =>
      microseconds * sampleRate ~/ Duration.microsecondsPerSecond;

  static int _deltaUs(int ticks) => ticks * _tempoUsPerBeat ~/ _ticksPerBeat;

  static int _durationUs(MusSong song) {
    var tick = 0;
    var microseconds = 0;
    for (final MusEvent event in song.events) {
      if (event.tick != tick) {
        microseconds += _deltaUs(event.tick - tick);
        tick = event.tick;
      }
    }
    if (song.durationTicks < tick) {
      throw const MusicFormatFailure('MUS duration precedes its final event');
    }
    return microseconds + _deltaUs(song.durationTicks - tick);
  }

  static List<_ScheduledEvent> _schedule(MusSong song) {
    if (song.durationTicks < 0) {
      throw const MusicFormatFailure('MUS durationTicks must be non-negative');
    }
    final List<int> channelMap = List<int>.filled(16, -1);
    const List<int> melodicOrder = <int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      10,
      11,
      12,
      13,
      14,
      9,
    ];
    var melodicCount = 0;
    var tick = 0;
    var microseconds = 0;
    final List<_ScheduledEvent> result = <_ScheduledEvent>[];
    for (final MusEvent event in song.events) {
      if (event.tick < 0 || event.tick < tick) {
        throw const MusicFormatFailure('MUS events are not ordered by tick');
      }
      if (event.tick != tick) {
        microseconds += _deltaUs(event.tick - tick);
        tick = event.tick;
      }
      final int musChannel = event.channel;
      if (musChannel < 0 || musChannel > 15) {
        throw MusicFormatFailure('MUS channel $musChannel is outside 0..15');
      }
      switch (event.type) {
        case MusEventType.noteOff:
          _checkRange(event.data1, 0, 127, 'note-off key');
        case MusEventType.noteOn:
          _checkRange(event.data1, 0, 127, 'note-on key');
          _checkRange(event.data2, 0, 127, 'note-on velocity');
        case MusEventType.pitchWheel:
          _checkRange(event.data1, 0, 255, 'pitch wheel');
        case MusEventType.systemEvent:
          _checkRange(event.data1, 10, 14, 'system controller');
        case MusEventType.controller:
          _checkRange(event.data1, 0, 9, 'controller number');
          _checkRange(event.data2, 0, 127, 'controller value');
      }
      var channel = channelMap[musChannel];
      if (channel < 0) {
        if (musChannel == 15) {
          channel = 15;
        } else {
          if (melodicCount >= melodicOrder.length) {
            throw const MusicFormatFailure('too many MUS melodic channels');
          }
          channel = melodicOrder[melodicCount++];
        }
        channelMap[musChannel] = channel;
      }
      result.add(_ScheduledEvent(microseconds, channel, event));
    }
    if (song.durationTicks < tick) {
      throw const MusicFormatFailure('MUS duration precedes its final event');
    }
    return List<_ScheduledEvent>.unmodifiable(result);
  }

  static void _checkRange(int value, int minimum, int maximum, String name) {
    if (value < minimum || value > maximum) {
      throw MusicFormatFailure('$name $value is outside $minimum..$maximum');
    }
  }

  static void _validateBank(GenMidiBank bank) {
    if (bank.mainInstruments.length != 128 ||
        bank.percussionInstruments.length != 47) {
      throw const MusicFormatFailure(
        'GENMIDI requires 128 melodic and 47 percussion instruments',
      );
    }
    for (final GenMidiInstrument instrument in <GenMidiInstrument>[
      ...bank.mainInstruments,
      ...bank.percussionInstruments,
    ]) {
      if (instrument.voices.length != 2) {
        throw const MusicFormatFailure(
          'GENMIDI instrument requires two voices',
        );
      }
      _checkRange(instrument.flags, 0, 0xffff, 'GENMIDI flags');
      _checkRange(instrument.rawFineTuning, 0, 0xff, 'GENMIDI fine tuning');
      _checkRange(instrument.fixedNote, 0, 0xff, 'GENMIDI fixed note');
      for (final GenMidiVoice voice in instrument.voices) {
        _checkRange(voice.feedback, 0, 0xff, 'GENMIDI feedback');
        _checkRange(
          voice.baseNoteOffset,
          -0x8000,
          0x7fff,
          'GENMIDI base-note offset',
        );
        for (final GenMidiOperator operator in <GenMidiOperator>[
          voice.modulator,
          voice.carrier,
        ]) {
          _checkRange(operator.characteristics, 0, 0xff, 'operator flags');
          _checkRange(operator.attackDecay, 0, 0xff, 'operator attack/decay');
          _checkRange(
            operator.sustainRelease,
            0,
            0xff,
            'operator sustain/release',
          );
          _checkRange(operator.waveform, 0, 0xff, 'operator waveform');
          _checkRange(operator.keyScaleLevel, 0, 0xff, 'operator KSL');
          _checkRange(operator.outputLevel, 0, 0xff, 'operator output level');
        }
      }
    }
  }

  void _resetChannels() {
    for (final _Channel channel in _channels) {
      channel.reset();
    }
  }

  void _handle(_ScheduledEvent scheduled) {
    final MusEvent event = scheduled.event;
    final int channel = scheduled.channel;
    switch (event.type) {
      case MusEventType.noteOff:
        _noteOff(channel, event.data1);
      case MusEventType.noteOn:
        if (event.data2 == 0) {
          _noteOff(channel, event.data1);
        } else {
          _noteOn(channel, event.data1, event.data2);
        }
      case MusEventType.pitchWheel:
        _setPitch(channel, (event.data1 >> 1) - 64);
      case MusEventType.systemEvent:
        if (event.data1 == 11) _allNotesOff(channel);
      case MusEventType.controller:
        _controller(channel, event.data1, event.data2);
    }
  }

  void _controller(int channelIndex, int controller, int value) {
    final _Channel channel = _channels[channelIndex];
    switch (controller) {
      case 0:
        channel.program = value.clamp(0, 127);
      case 3:
        channel.volume = value.clamp(0, 127);
        for (final _Voice voice in _voices) {
          if (voice.channel == channelIndex) _updateVolume(voice);
        }
      default:
      // Doom 1.9's OPL2 frontend ignores the other MUS mappings, including
      // pan and sustain.
    }
  }

  void _setPitch(int channelIndex, int bend) {
    final _Channel channel = _channels[channelIndex];
    channel.bend = bend.clamp(-64, 63);
    for (final _Voice voice in _allocated) {
      if (voice.channel != channelIndex) continue;
      final int frequency = _frequency(voice);
      if (frequency == voice.frequency) continue;
      voice.frequency = frequency;
      _write(0xa0 + voice.index, frequency & 0xff);
      _write(0xb0 + voice.index, (frequency >> 8) | 0x20);
    }
  }

  void _noteOn(int channelIndex, int key, int velocity) {
    if (key < 0 || key > 127 || velocity < 0 || velocity > 127) {
      throw MusicFormatFailure('invalid note key=$key velocity=$velocity');
    }

    late final GenMidiInstrument instrument;
    late final int instrumentId;
    var note = key;
    if (channelIndex == 15) {
      if (key < 35 || key > 81) return;
      instrumentId = 128 + key - 35;
      instrument = bank.percussionInstruments[key - 35];
      note = 60;
    } else {
      instrumentId = _channels[channelIndex].program;
      instrument = bank.mainInstruments[instrumentId];
    }

    _ensureFreeVoice();
    _startVoice(
      _takeFree(),
      channelIndex: channelIndex,
      key: key,
      note: note,
      velocity: velocity,
      instrument: instrument,
      instrumentId: instrumentId,
      subVoice: 0,
    );
    if (instrument.isDoubleVoice && _free.isNotEmpty) {
      _startVoice(
        _takeFree(),
        channelIndex: channelIndex,
        key: key,
        note: note,
        velocity: velocity,
        instrument: instrument,
        instrumentId: instrumentId,
        subVoice: 1,
      );
    }
  }

  void _ensureFreeVoice() {
    if (_free.isNotEmpty) return;
    var candidate = 0;
    for (var i = 0; i < _allocated.length; i++) {
      final _Voice current = _allocated[i];
      final _Voice selected = _allocated[candidate];
      if (current.subVoice != 0 || current.channel >= selected.channel) {
        candidate = i;
      }
    }
    _release(_allocated[candidate]);
  }

  _Voice _takeFree() {
    final _Voice voice = _free.removeAt(0);
    _allocated.add(voice);
    return voice;
  }

  void _startVoice(
    _Voice voice, {
    required int channelIndex,
    required int key,
    required int note,
    required int velocity,
    required GenMidiInstrument instrument,
    required int instrumentId,
    required int subVoice,
  }) {
    voice
      ..channel = channelIndex
      ..key = key
      ..note = note
      ..velocity = velocity
      ..instrument = instrument
      ..subVoice = subVoice;
    final GenMidiVoice definition = instrument.voices[subVoice];

    if (voice.instrumentId != instrumentId ||
        voice.cachedSubVoice != subVoice) {
      _programInstrument(voice, definition);
      voice
        ..instrumentId = instrumentId
        ..cachedSubVoice = subVoice;
    }
    _updateVolume(voice);
    final int frequency = _frequency(voice);
    voice.frequency = frequency;
    _write(0xa0 + voice.index, frequency & 0xff);
    _write(0xb0 + voice.index, (frequency >> 8) | 0x20);
  }

  void _programInstrument(_Voice voice, GenMidiVoice definition) {
    final int carrierSlot = _carrierSlots[voice.index];
    final int modulatorSlot = _modulatorSlots[voice.index];
    final GenMidiOperator carrier = definition.carrier;
    final GenMidiOperator modulator = definition.modulator;

    _write(0x40 + carrierSlot, (carrier.keyScaleLevel & 0xc0) | 0x3f);
    _write(0x20 + carrierSlot, carrier.characteristics);
    _write(0x60 + carrierSlot, carrier.attackDecay);
    _write(0x80 + carrierSlot, carrier.sustainRelease);
    _write(0xe0 + carrierSlot, carrier.waveform);
    voice.carrierLevel = 0x3f;

    final bool additive = (definition.feedback & 0x01) != 0;
    final int initialModulator = additive ? 0x3f : modulator.outputLevel & 0x3f;
    _write(
      0x40 + modulatorSlot,
      (modulator.keyScaleLevel & 0xc0) | initialModulator,
    );
    _write(0x20 + modulatorSlot, modulator.characteristics);
    _write(0x60 + modulatorSlot, modulator.attackDecay);
    _write(0x80 + modulatorSlot, modulator.sustainRelease);
    _write(0xe0 + modulatorSlot, modulator.waveform);
    voice.modulatorLevel = initialModulator;
    _write(0xc0 + voice.index, definition.feedback | 0x30);
  }

  void _updateVolume(_Voice voice) {
    final GenMidiVoice definition = voice.instrument!.voices[voice.subVoice];
    final int channelVolume = _channels[voice.channel].volume;
    final int midiVolume = 2 * (dmxVolumeCurve[channelVolume] + 1);
    final int fullVolume = dmxVolumeCurve[voice.velocity] * midiVolume >> 9;
    final int attenuation = 0x3f - fullVolume;

    final int carrierLevel = math.max(
      definition.carrier.outputLevel & 0x3f,
      attenuation,
    );
    if (carrierLevel != voice.carrierLevel) {
      voice.carrierLevel = carrierLevel;
      _write(
        0x40 + _carrierSlots[voice.index],
        (definition.carrier.keyScaleLevel & 0xc0) | carrierLevel,
      );
    }

    if ((definition.feedback & 0x01) != 0 &&
        (definition.modulator.outputLevel & 0x3f) != 0x3f) {
      final int modulatorLevel = math.max(
        definition.modulator.outputLevel & 0x3f,
        attenuation,
      );
      if (modulatorLevel != voice.modulatorLevel) {
        voice.modulatorLevel = modulatorLevel;
        _write(
          0x40 + _modulatorSlots[voice.index],
          (definition.modulator.keyScaleLevel & 0xc0) | modulatorLevel,
        );
      }
    }
  }

  int _frequency(_Voice voice) {
    final GenMidiInstrument instrument = voice.instrument!;
    final GenMidiVoice definition = instrument.voices[voice.subVoice];
    var note = instrument.isFixedPitch
        ? instrument.fixedNote
        : voice.note + definition.baseNoteOffset;
    while (note < 0) {
      note += 12;
    }
    while (note > 95) {
      note -= 12;
    }
    var index = 64 + 32 * note + _channels[voice.channel].bend;
    if (voice.subVoice == 1) {
      index += instrument.secondaryVoiceFineTuningSteps;
    }
    index = math.max(0, index);
    if (index < 284) return dmxFrequencyCurve[index];
    final int octave = math.min(7, (index - 284) ~/ 384);
    final int curveIndex = 284 + (index - 284) % 384;
    return dmxFrequencyCurve[curveIndex] | (octave << 10);
  }

  void _noteOff(int channel, int key) {
    for (final _Voice voice in List<_Voice>.of(_allocated)) {
      if (voice.channel == channel && voice.key == key) _release(voice);
    }
  }

  void _allNotesOff(int channel) {
    for (final _Voice voice in List<_Voice>.of(_allocated)) {
      if (voice.channel == channel) _release(voice);
    }
  }

  void _release(_Voice voice) {
    _write(0xb0 + voice.index, voice.frequency >> 8);
    voice
      ..channel = -1
      ..key = -1
      ..instrument = null;
    _allocated.remove(voice);
    _free.add(voice);
  }

  void _write(int address, int value) {
    _chip.writeRegister(address, value);
    _onRegisterWrite?.call(_renderedFrames, address, value);
  }
}

final class _ScheduledEvent {
  const _ScheduledEvent(this.timeUs, this.channel, this.event);

  final int timeUs;
  final int channel;
  final MusEvent event;
}

final class _Channel {
  _Channel(int _) {
    reset();
  }

  var program = 0;
  var volume = 100;
  var bend = 0;

  void reset() {
    program = 0;
    volume = 100;
    bend = 0;
  }
}

final class _Voice {
  _Voice(this.index);

  final int index;
  var channel = -1;
  var key = -1;
  var note = 0;
  var velocity = 0;
  var subVoice = 0;
  var instrumentId = -1;
  var cachedSubVoice = -1;
  var frequency = 0;
  var carrierLevel = 0x3f;
  var modulatorLevel = 0x3f;
  GenMidiInstrument? instrument;

  void reset() {
    channel = -1;
    key = -1;
    note = 0;
    velocity = 0;
    subVoice = 0;
    instrumentId = -1;
    cachedSubVoice = -1;
    frequency = 0;
    carrierLevel = 0x3f;
    modulatorLevel = 0x3f;
    instrument = null;
  }
}
