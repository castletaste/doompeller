import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/adapter/renderer_smoke_game.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('developer IWAD renderer smoke content', () {
    test(
      'uses DoomContentSource and accepts a parameterized fixture map',
      () async {
        final bytes = Uint8List.fromList(DoomFixtures.pwadBytes())
          ..setRange(0, 4, 'IWAD'.codeUnits);
        final source = DoomContentSource(
          environment: const <String, String>{
            kDoomWadPathEnvironment: '/private/tmp/generated-fixture.iwad',
          },
          readLength: (_) async => bytes.lengthInBytes,
          readBytes: (_) async => bytes,
        );

        final content = await resolveRendererSmokeContent(
          const RendererSmokeConfig(
            map: RendererSmokeMap.developerIwad,
            mapName: 'map01',
          ),
          contentSource: source,
        );

        expect(content.origin, DoomContentOrigin.developerIwad);
        expect(content.mapName, DoomFixtures.mapName);
        expect(content.wads.mapNames(), contains(DoomFixtures.mapName));
      },
    );

    test('fails explicitly when DOOM_WAD_PATH is absent', () async {
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

      await expectLater(
        resolveRendererSmokeContent(
          const RendererSmokeConfig(map: RendererSmokeMap.developerIwad),
          contentSource: source,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains(kDoomWadPathEnvironment),
          ),
        ),
      );
      expect(read, isFalse);
    });
  });
}
