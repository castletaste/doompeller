import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/synthetic_map.dart';

/// First end-to-end compile: does the whole pipeline produce a level?
void main() {
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
  final Uint8List flatPixels = Uint8List(kFlatBytes)..fillRange(0, kFlatBytes, 7);
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
