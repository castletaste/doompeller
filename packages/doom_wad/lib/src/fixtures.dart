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
  static const List<String> patchNames = <String>[
    'PAT1',
    'PAT2',
    'PAT3',
    'PAT4',
    'SKYPAN',
    'ANIMPA',
    'ANIMPB',
    'ANIMPC',
    'SWITCHA',
    'SWITCHB',
  ];

  /// Flat lumps inside F_START/F_END.
  static const List<String> flatNames = <String>[
    'FLOOR0',
    'CEIL0',
    'FLAT1',
    'NUKAGE1',
    'NUKAGE2',
    'NUKAGE3',
    kSkyFlatName,
  ];

  /// Sprite lumps inside S_START/S_END.
  static const List<String> spriteNames = <String>[
    'TESTA0',
    'TESTB0',
    'POSSA0',
    'POSSB0',
    'POSSC0',
    'POSSD0',
    'POSSE0',
    'POSSF0',
    'POSSG0',
    'POSSH0',
    'POSSI0',
    'POSSJ0',
    'POSSK0',
    'POSSL0',
    'POSSM0',
    'POSSN0',
    'POSSO0',
    'POSSP0',
    'POSSQ0',
    'POSSR0',
    'POSSS0',
    'POSST0',
    'POSSU0',
    'SPOSA0',
    'SPOSB0',
    'SPOSC0',
    'SPOSD0',
    'SPOSE0',
    'SPOSF0',
    'SPOSG0',
    'SPOSH0',
    'SPOSI0',
    'SPOSJ0',
    'SPOSK0',
    'SPOSL0',
    'SPOSM0',
    'SPOSN0',
    'SPOSO0',
    'SPOSP0',
    'SPOSQ0',
    'SPOSR0',
    'SPOSS0',
    'SPOST0',
    'SPOSU0',
    'TROOA0',
    'TROOB0',
    'TROOC0',
    'TROOD0',
    'TROOE0',
    'TROOF0',
    'TROOG0',
    'TROOH0',
    'TROOI0',
    'TROOJ0',
    'TROOK0',
    'TROOL0',
    'TROOM0',
    'TROON0',
    'TROOO0',
    'TROOP0',
    'TROOQ0',
    'TROOR0',
    'TROOS0',
    'TROOT0',
    'TROOU0',
    'BAR1A0',
    'BAR1B0',
    'BEXPA0',
    'BEXPB0',
    'BEXPC0',
    'BEXPD0',
    'BEXPE0',
    'BAL1A0',
    'BAL1B0',
    'BAL1C0',
    'BAL1D0',
    'BAL1E0',
    'PUFFA0',
    'PUFFB0',
    'PUFFC0',
    'PUFFD0',
    'BLUDA0',
    'BLUDB0',
    'BLUDC0',
    'CLIPA0',
    'SHOTA0',
    'STIMA0',
    'ARM1A0',
    'BON1A0',
    'BON2A0',
    'SHELA0',
    'PUNGA0',
    'PUNGB0',
    'PUNGC0',
    'PUNGD0',
    'PISGA0',
    'PISGB0',
    'PISGC0',
    'PISFA0',
    'SHTGA0',
    'SHTGB0',
    'SHTGC0',
    'SHTGD0',
    'SHTFA0',
    'SHTFB0',
    'CHGGA0',
    'CHGGB0',
    'CHGFA0',
    'CHGFB0',
  ];

  /// Generated DMX sounds used by the core's event vocabulary. The fixture
  /// contains no captured or derived commercial audio.
  static const List<String> soundNames = <String>[
    'DSPISTOL',
    'DSSHOTGN',
    'DSPUNCH',
    'DSWPNUP',
    'DSDOROPN',
    'DSDORCLS',
    'DSPSTART',
    'DSPSTOP',
    'DSPLPAIN',
    'DSPODTH1',
    'DSITEMUP',
    'DSSWTCHN',
    'DSSWTCHX',
  ];

  /// Texture names declared in TEXTURE1, in declaration order.
  static const List<String> texture1Names = <String>[
    'WALL1',
    'WALL2',
    'WALL3',
    'SKY1',
    'BLODGR1',
    'BLODGR2',
    'BLODGR3',
    'BLODGR4',
    'SW1COMP',
    'SW2COMP',
  ];

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
      for (final String name in flatNames)
        LumpSource(name, buildFixtureFlat(name)),
      LumpSource.marker('F_END'),
      LumpSource.marker('S_START'),
      for (final String name in spriteNames)
        LumpSource(name, encodeDoomPatch(buildFixtureSprite(name))),
      LumpSource.marker('S_END'),
      for (final String name in soundNames)
        LumpSource(name, buildFixtureSound(name)),
      LumpSource(
        'D_TEST',
        Uint8List.fromList(<int>[0x4d, 0x55, 0x53, 0x1a, 0, 0]),
      ),
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
  /// are all represented. SKY1 is a generated 256x128 panorama with explicit
  /// 16-pixel hue bands and columns, making yaw and seam errors easy to see.
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
    const _FixtureTexture('SKY1', 256, 128, <List<int>>[
      <int>[0, 0, 4],
    ]),
    const _FixtureTexture('BLODGR1', 64, 128, <List<int>>[
      <int>[0, 0, 5],
    ]),
    const _FixtureTexture('BLODGR2', 64, 128, <List<int>>[
      <int>[0, 0, 6],
    ]),
    const _FixtureTexture('BLODGR3', 64, 128, <List<int>>[
      <int>[0, 0, 7],
    ]),
    const _FixtureTexture('BLODGR4', 64, 128, <List<int>>[
      <int>[0, 0, 5],
      <int>[32, 0, 7],
    ]),
    const _FixtureTexture('SW1COMP', 64, 128, <List<int>>[
      <int>[0, 0, 8],
    ]),
    const _FixtureTexture('SW2COMP', 64, 128, <List<int>>[
      <int>[0, 0, 9],
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

/// Builds a deterministic synthetic DMX sound with conventional edge guards.
///
/// A stable FNV hash selects pitch from [name]. All sample
/// bytes are generated here; no IWAD audio is read or transformed.
Uint8List buildFixtureSound(String name, {int sampleRate = 11025}) {
  const int playableSamples = 384;
  const int guard = kDmxGuardSamples;
  final int seed = fnv1a64(Uint8List.fromList(name.codeUnits));
  final int period = 12 + (seed & 31);
  final Uint8List playable = Uint8List(playableSamples);
  for (var i = 0; i < playable.length; i++) {
    final int phase = i % period;
    final int wave = phase < period ~/ 2 ? 1 : -1;
    final int envelope = 96 * (playable.length - i) ~/ playable.length;
    playable[i] = 128 + wave * envelope;
  }
  final int stored = playable.length + guard * 2;
  final Uint8List out = Uint8List(kDmxSoundHeaderBytes + stored);
  final ByteData data = ByteData.sublistView(out);
  data.setUint16(0, kDmxDigitalSoundType, Endian.little);
  data.setUint16(2, sampleRate, Endian.little);
  data.setUint32(4, stored, Endian.little);
  out.fillRange(
    kDmxSoundHeaderBytes,
    kDmxSoundHeaderBytes + guard,
    playable.first,
  );
  out.setRange(
    kDmxSoundHeaderBytes + guard,
    kDmxSoundHeaderBytes + guard + playable.length,
    playable,
  );
  out.fillRange(
    kDmxSoundHeaderBytes + guard + playable.length,
    out.length,
    playable.last,
  );
  return out;
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

int _blend(int from, int to, int strength) =>
    from + ((to - from) * strength) ~/ 255;

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
/// grate with transparent gaps and irregular column starts, PAT4 is a small
/// tile used to test compositing that overhangs the texture canvas, and SKYPAN
/// is a generated opaque panorama with visibly distinct bands and columns.
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
    case 'SKYPAN':
      return _generatePatch(256, 128, 0, 0, (int x, int y) {
        // Each 16x16 tile changes both hue and brightness. The repeated
        // tile boundaries make horizontal bands, vertical columns and the
        // panorama seam visible without using any external artwork.
        final int band = y >> 4;
        final int column = x >> 4;
        final int hue = (column * 2 + band * 3) & 15;
        final int level = ((y & 15) + ((x & 15) >> 2) + band) & 15;
        return hue * 16 + level;
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

const Set<String> _fixturePickupPrefixes = <String>{
  'CLIP',
  'SHOT',
  'STIM',
  'ARM1',
  'BON1',
  'BON2',
  'SHEL',
};

const Set<String> _fixtureWeaponPrefixes = <String>{
  'PISG',
  'PUNG',
  'SHTG',
  'CHGG',
};

/// Builds a deterministic, legally clean sprite from [name].
///
/// The stable FNV hash controls palette, silhouette and cutouts, so enemies,
/// pickups, projectiles and weapon frames are visibly different without any
/// source artwork. World sprites keep their feet-oriented hotspot, pickups use
/// a smaller ground icon, and first-person weapons are bottom anchored.
PatchImage buildFixtureSprite(String name) {
  final String upper = name.toUpperCase();
  final int hash = _stableSpriteHash(upper);
  final String prefix = upper.length >= 4 ? upper.substring(0, 4) : upper;
  final bool isPickup = _fixturePickupPrefixes.contains(prefix);
  final bool isWeapon = _fixtureWeaponPrefixes.contains(prefix);
  final int width = isWeapon ? 96 : (isPickup ? 40 : 64);
  final int height = isWeapon ? 64 : (isPickup ? 40 : 64);
  final int leftOffset = width ~/ 2;
  final int topOffset = isWeapon
      ? height
      : (isPickup ? height - 4 : height - 4);
  final int cx = width ~/ 2;
  final int cy = isWeapon ? height - 22 : height ~/ 2;
  final int radius = isWeapon ? 34 : (isPickup ? 16 : 27);
  final int shape = hash & 3;
  final int hue = (hash >> 8) & 15;

  return _generatePatch(width, height, leftOffset, topOffset, (int x, int y) {
    final int dx = x - cx;
    final int dy = y - cy;
    final int ax = dx.abs();
    final int ay = dy.abs();
    final bool inside;
    if (isWeapon) {
      final int barrelHalfWidth = 7 + ((hash >> 4) & 7);
      final bool barrel = ay <= radius && ax <= barrelHalfWidth + (ay ~/ 5);
      final bool grip = y >= height - 24 && ax <= 6 + shape * 2;
      final bool sight = y >= 4 + shape * 2 && y <= 12 + shape * 2 && ax <= 3;
      inside = barrel || grip || sight;
    } else {
      inside = switch (shape) {
        0 => dx * dx + dy * dy <= radius * radius,
        1 => ax + ay <= radius + 5,
        2 => ay <= radius && ax <= radius - (ay ~/ 3),
        _ =>
          (ay <= radius && ax <= radius ~/ 2 + ((radius - ay) ~/ 2)) ||
              (ay < radius ~/ 3 && ax <= radius),
      };
    }
    if (!inside) {
      return -1;
    }

    // Name-derived holes create genuine cutouts instead of only a transparent
    // bounding box. Keep them small enough that every silhouette stays solid.
    final int holeX = 3 + ((hash >> 12) & 7);
    final int holeY = isWeapon ? cy - 10 : cy - 4 + ((hash >> 16) & 7);
    if ((x - (cx - holeX)).abs() <= 1 && (y - holeY).abs() <= 2) {
      return -1;
    }
    if ((hash & 0x20) != 0 &&
        (x - (cx + holeX)).abs() <= 1 &&
        (y - holeY).abs() <= 2) {
      return -1;
    }

    final int level = 1 + ((ax + ay + (hash >> 20)) & 7);
    return hue * 16 + level;
  });
}

int _stableSpriteHash(String name) {
  var hash = 0x811c9dc5;
  for (final int byte in name.codeUnits) {
    hash ^= byte & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
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
