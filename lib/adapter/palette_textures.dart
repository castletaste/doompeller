import 'dart:typed_data';
import 'dart:ui' show Color, PixelFormat;

import 'package:flame_3d/resources.dart';
import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;

import 'render_diagnostics.dart';

/// CPU-side encoding of the three lookup textures the palette shader reads.
///
/// Doom's art is 8-bit indexed: a texture stores palette indices, COLORMAP
/// remaps an index for a light level, and PLAYPAL turns the final index into
/// RGB. All three stay indexed all the way to the GPU, which is what preserves
/// the exact original colors.
///
/// ## Why everything is RGBA8
///
/// flame_3d 0.3.0 offers rgba8888, bgra8888 and rgbaFloat32 only. There is no
/// R8 format, so single-channel data is stored in RGBA8 and the shader reads
/// one channel. The atlas puts the palette index in red and mask coverage in
/// alpha, which costs 4x memory but needs no second texture binding and no
/// second sample.
///
/// This class takes plain typed data. It never imports doom_wad, so the
/// adapter stays independent of the pure-Dart packages while they are built.
final class PaletteTextureData {
  PaletteTextureData._({
    required this.atlasRgba,
    required this.atlasWidth,
    required this.atlasHeight,
    required this.colorMapRgba,
    required this.colorMapRows,
    required this.paletteRgba,
    required this.paletteRows,
  });

  /// Encodes an indexed atlas, a COLORMAP and a PLAYPAL.
  ///
  /// [atlasIndices] holds one palette index per pixel, row-major.
  /// [atlasCoverage] holds mask coverage per pixel: 0 for a cut-out pixel and
  /// 255 for a solid one. Omit it for fully opaque pages.
  ///
  /// [colorMaps] is a run of 256-byte rows. Doom ships 34: 32 light levels,
  /// then the invulnerability map, then an unused row.
  ///
  /// [palettes] is a run of 256-color rows, RGB or RGBA. Doom ships 14: the
  /// base palette, 8 damage-red steps, 4 item-pickup steps and the radsuit
  /// green.
  factory PaletteTextureData.encode({
    required int atlasWidth,
    required int atlasHeight,
    required Uint8List atlasIndices,
    required Uint8List colorMaps,
    required Uint8List palettes,
    Uint8List? atlasCoverage,
    int paletteChannels = 3,
  }) {
    if (atlasWidth <= 0 || atlasHeight <= 0) {
      throw ArgumentError('Atlas dimensions must be positive');
    }
    final pixelCount = atlasWidth * atlasHeight;
    if (atlasIndices.length != pixelCount) {
      throw ArgumentError.value(
        atlasIndices.length,
        'atlasIndices',
        'expected $pixelCount bytes for ${atlasWidth}x$atlasHeight',
      );
    }
    if (atlasCoverage != null && atlasCoverage.length != pixelCount) {
      throw ArgumentError.value(
        atlasCoverage.length,
        'atlasCoverage',
        'expected $pixelCount bytes',
      );
    }
    if (colorMaps.isEmpty || colorMaps.length % 256 != 0) {
      throw ArgumentError.value(
        colorMaps.length,
        'colorMaps',
        'expected whole 256-byte rows',
      );
    }
    if (paletteChannels != 3 && paletteChannels != 4) {
      throw ArgumentError.value(
        paletteChannels,
        'paletteChannels',
        'must be 3 (RGB) or 4 (RGBA)',
      );
    }
    final paletteStride = 256 * paletteChannels;
    if (palettes.isEmpty || palettes.length % paletteStride != 0) {
      throw ArgumentError.value(
        palettes.length,
        'palettes',
        'expected whole 256-color rows',
      );
    }

    // Atlas: index in red, coverage mirrored in green and alpha. This is the
    // same byte contract IndexedAtlas publishes; keeping both coverage
    // channels prevents an adapter-only texture from behaving differently
    // from a geometry-produced page.
    final atlasRgba = Uint8List(pixelCount * 4);
    for (var pixel = 0; pixel < pixelCount; pixel++) {
      final target = pixel * 4;
      atlasRgba[target] = atlasIndices[pixel];
      final coverage = atlasCoverage?[pixel] ?? 255;
      atlasRgba[target + 1] = coverage;
      atlasRgba[target + 3] = coverage;
    }

    // COLORMAP: remapped index in red.
    final colorMapRgba = Uint8List(colorMaps.length * 4);
    for (var entry = 0; entry < colorMaps.length; entry++) {
      final target = entry * 4;
      colorMapRgba[target] = colorMaps[entry];
      colorMapRgba[target + 3] = 255;
    }

    // PLAYPAL: RGB verbatim, alpha forced opaque. Doom palettes have no alpha;
    // transparency is carried by the atlas coverage plane instead.
    final colorCount = palettes.length ~/ paletteChannels;
    final paletteRgba = Uint8List(colorCount * 4);
    for (var color = 0; color < colorCount; color++) {
      final source = color * paletteChannels;
      final target = color * 4;
      paletteRgba[target] = palettes[source];
      paletteRgba[target + 1] = palettes[source + 1];
      paletteRgba[target + 2] = palettes[source + 2];
      paletteRgba[target + 3] = 255;
    }

    return PaletteTextureData._(
      atlasRgba: atlasRgba,
      atlasWidth: atlasWidth,
      atlasHeight: atlasHeight,
      colorMapRgba: colorMapRgba,
      colorMapRows: colorMaps.length ~/ 256,
      paletteRgba: paletteRgba,
      paletteRows: colorCount ~/ 256,
    );
  }

  /// Bridges one geometry atlas page and the complete Doom lookup tables.
  ///
  /// [AtlasPage.pixels] is already the exact RGBA8 upload format (index in R,
  /// coverage in G and A), so it is retained without a wasteful split into
  /// index/coverage planes followed by another 4-channel expansion.
  factory PaletteTextureData.fromDoomResources({
    required geometry.AtlasPage page,
    required wad.WadResources resources,
  }) {
    final expectedBytes = page.size * page.size * 4;
    if (page.pixels.length != expectedBytes) {
      throw ArgumentError.value(
        page.pixels.length,
        'page.pixels',
        'expected $expectedBytes RGBA8 bytes',
      );
    }

    final colorMaps = resources.colormap.maps;
    final palettes = resources.playpal.palettes;
    if (colorMaps.isEmpty || palettes.isEmpty) {
      throw StateError('PLAYPAL and COLORMAP must contain at least one row');
    }
    for (final row in colorMaps) {
      if (row.length != 256) {
        throw ArgumentError.value(row.length, 'COLORMAP row', 'expected 256');
      }
    }
    for (final row in palettes) {
      if (row.length != 256 * 3) {
        throw ArgumentError.value(row.length, 'PLAYPAL row', 'expected 768');
      }
    }

    final colorMapRgba = Uint8List(colorMaps.length * 256 * 4);
    for (var row = 0; row < colorMaps.length; row++) {
      final source = colorMaps[row];
      for (var index = 0; index < 256; index++) {
        final target = (row * 256 + index) * 4;
        colorMapRgba[target] = source[index];
        colorMapRgba[target + 3] = 255;
      }
    }

    final paletteRgba = Uint8List(palettes.length * 256 * 4);
    for (var row = 0; row < palettes.length; row++) {
      final source = palettes[row];
      for (var index = 0; index < 256; index++) {
        final sourceOffset = index * 3;
        final target = (row * 256 + index) * 4;
        paletteRgba[target] = source[sourceOffset];
        paletteRgba[target + 1] = source[sourceOffset + 1];
        paletteRgba[target + 2] = source[sourceOffset + 2];
        paletteRgba[target + 3] = 255;
      }
    }

    return PaletteTextureData._(
      atlasRgba: page.pixels,
      atlasWidth: page.size,
      atlasHeight: page.size,
      colorMapRgba: colorMapRgba,
      colorMapRows: colorMaps.length,
      paletteRgba: paletteRgba,
      paletteRows: palettes.length,
    );
  }

  /// RGBA8 atlas: palette index in red, mask coverage in alpha.
  final Uint8List atlasRgba;
  final int atlasWidth;
  final int atlasHeight;

  /// RGBA8 COLORMAP, 256 columns by [colorMapRows] rows.
  final Uint8List colorMapRgba;
  final int colorMapRows;

  /// RGBA8 PLAYPAL, 256 columns by [paletteRows] rows.
  final Uint8List paletteRgba;
  final int paletteRows;

  /// Highest usable light row.
  ///
  /// Doom's COLORMAP has 32 light levels followed by the invulnerability map,
  /// so distance shading must never run past row 31 or a dark corridor would
  /// suddenly invert.
  int get maxLightRow {
    const doomLightLevels = 32;
    final usable = colorMapRows >= doomLightLevels
        ? doomLightLevels
        : colorMapRows;
    return usable - 1;
  }

  /// Row holding the invulnerability map, or -1 when absent.
  int get invulnerabilityRow => colorMapRows > 32 ? 32 : -1;

  /// The CPU oracle for the shader's two-stage lookup.
  ///
  /// Tests compare this against hand-computed expectations. It performs the
  /// same index -> COLORMAP -> PLAYPAL walk the fragment shader does, with no
  /// tinting after the palette lookup.
  Color lookup(int paletteIndex, {int lightRow = 0, int paletteRow = 0}) {
    if (paletteIndex < 0 || paletteIndex > 255) {
      throw RangeError.range(paletteIndex, 0, 255, 'paletteIndex');
    }
    if (lightRow < 0 || lightRow >= colorMapRows) {
      throw RangeError.range(lightRow, 0, colorMapRows - 1, 'lightRow');
    }
    if (paletteRow < 0 || paletteRow >= paletteRows) {
      throw RangeError.range(paletteRow, 0, paletteRows - 1, 'paletteRow');
    }
    final remapped = colorMapRgba[(lightRow * 256 + paletteIndex) * 4];
    final offset = (paletteRow * 256 + remapped) * 4;
    return Color.fromARGB(
      255,
      paletteRgba[offset],
      paletteRgba[offset + 1],
      paletteRgba[offset + 2],
    );
  }

  /// Reads back the encoded palette index at a pixel.
  int atlasIndexAt(int x, int y) => atlasRgba[(y * atlasWidth + x) * 4];

  /// Reads back the encoded mask coverage at a pixel.
  int atlasCoverageAt(int x, int y) => atlasRgba[(y * atlasWidth + x) * 4 + 1];
}

/// The three GPU textures bound by [PaletteMaterial].
///
/// Textures are created lazily by flame_3d on first use and there is no
/// disposal API in 0.3.0, so one set should be built per level and shared by
/// every material.
final class PaletteTextures {
  PaletteTextures(this.data, {RenderDiagnostics? diagnostics})
    : indexAtlas = Texture(
        _byteView(data.atlasRgba),
        width: data.atlasWidth,
        height: data.atlasHeight,
      ),
      colorMapLut = Texture(
        _byteView(data.colorMapRgba),
        width: 256,
        height: data.colorMapRows,
      ),
      paletteLut = Texture(
        _byteView(data.paletteRgba),
        width: 256,
        height: data.paletteRows,
        format: PixelFormat.rgba8888,
      ) {
    diagnostics
      ?..onTextureCreated()
      ..onTextureCreated()
      ..onTextureCreated();
  }

  final PaletteTextureData data;

  /// Indexed art. Sampled with the backend's nearest filter, which is what
  /// keeps Doom's texels crisp instead of smeared.
  final Texture indexAtlas;

  /// Light-level remap table.
  final Texture colorMapLut;

  /// Final index-to-RGB table, one row per palette variant.
  final Texture paletteLut;
}

/// The 14 PLAYPAL variants, named.
///
/// Screen flashes are a palette row change and nothing else: no extra draw, no
/// blend, no full-screen quad. Selecting a row costs one uniform write.
abstract final class DoomPaletteVariant {
  /// Normal play.
  static const int normal = 0;

  /// Damage and berserk tint, rows 1..8, increasing in intensity.
  static const int damageFirst = 1;
  static const int damageLast = 8;

  /// Item pickup tint, rows 9..12.
  static const int itemPickupFirst = 9;
  static const int itemPickupLast = 12;

  /// Radiation suit green.
  static const int radiationSuit = 13;

  /// Total variants shipped in a Doom PLAYPAL.
  static const int count = 14;

  /// Maps a 0..1 damage amount onto the red flash rows.
  static int damage(double amount) {
    if (!amount.isFinite || amount <= 0) {
      return normal;
    }
    final steps = damageLast - damageFirst + 1;
    final step = (amount.clamp(0.0, 1.0) * steps).ceil();
    return step <= 0 ? normal : damageFirst + (step - 1);
  }

  /// Maps a 0..1 pickup amount onto the gold flash rows.
  static int itemPickup(double amount) {
    if (!amount.isFinite || amount <= 0) {
      return normal;
    }
    final steps = itemPickupLast - itemPickupFirst + 1;
    final step = (amount.clamp(0.0, 1.0) * steps).ceil();
    return step <= 0 ? normal : itemPickupFirst + (step - 1);
  }
}

ByteData _byteView(Uint8List bytes) =>
    bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
