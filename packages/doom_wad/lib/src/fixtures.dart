import 'dart:math' as math;
import 'dart:typed_data';

import 'fixture_map.dart';
import 'resources.dart';
import 'resources_model.dart';
import 'wad.dart';
import 'wad_builder.dart';

/// Builds a synthetic, legally clean PWAD entirely in memory.
///
/// Every byte is generated from the constants in this file, so the fixture
/// carries no commercial data and is reproducible: the same code always emits
/// the same bytes, which lets tests pin a hash and see regressions.
///
/// The MAP01 it contains is deliberately awkward: a convex room, a concave
/// L-shaped room, a room whose floor has a hole punched in it, two-sided lines
/// with mismatched floor and ceiling heights, and a sky ceiling. It ships with
/// a real NODES/SEGS/SSECTORS tree built by [buildBspTree], so BSP traversal,
/// subsector lookup and sector-from-subsector code can be exercised with no
/// commercial IWAD present.
abstract final class DoomFixtures {
  /// Map contained in the fixture.
  static const String mapName = 'MAP01';

  /// Cached bytes; generation is deterministic so one copy is enough.
  static Uint8List? _bytes;

  /// The fixture PWAD as raw bytes.
  static Uint8List pwadBytes() => _bytes ??= _build();

  /// The fixture parsed as a [WadFile].
  static WadFile wad() => WadFile.parse(pwadBytes());

  /// The fixture as a single-entry [WadSet], ready for resource and map loads.
  static WadSet wadSet() => WadSet(<WadFile>[wad()]);

  /// FNV-1a hash of [pwadBytes], for regression pinning.
  static int hash() => fnv1a64(pwadBytes());

  /// Patch lumps referenced by PNAMES, in index order.
  static const List<String> patchNames = <String>['PAT1', 'PAT2', 'PAT3', 'PAT4'];

  /// Flat lumps inside F_START/F_END.
  static const List<String> flatNames = <String>['FLOOR0', 'CEIL0', 'FLAT1', kSkyFlatName];

  /// Sprite lumps inside S_START/S_END.
  static const List<String> spriteNames = <String>['TESTA0', 'TESTB0'];

  /// Texture names declared in TEXTURE1, in declaration order.
  static const List<String> texture1Names = <String>['WALL1', 'WALL2', 'WALL3'];

  /// Texture names declared in TEXTURE2.
  static const List<String> texture2Names = <String>['WALLOVR'];

  static Uint8List _build() {
    final FixtureMapLumps map = buildFixtureMapLumps();
    final List<LumpSource> lumps = <LumpSource>[
      LumpSource('PLAYPAL', buildFixturePlaypal()),
      LumpSource('COLORMAP', buildFixtureColormap()),
      LumpSource('PNAMES', _pnamesLump()),
      LumpSource('TEXTURE1', _texture1Lump()),
      LumpSource('TEXTURE2', _texture2Lump()),
      LumpSource.marker(mapName),
      LumpSource('THINGS', map.things),
      LumpSource('LINEDEFS', map.linedefs),
      LumpSource('SIDEDEFS', map.sidedefs),
      LumpSource('VERTEXES', map.vertexes),
      LumpSource('SEGS', map.segs),
      LumpSource('SSECTORS', map.ssectors),
      LumpSource('NODES', map.nodes),
      LumpSource('SECTORS', map.sectors),
      LumpSource('REJECT', map.reject),
      LumpSource('BLOCKMAP', map.blockmap),
      LumpSource.marker('P_START'),
      for (final String name in patchNames)
        LumpSource(name, encodeDoomPatch(buildFixturePatch(name))),
      LumpSource.marker('P_END'),
      LumpSource.marker('F_START'),
      for (final String name in flatNames) LumpSource(name, buildFixtureFlat(name)),
      LumpSource.marker('F_END'),
      LumpSource.marker('S_START'),
      for (final String name in spriteNames)
        LumpSource(name, encodeDoomPatch(buildFixtureSprite(name))),
      LumpSource.marker('S_END'),
    ];
    return buildWad(lumps);
  }

  static Uint8List _pnamesLump() {
    final Uint8List out = Uint8List(4 + patchNames.length * kPatchNameBytes);
    ByteData.sublistView(out).setInt32(0, patchNames.length, Endian.little);
    for (var i = 0; i < patchNames.length; i++) {
      encodeLumpName(out, 4 + i * kPatchNameBytes, patchNames[i]);
    }
    return out;
  }

  /// WALL1 is a single patch, WALL2 tiles two patches side by side and WALL3
  /// uses the patch with transparent gaps, so compositing, seams and masking
  /// are all represented.
  static Uint8List _texture1Lump() => _buildTextureLump(<_FixtureTexture>[
        const _FixtureTexture('WALL1', 64, 128, <List<int>>[
          <int>[0, 0, 0],
        ]),
        const _FixtureTexture('WALL2', 128, 128, <List<int>>[
          <int>[0, 0, 0],
          <int>[64, 0, 1],
        ]),
        const _FixtureTexture('WALL3', 64, 128, <List<int>>[
          <int>[0, 0, 2],
        ]),
      ]);

  /// WALLOVR places patches past both edges of the canvas so the compositor's
  /// clipping is exercised.
  static Uint8List _texture2Lump() => _buildTextureLump(<_FixtureTexture>[
        const _FixtureTexture('WALLOVR', 96, 64, <List<int>>[
          <int>[-16, 0, 3],
          <int>[48, 0, 3],
        ]),
      ]);

  static Uint8List _buildTextureLump(List<_FixtureTexture> textures) {
    var size = 4 + textures.length * 4;
    for (final _FixtureTexture texture in textures) {
      size += kTextureHeaderBytes + texture.patches.length * kTexturePatchBytes;
    }
    final Uint8List out = Uint8List(size);
    final ByteData view = ByteData.sublistView(out);
    view.setInt32(0, textures.length, Endian.little);

    var cursor = 4 + textures.length * 4;
    for (var i = 0; i < textures.length; i++) {
      view.setInt32(4 + i * 4, cursor, Endian.little);
      final _FixtureTexture texture = textures[i];
      encodeLumpName(out, cursor, texture.name);
      // Bytes 8..11 are the unused "masked" field vanilla never reads.
      view.setInt16(cursor + 12, texture.width, Endian.little);
      view.setInt16(cursor + 14, texture.height, Endian.little);
      view.setInt16(cursor + 20, texture.patches.length, Endian.little);
      var record = cursor + kTextureHeaderBytes;
      for (final List<int> patch in texture.patches) {
        view.setInt16(record, patch[0], Endian.little);
        view.setInt16(record + 2, patch[1], Endian.little);
        view.setInt16(record + 4, patch[2], Endian.little);
        record += kTexturePatchBytes;
      }
      cursor = record;
    }
    return out;
  }
}

class _FixtureTexture {
  const _FixtureTexture(this.name, this.width, this.height, this.patches);

  final String name;
  final int width;
  final int height;

  /// Each entry is originX, originY, pnamesIndex.
  final List<List<int>> patches;
}

/// Builds the 14 palette PLAYPAL used by the fixture.
///
/// The base palette is a 16 hue by 16 brightness grid, so palette index
/// hue * 16 + level holds one shade, with level 0 brightest. That structure
/// lets [buildFixtureColormap] produce a light ramp by simple index arithmetic
/// instead of a nearest-colour search, and keeps it reproducible from code.
Uint8List buildFixturePlaypal() {
  final Uint8List out = Uint8List(kPalettesPerPlaypal * kPaletteBytes);
  final Uint8List base = Uint8List(kPaletteBytes);
  for (var hue = 0; hue < 16; hue++) {
    final int r0;
    final int g0;
    final int b0;
    if (hue == 15) {
      r0 = 255;
      g0 = 255;
      b0 = 255;
    } else {
      final List<int> rgb = _hueToRgb(hue * 24);
      r0 = rgb[0];
      g0 = rgb[1];
      b0 = rgb[2];
    }
    for (var level = 0; level < 16; level++) {
      final int scale = 15 - level;
      final int o = (hue * 16 + level) * 3;
      base[o] = (r0 * scale) ~/ 15;
      base[o + 1] = (g0 * scale) ~/ 15;
      base[o + 2] = (b0 * scale) ~/ 15;
    }
  }
  out.setRange(0, kPaletteBytes, base);

  // 1..8 red damage flash, 9..12 item pickup gold, 13 radiation suit green.
  for (var p = 1; p < kPalettesPerPlaypal; p++) {
    final int tintR;
    final int tintG;
    final int tintB;
    final int strength;
    if (p <= 8) {
      tintR = 255;
      tintG = 0;
      tintB = 0;
      strength = p * 26;
    } else if (p <= 12) {
      tintR = 215;
      tintG = 186;
      tintB = 69;
      strength = (p - 8) * 24;
    } else {
      tintR = 3;
      tintG = 253;
      tintB = 3;
      strength = 32;
    }
    final int o = p * kPaletteBytes;
    for (var i = 0; i < kPaletteColors; i++) {
      final int s = i * 3;
      out[o + s] = _blend(base[s], tintR, strength);
      out[o + s + 1] = _blend(base[s + 1], tintG, strength);
      out[o + s + 2] = _blend(base[s + 2], tintB, strength);
    }
  }
  return out;
}

int _blend(int from, int to, int strength) => from + ((to - from) * strength) ~/ 255;

/// Full-saturation, full-value hue wheel; [degrees] is 0..359.
List<int> _hueToRgb(int degrees) {
  final int sector = degrees ~/ 60;
  final int within = ((degrees % 60) * 255) ~/ 60;
  switch (sector) {
    case 0:
      return <int>[255, within, 0];
    case 1:
      return <int>[255 - within, 255, 0];
    case 2:
      return <int>[0, 255, within];
    case 3:
      return <int>[0, 255 - within, 255];
    case 4:
      return <int>[within, 0, 255];
    default:
      return <int>[255, 0, 255 - within];
  }
}

/// Builds the 34 map COLORMAP matching [buildFixturePlaypal].
///
/// Maps 0..31 darken by walking down the palette's brightness axis, 32 is the
/// invulnerability inversion and 33 is solid black.
Uint8List buildFixtureColormap() {
  final Uint8List out = Uint8List(kColormapCount * kColormapBytes);
  for (var map = 0; map < 32; map++) {
    final int o = map * kColormapBytes;
    for (var i = 0; i < kPaletteColors; i++) {
      final int hue = i >> 4;
      final int level = i & 15;
      final int darker = math.min(15, level + (map >> 1));
      out[o + i] = hue * 16 + darker;
    }
  }
  final int inverted = 32 * kColormapBytes;
  for (var i = 0; i < kPaletteColors; i++) {
    out[inverted + i] = (i >> 4) * 16 + (15 - (i & 15));
  }
  final int black = 33 * kColormapBytes;
  for (var i = 0; i < kPaletteColors; i++) {
    out[black + i] = 255;
  }
  return out;
}

/// Builds the named fixture patch.
///
/// PAT1 and PAT2 are opaque wall patches with different patterns, PAT3 is a
/// grate with transparent gaps and irregular column starts, and PAT4 is a small
/// tile used to test compositing that overhangs the texture canvas.
PatchImage buildFixturePatch(String name) {
  switch (name) {
    case 'PAT1':
      return _generatePatch(64, 128, 32, 120, (int x, int y) {
        // Brick courses: mortar lines every 16 rows, staggered per course.
        final int course = y >> 4;
        final int stagger = (course & 1) * 16;
        final bool mortar = (y & 15) == 0 || ((x + stagger) & 31) == 0;
        return mortar ? 0x1F : 0x10 + ((course * 3 + x ~/ 8) & 7);
      });
    case 'PAT2':
      return _generatePatch(64, 128, 32, 120, (int x, int y) {
        // Vertical panelling with a highlight down each seam.
        final bool seam = (x & 15) == 0;
        return seam ? 0x2F : 0x20 + ((y >> 3) & 7);
      });
    case 'PAT3':
      return _generatePatch(64, 128, 32, 120, (int x, int y) {
        // Grate: transparent where both axes fall inside a hole.
        final bool hole = (x % 16) > 3 && (y % 16) > 3;
        return hole ? -1 : 0x30 + ((x + y) & 7);
      });
    default:
      return _generatePatch(64, 64, 32, 32, (int x, int y) {
        // Checkerboard with a transparent border, so clipping shows up.
        if (x < 2 || y < 2 || x > 61 || y > 61) {
          return -1;
        }
        return 0x40 + (((x >> 3) + (y >> 3)) & 7);
      });
  }
}

/// Builds the named fixture sprite. Sprites are patches with a hotspot offset
/// and large transparent margins, which is what real sprite lumps look like.
PatchImage buildFixtureSprite(String name) {
  final bool second = name == 'TESTB0';
  final int radius = second ? 20 : 28;
  return _generatePatch(64, 64, 32, 60, (int x, int y) {
    final int dx = x - 32;
    final int dy = y - 32;
    final int distance = dx * dx + dy * dy;
    if (distance > radius * radius) {
      return -1;
    }
    return (second ? 0x50 : 0x60) + ((distance >> 6) & 7);
  });
}

/// Runs [shade] over every pixel; a negative return means transparent.
PatchImage _generatePatch(
  int width,
  int height,
  int leftOffset,
  int topOffset,
  int Function(int x, int y) shade,
) {
  final Uint8List indices = Uint8List(width * height);
  final Uint8List coverage = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    final int row = y * width;
    for (var x = 0; x < width; x++) {
      final int value = shade(x, y);
      if (value >= 0) {
        indices[row + x] = value & 0xFF;
        coverage[row + x] = 255;
      }
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

/// Builds a 64x64 fixture flat.
Uint8List buildFixtureFlat(String name) {
  final Uint8List out = Uint8List(kFlatBytes);
  switch (name) {
    case 'FLOOR0':
      for (var y = 0; y < kFlatSize; y++) {
        for (var x = 0; x < kFlatSize; x++) {
          out[y * kFlatSize + x] = 0x70 + (((x >> 3) ^ (y >> 3)) & 7);
        }
      }
    case 'CEIL0':
      for (var y = 0; y < kFlatSize; y++) {
        for (var x = 0; x < kFlatSize; x++) {
          out[y * kFlatSize + x] = 0x80 + (((x * y) >> 5) & 7);
        }
      }
    case 'FLAT1':
      for (var y = 0; y < kFlatSize; y++) {
        for (var x = 0; x < kFlatSize; x++) {
          out[y * kFlatSize + x] = 0x90 + (((x + y) >> 3) & 7);
        }
      }
    default:
      // Sky flat: a vertical gradient, never actually sampled by the renderer.
      for (var y = 0; y < kFlatSize; y++) {
        for (var x = 0; x < kFlatSize; x++) {
          out[y * kFlatSize + x] = 0xA0 + ((y >> 3) & 7);
        }
      }
  }
  return out;
}
