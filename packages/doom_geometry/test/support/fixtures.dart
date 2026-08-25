import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';

/// Synthetic textures for tests: no commercial bytes, just recognisable sizes.
///
/// Sizes matter more than pixels here. Texture alignment is driven by the
/// declared width and height, so the fixtures use the classic Doom dimensions
/// (64x128 walls, 128x128 large walls, 64x64 flats) to make the pegging
/// expectations in the tests read the same way they would against real data.
MapTextureSource testTextures() {
  return MapTextureSource(
    flats: <String, FlatImage>{
      'FLOOR0_1': _flat('FLOOR0_1', 7),
      'FLOOR4_8': _flat('FLOOR4_8', 11),
      'CEIL1_1': _flat('CEIL1_1', 23),
      'CEIL3_5': _flat('CEIL3_5', 31),
      'NUKAGE1': _flat('NUKAGE1', 47),
    },
    composites: <String, PatchImage>{
      'STARTAN3': _patch(64, 128, 3),
      'BROWN1': _patch(64, 128, 5),
      'DOORTRAK': _patch(8, 128, 9),
      'BIGDOOR2': _patch(128, 128, 13),
      'MIDGRATE': _patch(64, 128, 17, masked: true),
      'STEP1': _patch(32, 16, 19),
    },
    sprites: <String, PatchImage>{
      'TROOA1': _patch(41, 56, 21, masked: true, leftOffset: 20, topOffset: 54),
      'MEDIA0': _patch(28, 19, 25, masked: true, leftOffset: 14, topOffset: 18),
    },
  );
}

FlatImage _flat(String name, int fill) => FlatImage(
      name: name,
      indices: Uint8List(kFlatBytes)..fillRange(0, kFlatBytes, fill),
    );

PatchImage _patch(
  int width,
  int height,
  int fill, {
  bool masked = false,
  int leftOffset = 0,
  int topOffset = 0,
}) {
  final int count = width * height;
  final Uint8List indices = Uint8List(count)..fillRange(0, count, fill);
  final Uint8List coverage = Uint8List(count)..fillRange(0, count, 255);
  if (masked) {
    // Punch a transparent column so masked handling has something to see.
    for (var y = 0; y < height; y++) {
      coverage[y * width] = 0;
    }
  }
  return PatchImage(
    width: width,
    height: height,
    leftOffset: leftOffset,
    topOffset: topOffset,
    indices: indices,
    coverage: coverage,
  );
}

/// Total covered area of a sector as the loop oracle sees it.
double oracleArea(SectorLoopResult result) => result.area;

/// Sums the area of every BSP region belonging to [sector].
double bspAreaOfSector(BspRegionSet regions, int sector) {
  var total = 0.0;
  for (final BspRegion region in regions.regions) {
    if (region.sector == sector) {
      total += region.area;
    }
  }
  return total;
}

