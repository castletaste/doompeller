import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

import 'palette_textures.dart';

/// Binds Doompeller's indexed-palette shader: atlas index, COLORMAP, PLAYPAL.
///
/// One material covers an entire atlas page. Per-texture data (the atlas
/// sub-rectangle and the sampling mode) travels in the vertex record instead of
/// in uniforms, so wall, flat and sprite geometry sharing a page collapse into
/// a single draw. flame_3d 0.3.0 has no batching and insertion-sorts visible
/// draws back-to-front, so keeping the material count near the page count is
/// the main lever on frame cost.
///
/// Screen flashes are [paletteIndex] changes. Nothing is redrawn and no
/// full-screen quad is composited, exactly as the original did it.
final class PaletteMaterial extends Material {
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
       _distanceScale = distanceScale,
       super(
         vertexShader: VertexShader.fromAsset(
           shaderAsset,
           slots: const ['VertexInfo'],
         ),
         fragmentShader: FragmentShader.fromAsset(
           shaderAsset,
           slots: const [
             'indexAtlas',
             'colorMapLut',
             'paletteLut',
             'DoomMaterial',
           ],
         ),
       ) {
    _validatePaletteIndex(paletteIndex);
  }

  /// The compiled bundle produced by tool/build_shaders.sh.
  static const String shaderAsset = 'assets/shaders/doom_palette.shaderbundle';

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

  /// The active PLAYPAL row. See [DoomPaletteVariant].
  int get paletteIndex => _paletteIndex;
  set paletteIndex(int value) {
    _validatePaletteIndex(value);
    _paletteIndex = value;
  }

  /// Multiplier on sector light before the COLORMAP row is chosen.
  double get lightScale => _lightScale;
  set lightScale(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, 'lightScale', 'must be finite and >= 0');
    }
    _lightScale = value;
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
    _distanceScale = value;
  }

  /// Coverage below which a fragment is discarded.
  ///
  /// Doom masks are binary, so anything under half counts as a hole. Zero
  /// disables the test entirely.
  double get alphaThreshold => alphaCutout ? 0.5 : 0;

  @override
  void apply(covariant RenderContext3D context) {
    vertexShader
      ..setMatrix4('VertexInfo.model', context.model)
      ..setMatrix4('VertexInfo.view', context.view)
      ..setMatrix4('VertexInfo.projection', context.projection);

    final data = textures.data;
    fragmentShader
      ..setTexture('indexAtlas', textures.indexAtlas)
      ..setTexture('colorMapLut', textures.colorMapLut)
      ..setTexture('paletteLut', textures.paletteLut)
      ..setVector4(
        'DoomMaterial.atlasSize',
        Vector4(
          data.atlasWidth.toDouble(),
          data.atlasHeight.toDouble(),
          data.colorMapRows.toDouble(),
          data.paletteRows.toDouble(),
        ),
      )
      ..setVector4(
        'DoomMaterial.palette',
        Vector4(
          _paletteIndex.toDouble(),
          _lightScale,
          _distanceScale,
          alphaThreshold,
        ),
      )
      ..setVector4(
        'DoomMaterial.lighting',
        Vector4(
          data.maxLightRow.toDouble(),
          data.invulnerabilityRow.toDouble(),
          0,
          0,
        ),
      );
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
/// Each distinct material is a distinct GPU pipeline, and flame_3d has no
/// disposal API, so creating them per surface would leak pipelines for the
/// process lifetime. The cache also gives screen flashes a single place to
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

  /// Drops every cached material. The underlying GPU pipelines are not
  /// reclaimed, because flame_3d 0.3.0 exposes no disposal API.
  void clear() => _materials.clear();
}
