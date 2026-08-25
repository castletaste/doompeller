import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:doompeller/adapter/adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_gpu_backend.dart';

/// A COLORMAP where row r darkens every index by r, clamping at 0.
///
/// Real Doom rows are arbitrary lookups, but a linear ramp makes the two-stage
/// walk verifiable by hand.
Uint8List buildColorMaps(int rows) {
  final maps = Uint8List(rows * 256);
  for (var row = 0; row < rows; row++) {
    for (var index = 0; index < 256; index++) {
      final darkened = index - row;
      maps[row * 256 + index] = darkened < 0 ? 0 : darkened;
    }
  }
  return maps;
}

/// A PLAYPAL where row 0 is a grey ramp and each later row tints one channel,
/// so a wrong row is immediately visible as a wrong channel.
Uint8List buildPalettes(int rows) {
  final palettes = Uint8List(rows * 256 * 3);
  for (var row = 0; row < rows; row++) {
    for (var index = 0; index < 256; index++) {
      final offset = (row * 256 + index) * 3;
      palettes[offset] = index;
      palettes[offset + 1] = row == 0 ? index : 0;
      palettes[offset + 2] = row == 0 ? index : row;
    }
  }
  return palettes;
}

void main() {
  PaletteTextureData encode({
    int width = 4,
    int height = 2,
    Uint8List? indices,
    Uint8List? coverage,
    int colorMapRows = 34,
    int paletteRows = DoomPaletteVariant.count,
  }) => PaletteTextureData.encode(
    atlasWidth: width,
    atlasHeight: height,
    atlasIndices:
        indices ??
        Uint8List.fromList(List.generate(width * height, (i) => i * 7 % 256)),
    atlasCoverage: coverage,
    colorMaps: buildColorMaps(colorMapRows),
    palettes: buildPalettes(paletteRows),
  );

  group('atlas encoding', () {
    test('packs the palette index in red and coverage in alpha', () {
      final data = encode(
        width: 2,
        height: 1,
        indices: Uint8List.fromList(const [17, 200]),
        coverage: Uint8List.fromList(const [0, 255]),
      );

      expect(data.atlasRgba, hasLength(2 * 4));
      expect(data.atlasIndexAt(0, 0), 17);
      expect(data.atlasCoverageAt(0, 0), 0, reason: 'a cut-out pixel');
      expect(data.atlasIndexAt(1, 0), 200);
      expect(data.atlasCoverageAt(1, 0), 255);
    });

    test('defaults coverage to fully opaque', () {
      final data = encode(width: 1, height: 1, indices: Uint8List.fromList(const [5]));
      expect(data.atlasCoverageAt(0, 0), 255);
    });

    test('rejects mismatched plane sizes', () {
      expect(
        () => PaletteTextureData.encode(
          atlasWidth: 4,
          atlasHeight: 4,
          atlasIndices: Uint8List(8),
          colorMaps: buildColorMaps(1),
          palettes: buildPalettes(1),
        ),
        throwsArgumentError,
      );
      expect(
        () => PaletteTextureData.encode(
          atlasWidth: 2,
          atlasHeight: 2,
          atlasIndices: Uint8List(4),
          atlasCoverage: Uint8List(3),
          colorMaps: buildColorMaps(1),
          palettes: buildPalettes(1),
        ),
        throwsArgumentError,
      );
      expect(
        () => PaletteTextureData.encode(
          atlasWidth: 2,
          atlasHeight: 2,
          atlasIndices: Uint8List(4),
          colorMaps: Uint8List(100),
          palettes: buildPalettes(1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('two-stage lookup', () {
    test('applies COLORMAP before PLAYPAL', () {
      final data = encode();

      // Row 0 is the undarkened map, so the index passes through.
      expect(data.lookup(100, lightRow: 0), const Color.fromARGB(255, 100, 100, 100));

      // Row 8 darkens by 8 first, then the palette is read at the new index.
      expect(data.lookup(100, lightRow: 8), const Color.fromARGB(255, 92, 92, 92));
    });

    test('palette rows select a variant without touching RGB math', () {
      final data = encode();
      final damage = data.lookup(
        100,
        paletteRow: DoomPaletteVariant.damageFirst,
      );

      // Red carries the index verbatim; the tint comes from the palette row
      // itself, never from scaling the looked-up color.
      expect(damage.r * 255, closeTo(100, 0.5));
      expect(damage.g * 255, closeTo(0, 0.5));
      expect(damage.b * 255, closeTo(DoomPaletteVariant.damageFirst, 0.5));
    });

    test('rejects out-of-range rows', () {
      final data = encode(colorMapRows: 34, paletteRows: 14);
      expect(() => data.lookup(-1), throwsRangeError);
      expect(() => data.lookup(256), throwsRangeError);
      expect(() => data.lookup(0, lightRow: 34), throwsRangeError);
      expect(() => data.lookup(0, paletteRow: 14), throwsRangeError);
    });
  });

  group('light rows', () {
    test('stops distance shading before the invulnerability map', () {
      final data = encode(colorMapRows: 34);
      expect(
        data.maxLightRow,
        31,
        reason: 'rows 32+ are special maps, not light levels',
      );
      expect(data.invulnerabilityRow, 32);
    });

    test('handles a truncated COLORMAP', () {
      final data = encode(colorMapRows: 8);
      expect(data.maxLightRow, 7);
      expect(data.invulnerabilityRow, -1);
    });
  });

  group('palette variants', () {
    test('map damage and pickup amounts onto their row ranges', () {
      expect(DoomPaletteVariant.damage(0), DoomPaletteVariant.normal);
      expect(DoomPaletteVariant.damage(0.01), DoomPaletteVariant.damageFirst);
      expect(DoomPaletteVariant.damage(1), DoomPaletteVariant.damageLast);
      expect(DoomPaletteVariant.damage(double.nan), DoomPaletteVariant.normal);

      expect(DoomPaletteVariant.itemPickup(0), DoomPaletteVariant.normal);
      expect(
        DoomPaletteVariant.itemPickup(0.01),
        DoomPaletteVariant.itemPickupFirst,
      );
      expect(
        DoomPaletteVariant.itemPickup(1),
        DoomPaletteVariant.itemPickupLast,
      );
    });

    test('a full Doom PLAYPAL has 14 rows', () {
      expect(encode().paletteRows, DoomPaletteVariant.count);
      expect(DoomPaletteVariant.radiationSuit, DoomPaletteVariant.count - 1);
    });
  });

  group('GPU textures', () {
    test('uploads three RGBA8 lookups of the right shape', () {
      final backend = FakeGpuBackend();
      final diagnostics = RenderDiagnostics();
      final data = encode(width: 8, height: 4);
      final textures = PaletteTextures(data, diagnostics: diagnostics);

      // flame_3d creates resources lazily.
      textures.indexAtlas.resource;
      textures.colorMapLut.resource;
      textures.paletteLut.resource;

      expect(backend.textures, hasLength(3));
      expect(diagnostics.texturesCreated, 3);
      expect(
        backend.textures.every((t) => t.format.name == 'rgba8888'),
        isTrue,
        reason: 'flame_3d 0.3.0 has no R8 format',
      );
      expect((backend.textures[0].width, backend.textures[0].height), (8, 4));
      expect((backend.textures[1].width, backend.textures[1].height), (256, 34));
      expect((backend.textures[2].width, backend.textures[2].height), (256, 14));
    });
  });
}
