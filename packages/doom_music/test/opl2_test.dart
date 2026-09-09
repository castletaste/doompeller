import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doom_music/src/failure.dart';
import 'package:doom_music/src/opl2.dart';
import 'package:test/test.dart';

void main() {
  group('Opl2Chip', () {
    test('renders the documented F-number and block pitch within one cent', () {
      const fNumber = 577;
      const block = 4;
      final chip = _programTone(Opl2Chip(), fNumber: fNumber, block: block);
      final output = Float32List(Opl2Chip.sampleRate * 2);
      chip.renderInto(output);

      final start = Opl2Chip.sampleRate ~/ 4;
      final crossings = _zeroCrossings(output, start, output.length);
      final measured =
          crossings / 2 / ((output.length - start) / Opl2Chip.sampleRate);
      final expected =
          fNumber *
          math.pow(2, block - 1) *
          Opl2Chip.sampleRate /
          math.pow(2, 19);
      final cents = 1200 * math.log(measured / expected) / math.ln2;

      expect(cents.abs(), lessThan(1));
    });

    test('half multiplier follows the block-one even-unit relation', () {
      final half = _programPhaseCarrier(fNumber: 975, block: 1, multiple: 0);
      final integer = _programPhaseCarrier(fNumber: 487, block: 1);
      final actual = Float32List(8192);
      final expected = Float32List(8192);
      half.renderInto(actual);
      integer.renderInto(expected);

      expect(_sameBits(actual, expected), isTrue);
    });

    test('phase scaling keeps both internal even-unit quantizers', () {
      final cases = <(Opl2Chip, Opl2Chip)>[
        (
          _programPhaseCarrier(fNumber: 975, block: 0),
          _programPhaseCarrier(fNumber: 974, block: 0),
        ),
        (
          _programPhaseCarrier(fNumber: 975, block: 0, multiple: 2),
          _programPhaseCarrier(fNumber: 974, block: 1),
        ),
        (
          _programPhaseCarrier(fNumber: 975, block: 2, multiple: 0),
          _programPhaseCarrier(fNumber: 975, block: 1),
        ),
      ];
      for (final (actualChip, expectedChip) in cases) {
        final actual = Float32List(8192);
        final expected = Float32List(8192);
        actualChip.renderInto(actual);
        expectedChip.renderInto(expected);
        expect(_sameBits(actual, expected), isTrue);
      }
    });

    test('all documented waveforms produce distinct output', () {
      final outputs = <Float32List>[];
      for (var waveform = 0; waveform < 4; waveform++) {
        final chip = _programTone(Opl2Chip(), waveform: waveform);
        final output = Float32List(8192);
        chip.renderInto(output);
        outputs.add(output);
      }

      for (var first = 0; first < outputs.length; first++) {
        for (var second = first + 1; second < outputs.length; second++) {
          expect(
            _sameBits(outputs[first], outputs[second]),
            isFalse,
            reason: 'waveforms $first and $second must differ',
          );
        }
      }
      expect(_zeroFraction(outputs[1]), greaterThan(0.35));
      expect(_zeroFraction(outputs[3]), greaterThan(0.35));
    });

    test('strong serial FM differs materially from an unmodulated carrier', () {
      final fmChip = _programTone(
        Opl2Chip(),
        additive: false,
        modulatorLevel: 0,
      );
      final plainChip = _programTone(Opl2Chip());
      final fm = Float32List(16384);
      final plain = Float32List(16384);
      fmChip.renderInto(fm);
      plainChip.renderInto(plain);

      expect(_differenceEnergy(fm, plain), greaterThan(0.001));
    });

    test('key-off enters a declining release envelope', () {
      final chip = _programTone(
        Opl2Chip(),
        attackDecay: 0xf4,
        sustainRelease: 0x48,
      );
      chip.renderInto(Float32List(12000));
      chip.writeRegister(0xb0, 0x12);
      final release = Float32List(24000);
      chip.renderInto(release);

      expect(
        _energy(release, 18000, 24000),
        lessThan(_energy(release, 0, 6000)),
      );
    });

    test('zero decay rate still enters sustain at a reached level', () {
      final held = _programTone(
        Opl2Chip(),
        attackDecay: 0xf0,
        sustainRelease: 0x0f,
      );
      final released = _programTone(
        Opl2Chip(),
        attackDecay: 0xf0,
        sustainRelease: 0x0f,
      );
      held.renderInto(Float32List(500));
      released
        ..renderInto(Float32List(500))
        ..writeRegister(0x23, 0x01);
      final heldOutput = Float32List(2048);
      final releasedOutput = Float32List(2048);
      held.renderInto(heldOutput);
      released.renderInto(releasedOutput);

      expect(_energy(heldOutput, 1536, 2048), greaterThan(0.001));
      expect(_energy(releasedOutput, 1536, 2048), lessThan(0.000001));
    });

    test('a lowered sustain target does not rewind a decaying envelope', () {
      final control = _programTone(
        Opl2Chip(),
        attackDecay: 0xff,
        sustainRelease: 0xff,
      );
      final lowered = _programTone(
        Opl2Chip(),
        attackDecay: 0xff,
        sustainRelease: 0xff,
      );
      control.renderInto(Float32List(30));
      lowered
        ..renderInto(Float32List(30))
        ..writeRegister(0x83, 0x0f);
      final expected = Float32List(512);
      final actual = Float32List(512);
      control.renderInto(expected);
      lowered.renderInto(actual);

      expect(_sameBits(actual, expected), isTrue);
    });

    test('a live sustain target holds its current attenuation band', () {
      final control = _programTone(
        Opl2Chip(),
        fNumber: 433,
        block: 3,
        attackDecay: 0xf4,
        sustainRelease: 0xf4,
      );
      final held = _programTone(
        Opl2Chip(),
        fNumber: 433,
        block: 3,
        attackDecay: 0xf4,
        sustainRelease: 0xf4,
      );
      control.renderInto(Float32List(320));
      held
        ..renderInto(Float32List(320))
        ..writeRegister(0x83, 0x04);
      final expected = Float32List(1024);
      final actual = Float32List(1024);
      control.renderInto(expected);
      held.renderInto(actual);

      expect(
        _sameBits(
          Float32List.sublistView(actual, 0, 452),
          Float32List.sublistView(expected, 0, 452),
        ),
        isTrue,
      );
      expect(actual[452], isNot(expected[452]));
      expect(
        _energy(actual, 768, 1024),
        greaterThan(_energy(expected, 768, 1024)),
      );
    });

    test('retrigger attacks from the current released level', () {
      final chip = _programTone(
        Opl2Chip(),
        attackDecay: 0x85,
        sustainRelease: 0x85,
      );
      chip.renderInto(Float32List(10000));
      chip.writeRegister(0xb0, 0x12);
      chip.renderInto(Float32List(500));
      chip.writeRegister(0xb0, 0x32);
      final retrigger = Float32List(16);
      chip.renderInto(retrigger);

      expect(retrigger.any((sample) => sample != 0), isTrue);
    });

    test('retrigger emits the old phase before consuming its reset', () {
      final control = _programTone(
        Opl2Chip(),
        attackDecay: 0xa0,
        sustainRelease: 0x00,
      );
      final retriggered = _programTone(
        Opl2Chip(),
        attackDecay: 0xa0,
        sustainRelease: 0x00,
      );
      control.renderInto(Float32List(4096));
      retriggered.renderInto(Float32List(4096));
      control.writeRegister(0xb0, 0x12);
      retriggered.writeRegister(0xb0, 0x12);
      control.renderInto(Float32List(100));
      retriggered.renderInto(Float32List(100));

      retriggered.writeRegister(0xb0, 0x32);
      final controlEdge = Float32List(2);
      final retriggerEdge = Float32List(2);
      control.renderInto(controlEdge);
      retriggered.renderInto(retriggerEdge);

      expect(retriggerEdge.first, controlEdge.first);
      expect(retriggerEdge.last, isNot(controlEdge.last));
    });

    test('coalesces same-frame key writes before consuming the edge', () {
      final control = _programTone(Opl2Chip());
      final coalesced = _programTone(Opl2Chip());
      control.renderInto(Float32List(4096));
      coalesced.renderInto(Float32List(4096));

      coalesced
        ..writeRegister(0xb0, 0x12)
        ..writeRegister(0xb0, 0x32);
      final expected = Float32List(4096);
      final actual = Float32List(4096);
      control.renderInto(expected);
      coalesced.renderInto(actual);

      expect(_sameBits(actual, expected), isTrue);
    });

    test('an attack-rate write cannot create a missing key edge', () {
      final chip = _programTone(Opl2Chip(), attackDecay: 0x00);
      chip.renderInto(Float32List(500));
      chip.writeRegister(0x63, 0xf0);
      final held = Float32List(256);
      chip.renderInto(held);
      expect(held.every((sample) => sample.abs() <= 2 / 32768), isTrue);

      chip.writeRegister(0xb0, 0x12);
      chip.renderInto(Float32List(10));
      chip.writeRegister(0xb0, 0x32);
      final retriggered = Float32List(256);
      chip.renderInto(retriggered);
      expect(retriggered.any((sample) => sample.abs() > 2 / 32768), isTrue);
    });

    test('a silent operator preserves the logarithmic sign bit', () {
      final chip = _programTone(Opl2Chip(), attackDecay: 0x00);
      final output = Float32List(4096);
      chip.renderInto(output);

      expect(
        output.every((sample) => sample == 0 || sample == -2 / 32768),
        isTrue,
      );
      expect(output.contains(-2 / 32768), isTrue);
    });

    test('shallow odd-F-number vibrato has no cycle phase drift', () {
      const fNumber = 0x1b1;
      final vibrato = _programVibratoCarrier(
        Opl2Chip(),
        fNumber: fNumber,
        vibrato: true,
      );
      final control = _programVibratoCarrier(Opl2Chip(), fNumber: fNumber);
      vibrato.renderInto(Float32List(8192));
      control.renderInto(Float32List(8192));
      vibrato.writeRegister(0x23, 0x21);

      final actual = Float32List(4096);
      final expected = Float32List(4096);
      vibrato.renderInto(actual);
      control.renderInto(expected);
      expect(_sameBits(actual, expected), isTrue);
    });

    test('deep vibrato follows the documented top-three F-number bits', () {
      const fNumber = 0x1b1;
      const deltas = <int>[0, 1, 3, 1, 0, -1, -3, -1];
      final vibrato = _programVibratoCarrier(
        Opl2Chip(),
        fNumber: fNumber,
        vibrato: true,
        deep: true,
      );
      final manual = _programVibratoCarrier(Opl2Chip(), fNumber: fNumber);
      final actual = Float32List(8192);
      final expected = Float32List(8192);
      for (var step = 0; step < deltas.length; step++) {
        _writePitch(manual, fNumber + deltas[step], 4);
        vibrato.renderInto(actual, offset: step * 1024, count: 1024);
        manual.renderInto(expected, offset: step * 1024, count: 1024);
      }
      expect(_sameBits(actual, expected), isTrue);
    });

    test('key scaling can promote attack rate fourteen to instant', () {
      final scaled =
          _programTone(Opl2Chip(), fNumber: 433, block: 2, attackDecay: 0xe0)
            ..writeRegister(0x20, 0x21)
            ..writeRegister(0x60, 0xf0)
            ..writeRegister(0x23, 0x31);
      final rawFifteen = _programTone(Opl2Chip(), fNumber: 433, block: 2);
      final actual = Float32List(256);
      final expected = Float32List(256);
      scaled.renderInto(actual);
      rawFifteen.renderInto(expected);
      expect(_sameBits(actual, expected), isTrue);
    });

    test('reprogrammed release rate is latched after a re-key slot', () {
      final slow = _programRekeyLatchChip();
      final fast = _programRekeyLatchChip();
      slow.renderInto(Float32List(512));
      fast.renderInto(Float32List(512));
      slow.writeRegister(0xb0, 0x11);
      fast.writeRegister(0xb0, 0x11);
      slow.renderInto(Float32List(100));
      fast.renderInto(Float32List(100));
      slow
        ..writeRegister(0x83, 0x00)
        ..writeRegister(0xb0, 0x31);
      fast
        ..writeRegister(0x83, 0x0f)
        ..writeRegister(0xb0, 0x31);

      final actual = Float32List(412);
      final expected = Float32List(412);
      slow.renderInto(actual);
      fast.renderInto(expected);
      expect(_sameBits(actual, expected), isTrue);
      expect(actual.any((sample) => sample.abs() > 2 / 32768), isTrue);
    });

    test('channel six carrier crosses the next accumulator sample', () {
      final firstGroupChip = _programTone(Opl2Chip());
      final secondGroupChip = _programTone(Opl2Chip(), channel: 6);
      firstGroupChip
        ..writeRegister(0x60, 0x00)
        ..writeRegister(0xe0, 0x01);
      secondGroupChip
        ..writeRegister(0x70, 0x00)
        ..writeRegister(0xf0, 0x01);
      final firstGroup = Float32List(4096);
      final secondGroup = Float32List(4096);
      firstGroupChip.renderInto(firstGroup);
      secondGroupChip.renderInto(secondGroup);

      expect(secondGroup.first, 0);
      expect(
        _sameBits(
          Float32List.sublistView(firstGroup, 0, firstGroup.length - 1),
          Float32List.sublistView(secondGroup, 1),
        ),
        isTrue,
      );
    });

    test('rendering is bit-identical across output chunk boundaries', () {
      final contiguousChip = _programTone(
        Opl2Chip(),
        additive: false,
        modulatorLevel: 0,
      );
      final chunkedChip = _programTone(
        Opl2Chip(),
        additive: false,
        modulatorLevel: 0,
      );
      final contiguous = Float32List(12289);
      final chunked = Float32List(12289);
      contiguousChip.renderInto(contiguous);
      chunkedChip
        ..renderInto(chunked, count: 1)
        ..renderInto(chunked, offset: 1, count: 4096)
        ..renderInto(chunked, offset: 4097);

      expect(_sameBits(contiguous, chunked), isTrue);
    });

    test('reset returns the chip to deterministic power-on state', () {
      final reused = _programTone(Opl2Chip());
      reused.renderInto(Float32List(5000));
      reused.reset();
      _writeTone(reused);
      final afterReset = Float32List(4096);
      reused.renderInto(afterReset);

      final fresh = _programTone(Opl2Chip());
      final expected = Float32List(4096);
      fresh.renderInto(expected);
      expect(_sameBits(afterReset, expected), isTrue);
    });

    test('rejects invalid calls and general YM3812 rhythm mode', () {
      final chip = Opl2Chip();
      expect(
        () => chip.writeRegister(-1, 0),
        throwsA(isA<MusicFormatFailure>()),
      );
      expect(
        () => chip.writeRegister(0, 256),
        throwsA(isA<MusicFormatFailure>()),
      );
      expect(
        () => chip.writeRegister(0xbd, 0x20),
        throwsA(isA<MusicUnsupportedFailure>()),
      );
      expect(
        () => chip.renderInto(Float32List(4), offset: 3, count: 2),
        throwsA(isA<MusicFormatFailure>()),
      );
    });
  });
}

Opl2Chip _programVibratoCarrier(
  Opl2Chip chip, {
  required int fNumber,
  bool vibrato = false,
  bool deep = false,
}) {
  for (final (address, value) in <(int, int)>[
    (0x01, 0x20),
    (0xbd, deep ? 0x40 : 0),
    (0x20, 0x21),
    (0x40, 0x3f),
    (0x60, 0x00),
    (0x80, 0x0f),
    (0xe0, 0x01),
    (0x23, vibrato ? 0x61 : 0x21),
    (0x43, 0x00),
    (0x63, 0xf0),
    (0x83, 0x0f),
    (0xe3, 0x00),
    (0xc0, 0x00),
  ]) {
    chip.writeRegister(address, value);
  }
  _writePitch(chip, fNumber, 4);
  return chip;
}

Opl2Chip _programPhaseCarrier({
  required int fNumber,
  required int block,
  int multiple = 1,
}) => _programTone(Opl2Chip(), fNumber: fNumber, block: block)
  ..writeRegister(0x60, 0x00)
  ..writeRegister(0xe0, 0x01)
  ..writeRegister(0x23, 0x20 | multiple);

Opl2Chip _programRekeyLatchChip() {
  final chip = Opl2Chip();
  for (final (address, value) in <(int, int)>[
    (0x01, 0x20),
    (0x20, 0x21),
    (0x40, 0x3f),
    (0x60, 0xf0),
    (0x80, 0x0f),
    (0x23, 0x21),
    (0x43, 0x00),
    (0x63, 0xa0),
    (0x83, 0x08),
    (0xc0, 0x01),
    (0xa0, 0xb1),
    (0xb0, 0x31),
  ]) {
    chip.writeRegister(address, value);
  }
  return chip;
}

void _writePitch(Opl2Chip chip, int fNumber, int block) {
  chip
    ..writeRegister(0xa0, fNumber & 0xff)
    ..writeRegister(0xb0, ((fNumber >> 8) & 3) | (block << 2) | 0x20);
}

Opl2Chip _programTone(
  Opl2Chip chip, {
  int fNumber = 577,
  int block = 4,
  int channel = 0,
  int waveform = 0,
  bool additive = true,
  int modulatorLevel = 0x3f,
  int attackDecay = 0xf0,
  int sustainRelease = 0x0f,
}) {
  _writeTone(
    chip,
    fNumber: fNumber,
    block: block,
    channel: channel,
    waveform: waveform,
    additive: additive,
    modulatorLevel: modulatorLevel,
    attackDecay: attackDecay,
    sustainRelease: sustainRelease,
  );
  return chip;
}

void _writeTone(
  Opl2Chip chip, {
  int fNumber = 577,
  int block = 4,
  int channel = 0,
  int waveform = 0,
  bool additive = true,
  int modulatorLevel = 0x3f,
  int attackDecay = 0xf0,
  int sustainRelease = 0x0f,
}) {
  const operatorOffsets = <(int, int)>[
    (0x00, 0x03),
    (0x01, 0x04),
    (0x02, 0x05),
    (0x08, 0x0b),
    (0x09, 0x0c),
    (0x0a, 0x0d),
    (0x10, 0x13),
    (0x11, 0x14),
    (0x12, 0x15),
  ];
  final (modulatorOffset, carrierOffset) = operatorOffsets[channel];
  for (final (address, value) in <(int, int)>[
    (0x01, 0x20),
    (0x20 + modulatorOffset, 0x21),
    (0x20 + carrierOffset, 0x21),
    (0x40 + modulatorOffset, modulatorLevel),
    (0x40 + carrierOffset, 0x00),
    (0x60 + modulatorOffset, attackDecay),
    (0x60 + carrierOffset, attackDecay),
    (0x80 + modulatorOffset, sustainRelease),
    (0x80 + carrierOffset, sustainRelease),
    (0xe0 + modulatorOffset, waveform),
    (0xe0 + carrierOffset, waveform),
    (0xc0 + channel, additive ? 1 : 0),
    (0xa0 + channel, fNumber & 0xff),
    (0xb0 + channel, ((fNumber >> 8) & 3) | (block << 2) | 0x20),
  ]) {
    chip.writeRegister(address, value);
  }
}

int _zeroCrossings(Float32List samples, int start, int end) {
  var crossings = 0;
  for (var index = start + 1; index < end; index++) {
    if ((samples[index - 1] < 0) != (samples[index] < 0)) {
      crossings++;
    }
  }
  return crossings;
}

double _zeroFraction(Float32List samples) {
  var zeroes = 0;
  for (final sample in samples) {
    if (sample == 0) {
      zeroes++;
    }
  }
  return zeroes / samples.length;
}

double _energy(Float32List samples, int start, int end) {
  var sum = 0.0;
  for (var index = start; index < end; index++) {
    sum += samples[index] * samples[index];
  }
  return sum / (end - start);
}

double _differenceEnergy(Float32List first, Float32List second) {
  var sum = 0.0;
  for (var index = 0; index < first.length; index++) {
    final difference = first[index] - second[index];
    sum += difference * difference;
  }
  return sum / first.length;
}

bool _sameBits(Float32List first, Float32List second) {
  final firstBits = Uint32List.view(
    first.buffer,
    first.offsetInBytes,
    first.length,
  );
  final secondBits = Uint32List.view(
    second.buffer,
    second.offsetInBytes,
    second.length,
  );
  for (var index = 0; index < firstBits.length; index++) {
    if (firstBits[index] != secondBits[index]) {
      return false;
    }
  }
  return true;
}
