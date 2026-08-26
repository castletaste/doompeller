import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

Uint8List dmx({
  int type = 3,
  int sampleRate = 11025,
  int declared = 4,
  List<int> bytes = const <int>[1, 2, 3, 4],
}) {
  final Uint8List out = Uint8List(8 + bytes.length);
  final ByteData data = ByteData.sublistView(out);
  data.setUint16(0, type, Endian.little);
  data.setUint16(2, sampleRate, Endian.little);
  data.setUint32(4, declared, Endian.little);
  out.setRange(8, out.length, bytes);
  return out;
}

WadResources resourcesWith(List<LumpSource> lumps) => WadResources.load(
  WadSet(<WadFile>[
    WadFile.parse(
      buildWad(<LumpSource>[
        LumpSource('PLAYPAL', buildFixturePlaypal()),
        LumpSource('COLORMAP', buildFixtureColormap()),
        ...lumps,
      ]),
    ),
  ]),
);

void main() {
  group('DMX sound decoder', () {
    test('round-trips generated fixture PCM and strips verified guards', () {
      final Uint8List lump = buildFixtureSound('DSPISTOL');
      final DoomSound decoded = decodeDoomSound(lump, name: 'dspistol');
      expect(decoded.name, 'DSPISTOL');
      expect(decoded.sampleRate, 11025);
      expect(decoded.sampleCount, 384);
      expect(decoded.pcm.first, lump[8 + 16]);
      expect(decoded.pcm.last, lump[lump.length - 17]);
    });

    test('does not strip unverified padding-like payload', () {
      final DoomSound decoded = decodeDoomSound(
        dmx(declared: 33, bytes: List<int>.generate(33, (int i) => i)),
      );
      expect(decoded.sampleCount, 33);
    });

    test('rejects every hostile header class with typed failures', () {
      expect(
        () => decodeDoomSound(Uint8List(7)),
        throwsA(isA<DoomFormatFailure>()),
      );
      expect(
        () => decodeDoomSound(dmx(type: 2)),
        throwsA(isA<DoomFormatFailure>()),
      );
      expect(
        () => decodeDoomSound(dmx(sampleRate: 0)),
        throwsA(isA<DoomFormatFailure>()),
      );
      expect(
        () => decodeDoomSound(dmx(sampleRate: 65535)),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxSoundSampleRate',
          ),
        ),
      );
      expect(
        () => decodeDoomSound(dmx(declared: 5)),
        throwsA(isA<DoomFormatFailure>()),
      );
      expect(
        () => decodeDoomSound(dmx(declared: 0xffffffff)),
        throwsA(isA<DoomFormatFailure>()),
      );
    });

    test('checks configured sample budget before allocating', () {
      expect(
        () => decodeDoomSound(
          dmx(),
          limits: const DoomLimits(maxSoundSamples: 3),
        ),
        throwsA(isA<DoomLimitFailure>()),
      );
    });
  });

  test('resource lookup is case insensitive and memoised', () {
    final WadResources resources = WadResources.load(DoomFixtures.wadSet());
    final DoomSound? lower = resources.sound('dspistol');
    expect(lower, isNotNull);
    expect(identical(lower, resources.sound('DSPISTOL')), isTrue);
    expect(resources.soundNames, containsAll(DoomFixtures.soundNames));
    expect(resources.sound('NOTSOUND'), isNull);
  });

  test('MUS signature is recognised without parsing music', () {
    final WadResources resources = resourcesWith(<LumpSource>[
      LumpSource(
        'D_MUS',
        Uint8List.fromList(<int>[0x4d, 0x55, 0x53, 0x1a, 1, 2]),
      ),
      LumpSource('D_RAW', Uint8List.fromList(<int>[0, 1, 2, 3])),
    ]);
    expect(resources.music('d_mus')?.isMus, isTrue);
    expect(resources.music('D_MUS')?.byteLength, 6);
    expect(resources.music('D_RAW')?.isMus, isFalse);
    expect(resources.music('D_NONE'), isNull);
  });
}
