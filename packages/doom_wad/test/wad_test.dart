import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

/// Builds a minimal but valid WAD with the given lumps.
Uint8List tinyWad(List<LumpSource> lumps, {WadKind kind = WadKind.pwad}) =>
    buildWad(lumps, kind: kind);

Uint8List bytesOf(List<int> values) => Uint8List.fromList(values);

void main() {
  group('WadFile.parse', () {
    test('reads a well formed PWAD', () {
      final Uint8List wad = tinyWad(<LumpSource>[
        LumpSource('ALPHA', bytesOf(<int>[1, 2, 3])),
        LumpSource('BETA', bytesOf(<int>[4, 5])),
      ]);
      final WadFile parsed = WadFile.parse(wad);

      expect(parsed.kind, WadKind.pwad);
      expect(parsed.length, 2);
      expect(parsed.lumps[0].name, 'ALPHA');
      expect(parsed.lumps[1].name, 'BETA');
      expect(parsed.lumpBytes(0), <int>[1, 2, 3]);
      expect(parsed.lumpBytes(1), <int>[4, 5]);
    });

    test('reads an IWAD and distinguishes it from a PWAD', () {
      final WadFile parsed = WadFile.parse(
        tinyWad(<LumpSource>[LumpSource('X', bytesOf(<int>[0]))], kind: WadKind.iwad),
      );
      expect(parsed.kind, WadKind.iwad);
    });

    test('rejects bad magic', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('X', bytesOf(<int>[0]))]);
      wad[0] = 0x58; // 'X'
      expect(
        () => WadFile.parse(wad),
        throwsA(isA<DoomFormatFailure>().having((DoomFormatFailure f) => f.message, 'message', contains('magic'))),
      );
    });

    test('rejects a truncated header', () {
      expect(
        () => WadFile.parse(bytesOf(<int>[0x50, 0x57, 0x41, 0x44, 0, 0])),
        throwsA(isA<DoomFormatFailure>().having((DoomFormatFailure f) => f.message, 'message', contains('header'))),
      );
    });

    test('rejects an empty buffer', () {
      expect(() => WadFile.parse(Uint8List(0)), throwsA(isA<DoomFormatFailure>()));
    });

    test('rejects a directory offset past the end of the file', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('X', bytesOf(<int>[0]))]);
      ByteData.sublistView(wad).setInt32(8, wad.lengthInBytes + 64, Endian.little);
      expect(
        () => WadFile.parse(wad),
        throwsA(isA<DoomFormatFailure>().having((DoomFormatFailure f) => f.message, 'message', contains('directory'))),
      );
    });

    test('rejects a negative directory offset', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('X', bytesOf(<int>[0]))]);
      ByteData.sublistView(wad).setInt32(8, -16, Endian.little);
      expect(() => WadFile.parse(wad), throwsA(isA<DoomFormatFailure>()));
    });

    test('rejects a negative lump count', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('X', bytesOf(<int>[0]))]);
      ByteData.sublistView(wad).setInt32(4, -1, Endian.little);
      expect(() => WadFile.parse(wad), throwsA(isA<DoomFormatFailure>()));
    });

    test('rejects a lump that overflows the end of the file', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('X', bytesOf(<int>[1, 2, 3, 4]))]);
      final int directory = ByteData.sublistView(wad).getInt32(8, Endian.little);
      // Grow the lump so its range runs past the file.
      ByteData.sublistView(wad).setInt32(directory + 4, 4096, Endian.little);
      expect(
        () => WadFile.parse(wad),
        throwsA(isA<DoomFormatFailure>().having((DoomFormatFailure f) => f.message, 'message', contains('beyond'))),
      );
    });

    test('rejects a negative lump size', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('X', bytesOf(<int>[1]))]);
      final int directory = ByteData.sublistView(wad).getInt32(8, Endian.little);
      ByteData.sublistView(wad).setInt32(directory + 4, -8, Endian.little);
      expect(() => WadFile.parse(wad), throwsA(isA<DoomFormatFailure>()));
    });

    test('tolerates a garbage offset on a zero-length marker lump', () {
      final Uint8List wad = tinyWad(<LumpSource>[
        LumpSource.marker('F_START'),
        LumpSource('FLAT', bytesOf(<int>[7])),
      ]);
      final int directory = ByteData.sublistView(wad).getInt32(8, Endian.little);
      // Real WADs frequently store nonsense here; it must not be treated as a
      // range, because markers have no payload.
      ByteData.sublistView(wad).setInt32(directory, 0x7FFFFF00, Endian.little);

      final WadFile parsed = WadFile.parse(wad);
      expect(parsed.lumps[0].isMarker, isTrue);
      expect(parsed.lumpBytes(0), isEmpty);
      expect(parsed.lumpBytes(1), <int>[7]);
    });

    test('decodes names as 8 bytes, NUL padded and uppercased', () {
      final Uint8List wad = tinyWad(<LumpSource>[
        LumpSource('longname', bytesOf(<int>[1])),
        LumpSource('mixEd', bytesOf(<int>[2])),
      ]);
      final WadFile parsed = WadFile.parse(wad);
      expect(parsed.lumps[0].name, 'LONGNAME');
      expect(parsed.lumps[1].name, 'MIXED');
    });

    test('folds non-printable name bytes instead of throwing', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('AB', bytesOf(<int>[1]))]);
      final int directory = ByteData.sublistView(wad).getInt32(8, Endian.little);
      wad[directory + 8] = 0x01;
      wad[directory + 9] = 0xFE;
      final WadFile parsed = WadFile.parse(wad);
      expect(parsed.lumps[0].name, '__');
    });

    test('indexOfLump honours the from cursor', () {
      final WadFile parsed = WadFile.parse(
        tinyWad(<LumpSource>[
          LumpSource('DUP', bytesOf(<int>[1])),
          LumpSource('OTHER', bytesOf(<int>[2])),
          LumpSource('DUP', bytesOf(<int>[3])),
        ]),
      );
      expect(parsed.indexOfLump('DUP'), 0);
      expect(parsed.indexOfLump('DUP', from: 1), 2);
      expect(parsed.indexOfLump('MISSING'), isNull);
      expect(parsed.lastIndexOfLump('DUP'), 2);
    });

    test('lumpBytes rejects an out of range index', () {
      final WadFile parsed = WadFile.parse(tinyWad(<LumpSource>[LumpSource('A', bytesOf(<int>[1]))]));
      expect(() => parsed.lumpBytes(5), throwsA(isA<DoomFormatFailure>()));
      expect(() => parsed.lumpBytes(-1), throwsA(isA<DoomFormatFailure>()));
    });
  });

  group('DoomLimits', () {
    test('maxLumpCount produces a typed limit failure', () {
      final Uint8List wad = tinyWad(<LumpSource>[
        LumpSource('A', bytesOf(<int>[1])),
        LumpSource('B', bytesOf(<int>[2])),
      ]);
      expect(
        () => WadFile.parse(wad, limits: const DoomLimits(maxLumpCount: 1)),
        throwsA(isA<DoomLimitFailure>()
            .having((DoomLimitFailure f) => f.limitName, 'limitName', 'maxLumpCount')
            .having((DoomLimitFailure f) => f.limit, 'limit', 1)),
      );
    });

    test('maxLumpBytes produces a typed limit failure', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('A', Uint8List(64))]);
      expect(
        () => WadFile.parse(wad, limits: const DoomLimits(maxLumpBytes: 16)),
        throwsA(isA<DoomLimitFailure>()
            .having((DoomLimitFailure f) => f.limitName, 'limitName', 'maxLumpBytes')),
      );
    });

    test('maxWadBytes produces a typed limit failure', () {
      final Uint8List wad = tinyWad(<LumpSource>[LumpSource('A', Uint8List(64))]);
      expect(
        () => WadFile.parse(wad, limits: const DoomLimits(maxWadBytes: 32)),
        throwsA(isA<DoomLimitFailure>()
            .having((DoomLimitFailure f) => f.limitName, 'limitName', 'maxWadBytes')),
      );
    });
  });

  group('WadSet', () {
    test('later entries override earlier ones', () {
      final WadFile iwad = WadFile.parse(
        tinyWad(<LumpSource>[
          LumpSource('SHARED', bytesOf(<int>[1])),
          LumpSource('ONLYIWAD', bytesOf(<int>[2])),
        ], kind: WadKind.iwad),
      );
      final WadFile pwad = WadFile.parse(
        tinyWad(<LumpSource>[
          LumpSource('SHARED', bytesOf(<int>[9])),
          LumpSource('ONLYPWAD', bytesOf(<int>[3])),
        ]),
      );
      final WadSet set = WadSet(<WadFile>[iwad, pwad]);

      expect(set.length, 4);
      expect(set.read('SHARED'), <int>[9]);
      expect(set.read('ONLYIWAD'), <int>[2]);
      expect(set.read('ONLYPWAD'), <int>[3]);
      expect(set.read('NOPE'), isNull);
    });

    test('reversing the order reverses which lump wins', () {
      final WadFile a = WadFile.parse(tinyWad(<LumpSource>[LumpSource('SHARED', bytesOf(<int>[1]))]));
      final WadFile b = WadFile.parse(tinyWad(<LumpSource>[LumpSource('SHARED', bytesOf(<int>[2]))]));
      expect(WadSet(<WadFile>[a, b]).read('SHARED'), <int>[2]);
      expect(WadSet(<WadFile>[b, a]).read('SHARED'), <int>[1]);
    });

    test('indexOf, bytesAt and entryAt agree', () {
      final WadSet set = WadSet(<WadFile>[
        WadFile.parse(tinyWad(<LumpSource>[
          LumpSource('A', bytesOf(<int>[1, 1])),
          LumpSource('B', bytesOf(<int>[2])),
        ])),
      ]);
      final int index = set.indexOf('B')!;
      expect(set.nameAt(index), 'B');
      expect(set.entryAt(index).size, 1);
      expect(set.bytesAt(index), <int>[2]);
      expect(set.wadIndexAt(index), 0);
      expect(() => set.bytesAt(99), throwsA(isA<DoomFormatFailure>()));
    });

    test('require throws a missing lump failure', () {
      final WadSet set = WadSet(<WadFile>[
        WadFile.parse(tinyWad(<LumpSource>[LumpSource('A', bytesOf(<int>[1]))])),
      ]);
      expect(set.require('A'), <int>[1]);
      expect(
        () => set.require('GONE'),
        throwsA(isA<DoomMissingLumpFailure>().having((DoomMissingLumpFailure f) => f.lumpName, 'lumpName', 'GONE')),
      );
    });

    test('mapNames finds ExMy and MAPxx markers only', () {
      final WadSet set = WadSet(<WadFile>[
        WadFile.parse(tinyWad(<LumpSource>[
          LumpSource.marker('MAP01'),
          LumpSource.marker('E1M1'),
          LumpSource.marker('MAP32'),
          LumpSource.marker('NOTAMAP'),
          LumpSource.marker('MAPXX'),
          LumpSource.marker('E1MX'),
          LumpSource('THINGS', bytesOf(<int>[0])),
        ])),
      ]);
      expect(set.mapNames(), <String>['E1M1', 'MAP01', 'MAP32']);
    });

    test('lookups are case insensitive', () {
      final WadSet set = WadSet(<WadFile>[
        WadFile.parse(tinyWad(<LumpSource>[LumpSource('PLAYPAL', bytesOf(<int>[1]))])),
      ]);
      expect(set.read('playpal'), <int>[1]);
      expect(set.read('PlayPal'), <int>[1]);
    });
  });
}
