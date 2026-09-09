import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/synthetic_map.dart';

/// First end-to-end compile: does the whole pipeline produce a level?
void main() {
  test(
    'runtime copy preserves current geometry with independent update handles',
    () {
      final builder = MapBuilder('MAP01');
      final sector = builder.sector(floorHeight: 0, ceilingHeight: 128);
      builder.solidLoop([0, 0, 256, 0, 256, 256, 0, 256], sector);
      final template = DoomGeometryCompiler.compileWithTextures(
        builder.build(),
        _textures(),
      );
      template.setFloorHeight(sector, 7);
      template.updateWallsForSector(sector, 7, 128, [7], [128]);
      final copy = template.copyForRuntime();
      expect(copy.atlas, same(template.atlas));
      expect(copy.floorPlanes.first.height, 7);
      expect(copy.floorPlanes.first.baseHeight, 0);
      expect(copy.wallBands.first.bottom, 7);
      expect(copy.wallBands.first.baseBottom, 0);
      for (var i = 0; i < template.meshes.length; i++) {
        expect(
          copy.meshes[i].vertices,
          orderedEquals(template.meshes[i].vertices),
        );
        expect(
          copy.meshes[i].vertices,
          isNot(same(template.meshes[i].vertices)),
        );
        expect(() => copy.meshes[i].indices[0] = 0, throwsUnsupportedError);
      }
      copy.setFloorHeight(sector, 0);
      copy.updateWallsForSector(sector, 0, 128, [0], [128]);
      expect(template.floorPlanes.first.height, 7);
      expect(template.wallBands.first.bottom, 7);
      expect(copy.floorPlanes.first.height, 0);
      expect(copy.wallBands.first.bottom, 0);
    },
  );

  test('compiles a simple room end to end', () {
    final MapBuilder b = MapBuilder('E1M0');
    final int s = b.sector(floorHeight: 0, ceilingHeight: 128);
    b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s);
    final MapData map = b.build();

    final CompiledLevel level = DoomGeometryCompiler.compileWithTextures(
      map,
      _textures(),
    );

    print(level.report.summary());
    expect(level.meshes, isNotEmpty);
    expect(level.floorPlanes.length, 1);
    expect(level.ceilingPlanes.length, 1);
    expect(level.wallBands.length, 4);
    expect(level.report.fallbackSectors, isEmpty);
    expect(level.report.totalAreaDelta, lessThan(1.0));
  });
}

MapTextureSource _textures() {
  final Uint8List flatPixels = Uint8List(kFlatBytes)
    ..fillRange(0, kFlatBytes, 7);
  return MapTextureSource(
    flats: <String, FlatImage>{
      'FLOOR0_1': FlatImage(name: 'FLOOR0_1', indices: flatPixels),
      'CEIL1_1': FlatImage(name: 'CEIL1_1', indices: flatPixels),
    },
    composites: <String, PatchImage>{
      'STARTAN3': PatchImage(
        width: 64,
        height: 128,
        leftOffset: 0,
        topOffset: 0,
        indices: Uint8List(64 * 128),
        coverage: Uint8List(64 * 128)..fillRange(0, 64 * 128, 255),
      ),
    },
  );
}
