import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/synthetic_map.dart';

/// Synthetic stand-ins for real-IWAD edge cases. No commercial bytes are used.
void main() {
  test(
    'two-sided omitted textures create no quads or missing-resource noise',
    () {
      final MapBuilder builder = MapBuilder('NOTEXTURE');
      final int low = builder.sector(floorHeight: 0, ceilingHeight: 128);
      final int high = builder.sector(floorHeight: 32, ceilingHeight: 96);
      builder.twoSidedLoop(
        <int>[0, 0, 128, 0, 128, 128, 0, 128],
        low,
        high,
        upper: '-',
        lower: '-',
        middle: '-',
      );

      final WallSet walls = WallBuilder(
        builder.build(buildNodes: false),
        MapTextureSource(),
        GeometryOptions.defaults,
      ).build();

      expect(walls.quads, isEmpty);
      expect(walls.missingTextures, isEmpty);
    },
  );

  test(
    'positive odd-size wall texture survives wall sizing and atlas packing',
    () {
      const String texture = 'AASHITTY';
      final PatchImage image = PatchImage(
        width: 13,
        height: 7,
        leftOffset: 0,
        topOffset: 0,
        indices: Uint8List(13 * 7)..fillRange(0, 13 * 7, 47),
        coverage: Uint8List(13 * 7)..fillRange(0, 13 * 7, 255),
      );
      final MapTextureSource textures = MapTextureSource(
        composites: <String, PatchImage>{texture: image},
      );
      final MapBuilder builder = MapBuilder('ODDTEX');
      final int sector = builder.sector();
      builder.solidLoop(
        <int>[0, 0, 64, 0, 64, 64, 0, 64],
        sector,
        middle: texture,
      );

      final WallSet walls = WallBuilder(
        builder.build(buildNodes: false),
        textures,
        GeometryOptions.defaults,
      ).build();
      final IndexedAtlas atlas = (AtlasBuilder(
        textures,
        GeometryOptions.defaults,
      )..addWallTexture(texture)).build();

      expect(walls.quads, isNotEmpty);
      expect(walls.quads.first.textureWidth, 13);
      expect(walls.quads.first.textureHeight, 7);
      expect(atlas.overflowed, isEmpty);
      expect(
        (atlas.entry(texture)!.width, atlas.entry(texture)!.height),
        (13, 7),
      );
    },
  );
}
