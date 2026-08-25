import 'dart:math' as math;

import 'package:doompeller/adapter/adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves camera-invariant A0', () {
    final catalog = DoomSpriteCatalog(const <String>['TESTA0']);
    for (var rotation = 0; rotation <= 8; rotation++) {
      final selected = catalog.resolve(
        prefix: 'TEST',
        frame: 0,
        rotation: rotation,
      );
      expect(selected?.lumpName, 'TESTA0');
      expect(selected?.mirrored, isFalse);
    }
  });

  test('resolves A1 through A8 and dual-pair mirrors', () {
    final catalog = DoomSpriteCatalog(const <String>[
      'TROOA1',
      'TROOA2A8',
      'TROOA3A7',
      'TROOA4A6',
      'TROOA5',
    ]);
    for (var rotation = 1; rotation <= 8; rotation++) {
      final selected = catalog.resolve(
        prefix: 'troo',
        frame: 0,
        rotation: rotation,
      )!;
      expect(selected.lumpName, startsWith('TROOA'));
      expect(selected.mirrored, rotation >= 6);
    }
  });

  test('frame index selects B independently from A', () {
    final catalog = DoomSpriteCatalog(const <String>['TROOA0', 'TROOB0']);
    expect(
      catalog.resolve(prefix: 'TROO', frame: 1, rotation: 4)?.lumpName,
      'TROOB0',
    );
  });

  test('camera bearings quantize to eight stable buckets', () {
    final rotations = <int>{
      for (var i = 0; i < 8; i++)
        DoomSpriteCatalog.cameraRotation(
          actorAngle: 0,
          actorX: 0,
          actorZ: 0,
          cameraX: math.sin(i * math.pi / 4) * 10,
          cameraZ: math.cos(i * math.pi / 4) * 10,
        ),
    };
    expect(rotations, <int>{1, 2, 3, 4, 5, 6, 7, 8});
  });
}
