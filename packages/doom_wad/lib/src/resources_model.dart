import 'dart:typed_data';

/// Pure data classes for decoded WAD graphics. No behaviour beyond trivial
/// accessors, no Flutter types, no rendering assumptions.

/// Number of palettes in a vanilla PLAYPAL lump.
const int kPalettesPerPlaypal = 14;

/// Entries per palette.
const int kPaletteColors = 256;

/// Bytes per palette: 256 RGB triples.
const int kPaletteBytes = kPaletteColors * 3;

/// Number of light/effect maps in a vanilla COLORMAP lump.
const int kColormapCount = 34;

/// Bytes per colormap: one remapped index per palette entry.
const int kColormapBytes = kPaletteColors;

/// Edge length of a flat. Flats are always square and unpaletted.
const int kFlatSize = 64;

/// Bytes in one flat: 64x64 palette indices.
const int kFlatBytes = kFlatSize * kFlatSize;

/// Flat name that means "draw the sky here" rather than a real surface.
const String kSkyFlatName = 'F_SKY1';

/// Texture name meaning "no texture on this surface".
const String kNoTextureName = '-';

/// The 14 palettes of PLAYPAL.
///
/// Index 0 is the base palette; 1..8 are damage flashes, 9..12 item pickup
/// tints and 13 the radiation suit tint.
class Playpal {
  const Playpal(this.palettes);

  /// One [kPaletteBytes] long RGB block per palette.
  final List<Uint8List> palettes;

  /// Base palette, used for everything except full-screen tinting.
  Uint8List get base => palettes[0];

  int get length => palettes.length;

  /// Red channel of [color] in [palette].
  int red(int palette, int color) => palettes[palette][color * 3];

  /// Green channel of [color] in [palette].
  int green(int palette, int color) => palettes[palette][color * 3 + 1];

  /// Blue channel of [color] in [palette].
  int blue(int palette, int color) => palettes[palette][color * 3 + 2];

  /// Packs [palette] into 0xAARRGGBB words, opaque, for texture upload.
  Uint32List toArgb(int palette) {
    final Uint8List rgb = palettes[palette];
    final Uint32List out = Uint32List(kPaletteColors);
    for (var i = 0; i < kPaletteColors; i++) {
      final int o = i * 3;
      out[i] = 0xFF000000 | (rgb[o] << 16) | (rgb[o + 1] << 8) | rgb[o + 2];
    }
    return out;
  }
}

/// The 34 light maps of COLORMAP.
///
/// Maps 0..31 are the diminishing-light ramp (0 = brightest), 32 is the
/// invulnerability inversion and 33 is all-black.
class Colormap {
  const Colormap(this.maps);

  /// One [kColormapBytes] long index-remap table per map.
  final List<Uint8List> maps;

  int get length => maps.length;

  /// Brightest lighting level.
  Uint8List get brightest => maps[0];

  /// Flattens every map into a single row-major plane of length times 256
  /// bytes, ready to upload as a lookup texture.
  Uint8List toPlane() {
    final Uint8List out = Uint8List(maps.length * kColormapBytes);
    for (var i = 0; i < maps.length; i++) {
      out.setRange(i * kColormapBytes, (i + 1) * kColormapBytes, maps[i]);
    }
    return out;
  }
}

/// A decoded Doom patch: palette indices plus a coverage mask.
///
/// Storage is ROW-MAJOR: pixel (x, y) lives at index y * width + x. The
/// on-disk format is column-major, so the decoder transposes once at load
/// time; every downstream consumer (atlas packing, compositing, blitting) then
/// works in scanline order, which is what both the packer and the GPU want.
///
/// [coverage] is 0 for transparent pixels and 255 for opaque ones. Doom patches
/// have no alpha channel; transparency comes from columns simply not covering
/// a row, so the mask cannot be derived from [indices] alone (index 0 is a real
/// colour).
class PatchImage {
  const PatchImage({
    required this.width,
    required this.height,
    required this.leftOffset,
    required this.topOffset,
    required this.indices,
    required this.coverage,
  });

  /// A fully transparent patch of the given size.
  factory PatchImage.empty(int width, int height) => PatchImage(
        width: width,
        height: height,
        leftOffset: 0,
        topOffset: 0,
        indices: Uint8List(width * height),
        coverage: Uint8List(width * height),
      );

  final int width;
  final int height;

  /// Horizontal sprite origin: pixels from the patch's left edge to its hotspot.
  final int leftOffset;

  /// Vertical sprite origin: pixels from the patch's top edge to its hotspot.
  final int topOffset;

  /// width * height palette indices, row-major.
  final Uint8List indices;

  /// width * height opacity bytes, row-major: 0 transparent, 255 opaque.
  final Uint8List coverage;

  int get pixelCount => width * height;

  /// True when no pixel is transparent, so the image can skip masked draw paths.
  bool get isFullyOpaque {
    for (var i = 0; i < coverage.length; i++) {
      if (coverage[i] == 0) {
        return false;
      }
    }
    return true;
  }

  /// Palette index at (x, y); 0 when out of bounds.
  int indexAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return 0;
    }
    return indices[y * width + x];
  }

  /// Opacity at (x, y); 0 when out of bounds.
  int coverageAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return 0;
    }
    return coverage[y * width + x];
  }
}

/// A 64x64 floor or ceiling texture. Flats are raw index planes with no header.
class FlatImage {
  const FlatImage({required this.name, required this.indices});

  /// Uppercase lump name.
  final String name;

  /// [kFlatBytes] palette indices, row-major.
  final Uint8List indices;

  int get width => kFlatSize;
  int get height => kFlatSize;

  /// True when this flat is the sky sentinel rather than a drawable surface.
  bool get isSky => name == kSkyFlatName;

  int indexAt(int x, int y) => indices[(y & 63) * kFlatSize + (x & 63)];
}

/// One patch placement inside a composite texture.
class TexturePatch {
  const TexturePatch({
    required this.originX,
    required this.originY,
    required this.patchIndex,
  });

  /// Offset of the patch's left edge from the texture's left edge. May be
  /// negative: vanilla clips patches that hang off the texture.
  final int originX;

  /// Offset of the patch's top edge from the texture's top edge.
  final int originY;

  /// Index into PNAMES.
  final int patchIndex;

  @override
  String toString() => 'TexturePatch($originX, $originY, #$patchIndex)';
}

/// A TEXTURE1/TEXTURE2 entry: a canvas size plus the patches painted onto it.
class TextureDef {
  const TextureDef({
    required this.name,
    required this.width,
    required this.height,
    required this.patches,
  });

  /// Uppercase texture name as referenced by sidedefs.
  final String name;
  final int width;
  final int height;

  /// Patches in paint order; later entries draw over earlier ones.
  final List<TexturePatch> patches;

  int get pixelCount => width * height;

  @override
  String toString() =>
      'TextureDef($name, ${width}x$height, ${patches.length} patches)';
}
