import 'dart:math' as math;
import 'dart:typed_data';

import 'failure.dart';

/// A mono, register-driven OPL2 synthesizer for Doom's melodic voice path.
///
/// The chip timebase is fixed at the YM3812 native output rate. Browser and
/// device sample-rate conversion belongs outside this class.
final class Opl2Chip {
  Opl2Chip()
    : _channels = List<_Channel>.generate(9, (_) => _Channel()),
      _operators = List<_Operator>.generate(18, (_) => _Operator());

  static const int sampleRate = 49716;

  static const int _phaseMask = 0xfffff;
  static const int _envelopeOff = 511;

  final Uint8List _registers = Uint8List(256);
  final List<_Channel> _channels;
  final List<_Operator> _operators;
  int _sampleClock = 0;

  void reset() {
    _registers.fillRange(0, _registers.length, 0);
    _sampleClock = 0;
    for (final channel in _channels) {
      channel.reset();
    }
    for (final operator in _operators) {
      operator.reset();
    }
  }

  void writeRegister(int address, int value) {
    _requireByte(address, 'address');
    _requireByte(value, 'value');
    if (address == 0xbd && (value & 0x20) != 0) {
      throw const MusicUnsupportedFailure(
        'OPL2 rhythm mode is outside the Doom melodic-voice path',
      );
    }

    _registers[address] = value;
    if (address >= 0xa0 && address <= 0xa8) {
      _updatePitch(address - 0xa0);
      return;
    }
    if (address >= 0xb0 && address <= 0xb8) {
      final channelIndex = address - 0xb0;
      _updatePitch(channelIndex);
      return;
    }
    if (address == 0x08) {
      for (var channel = 0; channel < _channels.length; channel++) {
        _updatePitch(channel);
      }
    }
  }

  void renderInto(Float32List output, {int offset = 0, int? count}) {
    if (offset < 0 || offset > output.length) {
      throw MusicFormatFailure(
        'render offset $offset is outside 0..${output.length}',
      );
    }
    final frameCount = count ?? output.length - offset;
    if (frameCount < 0 || frameCount > output.length - offset) {
      throw MusicFormatFailure(
        'render count $frameCount exceeds the output range',
      );
    }

    final end = offset + frameCount;
    for (var destination = offset; destination < end; destination++) {
      output[destination] = _renderFrame() / 32768.0;
    }
  }

  int _renderFrame() {
    final tremolo = _tremoloAttenuation();
    var mix = 0;

    for (
      var channelIndex = 0;
      channelIndex < _channels.length;
      channelIndex++
    ) {
      final channel = _channels[channelIndex];
      _consumeKeyEdge(channelIndex, channel);
      final modulatorIndex = channelIndex * 2;
      final carrierIndex = modulatorIndex + 1;
      final modulator = _operators[modulatorIndex];
      final carrier = _operators[carrierIndex];

      _clockEnvelope(channel, modulator);
      _clockEnvelope(channel, carrier);

      final feedbackPhase = _feedbackPhase(
        channel.feedbackFirst + channel.feedbackSecond,
        (_registers[0xc0 + channelIndex] >> 1) & 7,
      );
      final modulatorOutput = _operatorOutput(
        channel,
        modulator,
        modulatorIndex,
        feedbackPhase,
        tremolo,
      );

      // Slots are serialized within the chip sample: the carrier consumes the
      // modulator result produced immediately before it. Each operator emits
      // from its latched phase, then advances that phase for the next sample.
      channel.feedbackSecond = channel.feedbackFirst;
      channel.feedbackFirst = modulatorOutput;

      final additive = (_registers[0xc0 + channelIndex] & 1) != 0;
      final carrierOutput = _operatorOutput(
        channel,
        carrier,
        carrierIndex,
        additive ? 0 : modulatorOutput,
        tremolo,
      );
      _activatePendingAttack(modulator);
      _activatePendingAttack(carrier);
      if (channelIndex < 6) {
        mix += additive ? modulatorOutput + carrierOutput : carrierOutput;
      } else {
        mix += additive
            ? modulatorOutput + channel.delayedCarrierOutput
            : channel.delayedCarrierOutput;
        channel.delayedCarrierOutput = carrierOutput;
      }
    }

    _latchEnvelopeRegisters();
    _sampleClock++;
    return mix.clamp(-32768, 32767);
  }

  void _consumeKeyEdge(int channelIndex, _Channel channel) {
    if (channel.keyOn == channel.activeKeyOn) {
      return;
    }
    if (channel.keyOn) {
      _startVoice(channelIndex);
    } else {
      _releaseVoice(channelIndex);
    }
    channel.activeKeyOn = channel.keyOn;
  }

  int _operatorOutput(
    _Channel channel,
    _Operator operator,
    int operatorIndex,
    int phaseModulation,
    int tremolo,
  ) {
    final registerOffset = _operatorOffsets[operatorIndex];
    final characteristics = _registers[0x20 + registerOffset];
    final multiple = characteristics & 15;

    var fNumber = channel.fNumber;
    if ((characteristics & 0x40) != 0) {
      fNumber = (fNumber + _vibratoDelta(fNumber)).clamp(0, 1023);
    }
    final outputPhase = operator.phase;
    final phaseBase = (fNumber * (1 << channel.block)) & ~1;
    final increment = ((phaseBase * _multipleNumerators[multiple]) ~/ 2) & ~1;
    if (operator.resetPhaseAfterOutput) {
      operator.phase = 0;
      operator.resetPhaseAfterOutput = false;
    }
    operator.phase = (operator.phase + increment) & _phaseMask;

    final level = _registers[0x40 + registerOffset];
    var attenuation =
        operator.attenuation +
        (level & 0x3f) * 4 +
        _keyScaleAttenuation(channel, level >> 6);
    if ((characteristics & 0x80) != 0) {
      attenuation += tremolo;
    }
    final phase = ((outputPhase >> 10) + phaseModulation) & 0x3ff;
    final waveform = (_registers[0x01] & 0x20) == 0
        ? 0
        : _registers[0xe0 + registerOffset] & 3;
    return _waveformOutput(phase, waveform, attenuation);
  }

  void _clockEnvelope(_Channel channel, _Operator operator) {
    var stage = operator.stage;
    if (stage == _EnvelopeStage.off) {
      return;
    }
    final characteristics = operator.activeCharacteristics;
    final sustained = (characteristics & 0x20) != 0;
    if (stage == _EnvelopeStage.sustain) {
      if (sustained) {
        return;
      }
      operator.stage = stage = _EnvelopeStage.release;
    } else if (stage == _EnvelopeStage.release &&
        channel.activeKeyOn &&
        !operator.pendingAttack &&
        sustained) {
      operator.stage = _EnvelopeStage.sustain;
      return;
    }
    if (stage == _EnvelopeStage.attack && operator.attackDelay > 0) {
      operator.attackDelay--;
      return;
    }
    if (stage == _EnvelopeStage.release && operator.releaseDelay > 0) {
      operator.releaseDelay--;
      return;
    }

    final attackDecay = operator.activeAttackDecay;
    final sustainRelease = operator.activeSustainRelease;
    if (stage == _EnvelopeStage.decay) {
      final sustain = _sustainAttenuation(sustainRelease >> 4);
      if ((operator.attenuation >> 4) == (sustain >> 4)) {
        operator.stage = stage = sustained
            ? _EnvelopeStage.sustain
            : _EnvelopeStage.release;
        if (stage == _EnvelopeStage.sustain) {
          return;
        }
      }
    }
    final rawRate = switch (stage) {
      _EnvelopeStage.attack => attackDecay >> 4,
      _EnvelopeStage.decay => attackDecay & 15,
      _EnvelopeStage.release => sustainRelease & 15,
      _ => 0,
    };
    if (rawRate == 0) {
      return;
    }
    final keyScale = (characteristics & 0x10) != 0
        ? channel.keyScaleNumber
        : channel.keyScaleNumber >> 2;
    final rate = math.min(63, rawRate * 4 + keyScale);
    if (stage == _EnvelopeStage.attack && rate >= 60) {
      operator.attenuation = 0;
      operator.stage = _EnvelopeStage.decay;
      return;
    }
    final envelopeClock = stage == _EnvelopeStage.release
        ? _sampleClock - 4
        : _sampleClock - _attackClockOffset;
    final increment = _envelopeIncrement(rate, envelopeClock);
    if (increment == 0) {
      return;
    }

    switch (stage) {
      case _EnvelopeStage.attack:
        operator.attenuation += ((~operator.attenuation) * increment) >> 3;
        if (operator.attenuation <= 0) {
          operator.attenuation = 0;
          operator.stage = _EnvelopeStage.decay;
        }
      case _EnvelopeStage.decay:
        final previousAttenuation = operator.attenuation;
        operator.attenuation = math.min(
          _envelopeOff,
          operator.attenuation + increment,
        );
        final sustain = _sustainAttenuation(sustainRelease >> 4);
        if (previousAttenuation < sustain && operator.attenuation >= sustain) {
          operator.attenuation = sustain;
          operator.stage = (characteristics & 0x20) != 0
              ? _EnvelopeStage.sustain
              : _EnvelopeStage.release;
        }
      case _EnvelopeStage.release:
        operator.attenuation = math.min(
          _envelopeOff,
          operator.attenuation + increment,
        );
        if (operator.attenuation == _envelopeOff) {
          operator.stage = _EnvelopeStage.off;
        }
      case _EnvelopeStage.sustain:
      case _EnvelopeStage.off:
        break;
    }
  }

  void _updatePitch(int channelIndex) {
    final channel = _channels[channelIndex];
    final high = _registers[0xb0 + channelIndex];
    channel
      ..fNumber = _registers[0xa0 + channelIndex] | ((high & 3) << 8)
      ..block = (high >> 2) & 7
      ..keyOn = (high & 0x20) != 0;
    final noteSelect = (_registers[0x08] & 0x40) != 0;
    final splitBit = noteSelect
        ? (channel.fNumber >> 8) & 1
        : (channel.fNumber >> 9) & 1;
    channel.keyScaleNumber = channel.block * 2 + splitBit;
  }

  void _startVoice(int channelIndex) {
    for (var slot = 0; slot < 2; slot++) {
      final operatorIndex = channelIndex * 2 + slot;
      final operator = _operators[operatorIndex];
      final registerOffset = _operatorOffsets[operatorIndex];
      final attackRate = _registers[0x60 + registerOffset] >> 4;
      final characteristics = _registers[0x20 + registerOffset];
      final keyScale = (characteristics & 0x10) != 0
          ? _channels[channelIndex].keyScaleNumber
          : _channels[channelIndex].keyScaleNumber >> 2;
      final effectiveRate = math.min(63, attackRate * 4 + keyScale);
      operator
        ..resetPhaseAfterOutput = true
        ..pendingAttack = true
        ..pendingAttackOff = attackRate == 0
        ..pendingAttackDelay =
            attackRate < 15 &&
                effectiveRate >= 48 &&
                effectiveRate < 60 &&
                (effectiveRate & 3) == 0
            ? 1
            : effectiveRate < 48
            ? 1
            : 0;
    }
  }

  static void _activatePendingAttack(_Operator operator) {
    if (!operator.pendingAttack) {
      return;
    }
    operator
      ..pendingAttack = false
      ..attackDelay = operator.pendingAttackDelay
      ..releaseDelay = 0
      ..stage = operator.pendingAttackOff
          ? _EnvelopeStage.off
          : _EnvelopeStage.attack;
  }

  void _latchEnvelopeRegisters() {
    for (
      var operatorIndex = 0;
      operatorIndex < _operators.length;
      operatorIndex++
    ) {
      final registerOffset = _operatorOffsets[operatorIndex];
      _operators[operatorIndex]
        ..activeCharacteristics = _registers[0x20 + registerOffset]
        ..activeAttackDecay = _registers[0x60 + registerOffset]
        ..activeSustainRelease = _registers[0x80 + registerOffset];
    }
  }

  void _releaseVoice(int channelIndex) {
    for (var slot = 0; slot < 2; slot++) {
      final operator = _operators[channelIndex * 2 + slot];
      if (operator.stage != _EnvelopeStage.off) {
        operator
          ..releaseDelay = 2
          ..stage = _EnvelopeStage.release;
      }
    }
  }

  int _tremoloAttenuation() {
    final position = (_sampleClock >> 6) % 210;
    final triangle = position < 105 ? position : 210 - position;
    final deep = triangle >> 2;
    return (_registers[0xbd] & 0x80) != 0 ? deep : deep >> 2;
  }

  int _vibratoDelta(int fNumber) {
    final peak = fNumber >> 7;
    final shoulder = peak >> 1;
    final deep = switch ((_sampleClock >> 10) & 7) {
      0 || 4 => 0,
      1 || 3 => shoulder,
      2 => peak,
      5 || 7 => -shoulder,
      _ => -peak,
    };
    if ((_registers[0xbd] & 0x40) != 0) {
      return deep;
    }
    // Shallow vibrato halves the magnitude symmetrically. An arithmetic shift
    // would round negative odd values down and accumulate a DC phase error.
    return deep < 0 ? -((-deep) >> 1) : deep >> 1;
  }

  static int _feedbackPhase(int previousSum, int feedback) {
    if (feedback == 0) {
      return 0;
    }
    // The two stored outputs are summed before the documented feedback factor;
    // the extra bit keeps that sum in one operator-output unit.
    return previousSum >> (9 - feedback);
  }

  static int _envelopeIncrement(int rate, int clock) {
    if (rate < 4) {
      return 0;
    }
    if (rate >= 48) {
      return _highEnvelopePatterns[rate - 48][clock & 7];
    }
    final group = rate >> 2;
    final shift = 12 - group;
    final phase = shift >= 0 ? (clock >> shift) & 7 : clock & 7;
    if (shift > 0 && (clock & ((1 << shift) - 1)) != 0) {
      return 0;
    }
    final base = _envelopePatterns[rate & 3][phase];
    return shift < 0 ? base << -shift : base;
  }

  static int _keyScaleAttenuation(_Channel channel, int mode) {
    if (mode == 0 || channel.fNumber == 0) {
      return 0;
    }
    final octaveValue =
        _keyScaleTable[(channel.fNumber >> 6) & 15] -
        ((8 - channel.block) << 5);
    final base = math.max(0, octaveValue);
    return switch (mode) {
      1 => base >> 1,
      2 => base >> 2,
      3 => base,
      _ => 0,
    };
  }

  static int _waveformOutput(int phase, int waveform, int envelope) {
    var wavePhase = phase;
    switch (waveform) {
      case 1:
        if ((wavePhase & 0x200) != 0) {
          return 0;
        }
      case 2:
        wavePhase &= 0x1ff;
      case 3:
        if ((wavePhase & 0x100) != 0) {
          return 0;
        }
        wavePhase &= 0xff;
    }

    final negative = (wavePhase & 0x200) != 0;
    var quarter = wavePhase & 0xff;
    if ((wavePhase & 0x100) != 0) {
      quarter ^= 0xff;
    }
    final logarithmic = _logSineTable[quarter] + (envelope << 3);
    if (logarithmic >= 13 << 8) {
      return negative ? -1 : 0;
    }
    final magnitude =
        ((_exponentialTable[logarithmic & 0xff] + 1024) << 1) >>
        (logarithmic >> 8);
    // Yamaha emits the negative half as the one's complement of the positive
    // magnitude, rather than a symmetric arithmetic negation.
    return negative ? -magnitude - 1 : magnitude;
  }

  static int _sustainAttenuation(int value) => value == 15 ? 496 : value * 16;

  static void _requireByte(int value, String label) {
    if (value < 0 || value > 255) {
      throw MusicFormatFailure('$label $value is outside 0..255');
    }
  }
}

const int _attackClockOffset = 4;

enum _EnvelopeStage { off, attack, decay, sustain, release }

final class _Channel {
  int fNumber = 0;
  int block = 0;
  int keyScaleNumber = 0;
  bool keyOn = false;
  bool activeKeyOn = false;
  int feedbackFirst = 0;
  int feedbackSecond = 0;
  int delayedCarrierOutput = 0;

  void reset() {
    fNumber = 0;
    block = 0;
    keyScaleNumber = 0;
    keyOn = false;
    activeKeyOn = false;
    feedbackFirst = 0;
    feedbackSecond = 0;
    delayedCarrierOutput = 0;
  }
}

final class _Operator {
  int phase = 0;
  bool resetPhaseAfterOutput = false;
  bool pendingAttack = false;
  bool pendingAttackOff = false;
  int pendingAttackDelay = 0;
  int attenuation = Opl2Chip._envelopeOff;
  int attackDelay = 0;
  int releaseDelay = 0;
  int activeCharacteristics = 0;
  int activeAttackDecay = 0;
  int activeSustainRelease = 0;
  _EnvelopeStage stage = _EnvelopeStage.off;

  void reset() {
    phase = 0;
    resetPhaseAfterOutput = false;
    pendingAttack = false;
    pendingAttackOff = false;
    pendingAttackDelay = 0;
    attenuation = Opl2Chip._envelopeOff;
    attackDelay = 0;
    releaseDelay = 0;
    activeCharacteristics = 0;
    activeAttackDecay = 0;
    activeSustainRelease = 0;
    stage = _EnvelopeStage.off;
  }
}

final List<int> _logSineTable = List<int>.generate(256, (index) {
  final angle = (index + 0.5) * math.pi / 512.0;
  return (-math.log(math.sin(angle)) / math.ln2 * 256.0).round();
}, growable: false);

final List<int> _exponentialTable = List<int>.generate(
  256,
  (index) => ((math.pow(2.0, (255 - index) / 256.0) - 1.0) * 1024.0).round(),
  growable: false,
);

final List<int> _keyScaleTable = List<int>.generate(16, (index) {
  if (index == 0) {
    return 0;
  }
  return ((32.0 + 8.0 * math.log(index) / math.ln2).ceil()) << 2;
}, growable: false);

const List<List<int>> _envelopePatterns = <List<int>>[
  <int>[0, 1, 0, 1, 0, 1, 0, 1],
  <int>[0, 1, 0, 1, 1, 1, 0, 1],
  <int>[0, 1, 1, 1, 0, 1, 1, 1],
  <int>[0, 1, 1, 1, 1, 1, 1, 1],
];

const List<List<int>> _highEnvelopePatterns = <List<int>>[
  <int>[1, 0, 1, 0, 1, 0, 1, 0],
  <int>[1, 0, 1, 0, 1, 0, 1, 1],
  <int>[1, 0, 1, 1, 1, 0, 1, 1],
  <int>[1, 1, 1, 1, 1, 0, 1, 1],
  <int>[1, 1, 1, 1, 1, 1, 1, 1],
  <int>[2, 1, 1, 1, 1, 1, 1, 2],
  <int>[2, 1, 1, 2, 2, 1, 1, 2],
  <int>[2, 2, 2, 2, 2, 1, 1, 2],
  <int>[2, 2, 2, 2, 2, 2, 2, 2],
  <int>[4, 2, 2, 2, 2, 2, 2, 4],
  <int>[4, 2, 2, 4, 4, 2, 2, 4],
  <int>[4, 4, 4, 4, 4, 2, 2, 4],
  <int>[4, 4, 4, 4, 4, 4, 4, 4],
  <int>[4, 4, 4, 4, 4, 4, 4, 4],
  <int>[4, 4, 4, 4, 4, 4, 4, 4],
  <int>[4, 4, 4, 4, 4, 4, 4, 4],
];

const List<int> _multipleNumerators = <int>[
  1,
  2,
  4,
  6,
  8,
  10,
  12,
  14,
  16,
  18,
  20,
  20,
  24,
  24,
  30,
  30,
];

const List<int> _operatorOffsets = <int>[
  0x00,
  0x03,
  0x01,
  0x04,
  0x02,
  0x05,
  0x08,
  0x0b,
  0x09,
  0x0c,
  0x0a,
  0x0d,
  0x10,
  0x13,
  0x11,
  0x14,
  0x12,
  0x15,
];
