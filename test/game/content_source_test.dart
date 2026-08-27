import 'dart:typed_data';

import 'package:doompeller/game/content_source.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DoomContentSource', () {
    test(
      'does not scan a default location when DOOM_WAD_PATH is absent',
      () async {
        var read = false;
        final source = DoomContentSource(
          environment: const <String, String>{},
          readLength: (_) async {
            read = true;
            return 0;
          },
          readBytes: (_) async {
            read = true;
            return Uint8List(0);
          },
        );

        final result = await source.loadDeveloperIwad();

        expect(result, isA<DoomContentPathMissing>());
        expect(read, isFalse);
      },
    );

    test('fixture is generated in memory and selects MAP01', () {
      final content = DoomContentSource(
        environment: const <String, String>{},
      ).loadFixture();

      expect(content.origin, DoomContentOrigin.syntheticFixture);
      expect(content.sourcePath, isNull);
      expect(content.mapName, DoomFixtures.mapName);
      expect(content.wads.mapNames(), contains(DoomFixtures.mapName));
    });

    test('rejects a PWAD selected as the standalone developer IWAD', () async {
      final bytes = DoomFixtures.pwadBytes();
      final source = DoomContentSource(
        environment: const <String, String>{
          kDoomWadPathEnvironment: '/private/tmp/fixture.wad',
        },
        readLength: (_) async => bytes.length,
        readBytes: (_) async => bytes,
      );

      final result = await source.loadDeveloperIwad();

      expect(result, isA<DoomContentLoadFailure>());
      expect((result as DoomContentLoadFailure).message, contains('PWAD'));
    });

    test('loads an explicitly selected in-memory IWAD without a file path', () {
      final Uint8List bytes = DoomFixtures.pwadBytes()
        ..setRange(0, 4, 'IWAD'.codeUnits);
      final result = DoomContentSource(
        environment: const <String, String>{},
      ).loadIwadBytes(bytes, mapName: DoomFixtures.mapName);

      expect(result, isA<DoomContentLoaded>());
      final content = (result as DoomContentLoaded).content;
      expect(content.origin, DoomContentOrigin.developerIwad);
      expect(content.sourcePath, isNull);
      expect(content.mapName, DoomFixtures.mapName);
    });

    test('checks maxWadBytes before reading file contents', () async {
      var readBytes = false;
      final source = DoomContentSource(
        environment: const <String, String>{
          kDoomWadPathEnvironment: '/private/tmp/too-large.wad',
        },
        limits: const DoomLimits(maxWadBytes: 4),
        readLength: (_) async => 5,
        readBytes: (_) async {
          readBytes = true;
          return Uint8List(5);
        },
      );

      final result = await source.loadDeveloperIwad();

      expect(result, isA<DoomContentLoadFailure>());
      expect((result as DoomContentLoadFailure).cause, isA<DoomLimitFailure>());
      expect(readBytes, isFalse);
    });
  });
}
