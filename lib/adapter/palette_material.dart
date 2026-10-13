import 'dart:typed_data';

import 'palette_textures.dart';

/// The state of Doompeller's indexed-palette shader: atlas index, COLORMAP,
/// PLAYPAL.
///
/// One material covers an entire atlas page. Per-texture data (the atlas
/// sub-rectangle and the sampling mode) travels in the vertex record instead of
/// in uniforms, so wall, flat and sprite geometry sharing a page collapse into
/// a single draw, and the material count stays near the page count.
///
/// This is plain state. The presenter mirrors it into a GPU material and
/// re-uploads the uniform block only when [revision] changes.
///
/// Screen flashes are [paletteIndex] changes. Nothing is redrawn and no
/// full-screen quad is composited, exactly as the original did it.
final class PaletteMaterial {
  PaletteMaterial({
    required this.textures,
    int paletteIndex = DoomPaletteVariant.normal,
    this.alphaCutout = false,
    double lightScale = 1,
    double distanceScale = defaultDistanceScale,
  }) : _paletteIndex = paletteIndex,
       // Mutable settings are exposed through validating setters, so the
       // backing fields stay private.
       // ignore: prefer_initializing_formals
       _lightScale = lightScale,
       // ignore: prefer_initializing_formals
       _distanceScale = distanceScale {
    _validatePaletteIndex(paletteIndex);
  }

  /// COLORMAP rows added per world unit of distance.
  ///
  /// Doom diminishes light with distance in addition to sector brightness. The
  /// default is tuned so a surface reaches full darkness at roughly the
  /// original engine's visible range; a level using different world scale can
  /// override it.
  static const double defaultDistanceScale = 1 / 96;

  /// The shared lookup textures for this atlas page.
  final PaletteTextures textures;

  /// Whether fragments below the coverage threshold are discarded.
  ///
  /// Masked midtextures, sprites and the weapon quad set this. Opaque world
  /// geometry leaves it off so the branch never runs.
  final bool alphaCutout;

  int _paletteIndex;
  double _lightScale;
  double _distanceScale;

  /// Fixed COLORMAP row for invulnerability/light amplification; -1 restores
  /// ordinary sector and distance lighting without rewriting geometry.
  int get fixedColorMap => _fixedColorMap;
  int _fixedColorMap = -1;
  set fixedColorMap(int value) {
    if (value < -1 || value >= textures.data.colorMapRows) {
      throw RangeError.range(value, -1, textures.data.colorMapRows - 1);
    }
    if (_fixedColorMap == value) return;
    _fixedColorMap = value;
    _revision++;
  }

  /// The active PLAYPAL row. See [DoomPaletteVariant].
  int get paletteIndex => _paletteIndex;
  set paletteIndex(int value) {
    _validatePaletteIndex(value);
    if (_paletteIndex == value) return;
    _paletteIndex = value;
    _revision++;
  }

  /// Multiplier on sector light before the COLORMAP row is chosen.
  double get lightScale => _lightScale;
  set lightScale(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, 'lightScale', 'must be finite and >= 0');
    }
    if (_lightScale == value) return;
    _lightScale = value;
    _revision++;
  }

  /// COLORMAP rows added per world unit of distance.
  double get distanceScale => _distanceScale;
  set distanceScale(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(
        value,
        'distanceScale',
        'must be finite and >= 0',
      );
    }
    if (_distanceScale == value) return;
    _distanceScale = value;
    _revision++;
  }

  /// Coverage below which a fragment is discarded.
  ///
  /// Doom masks are binary, so anything under half counts as a hole. Zero
  /// disables the test entirely.
  double get alphaThreshold => alphaCutout ? 0.5 : 0;

  /// Changes whenever a uniform value changes.
  int get revision => _revision;
  int _revision = 0;

  /// Number of floats in the std140 DoomMaterial uniform block.
  static const int uniformFloats = 12;

  /// Writes the DoomMaterial block, three vec4 rows matching
  /// shaders/doom_palette.frag, into [target] and returns it.
  Float32List writeUniforms([Float32List? target]) {
    final data = textures.data;
    return (target ?? Float32List(uniformFloats))
      // (atlasWidth, atlasHeight, colorMapRows, paletteRows)
      ..[0] = data.atlasWidth.toDouble()
      ..[1] = data.atlasHeight.toDouble()
      ..[2] = data.colorMapRows.toDouble()
      ..[3] = data.paletteRows.toDouble()
      // (paletteIndex, lightScale, distanceScale, alphaThreshold)
      ..[4] = _paletteIndex.toDouble()
      ..[5] = _lightScale
      ..[6] = _distanceScale
      ..[7] = alphaThreshold
      // (maxLightRow, invulnerabilityRow, fixedColorMap, unused)
      ..[8] = data.maxLightRow.toDouble()
      ..[9] = data.invulnerabilityRow.toDouble()
      ..[10] = _fixedColorMap.toDouble()
      ..[11] = 0;
  }

  void _validatePaletteIndex(int value) {
    if (value < 0 || value >= textures.data.paletteRows) {
      throw RangeError.range(
        value,
        0,
        textures.data.paletteRows - 1,
        'paletteIndex',
      );
    }
  }
}

/// Reuses one [PaletteMaterial] per (atlas page, cutout mode) pair.
///
/// Each distinct material is a distinct GPU material, and GPU memory is
/// reclaimed only when the engine collects it, so creating them per surface
/// would grow GPU state with the surface count. The cache also gives screen flashes a single place to
/// update every live material at once.
final class PaletteMaterialCache {
  PaletteMaterialCache();

  final Map<(String, bool, PaletteTextures), PaletteMaterial> _materials = {};

  /// Distinct materials currently held.
  int get length => _materials.length;

  /// Every live material, for bulk uniform updates.
  Iterable<PaletteMaterial> get materials => _materials.values;

  /// Returns the material for [atlasKey], creating it on first use.
  PaletteMaterial resolve({
    required String atlasKey,
    required PaletteTextures textures,
    required bool alphaCutout,
    int paletteIndex = DoomPaletteVariant.normal,
  }) => _materials.putIfAbsent(
    (atlasKey, alphaCutout, textures),
    () => PaletteMaterial(
      textures: textures,
      alphaCutout: alphaCutout,
      paletteIndex: paletteIndex,
    ),
  );

  /// Starts publishing another scene through this cache.
  ///
  /// A cache is bounded to one published scene. Old surfaces retain their
  /// material objects, but a same-named page in the new level can never reuse
  /// bindings to the previous level's atlas or palette textures.
  void beginScene() => _materials.clear();

  /// Switches every live material to [paletteIndex].
  ///
  /// This is the whole implementation of a damage or pickup flash.
  void setPaletteIndex(int paletteIndex) {
    for (final material in _materials.values) {
      material.paletteIndex = paletteIndex;
    }
  }

  void setFixedColorMap(int row) {
    for (final material in _materials.values) {
      material.fixedColorMap = row < material.textures.data.colorMapRows
          ? row
          : -1;
    }
  }

  /// Drops every cached material. The GPU side is reclaimed when the engine
  /// collects it.
  void clear() => _materials.clear();
}
