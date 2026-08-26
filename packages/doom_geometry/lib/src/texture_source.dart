import 'wad_types.dart';

/// Narrow view of the texture data the geometry compiler actually needs.
///
/// The public entry point still takes a WadResources exactly as the contract
/// says, but everything inside this package talks to this interface instead.
/// Two reasons: the compiler only ever needs four lookups out of the much
/// larger resource surface, and tests can supply a handful of synthetic
/// textures without building a WAD container first.
abstract class TextureSource {
  /// Classic animations resolved against this source's real declaration order.
  DoomAnimationResolution get animationResolution;

  /// Classic two-state switch pairs available to the compiler.
  List<DoomSwitchPair> get switchPairs;

  /// Composited wall texture by TEXTURE1/TEXTURE2 name, or null if absent.
  PatchImage? composite(String name);

  /// 64x64 floor/ceiling flat by name, or null if absent.
  FlatImage? flat(String name);

  /// Sprite patch by lump name, or null if absent.
  PatchImage? sprite(String name);

  /// Declared texture size without forcing a composite to be built.
  ///
  /// Vanilla aligns wall textures against the size declared in TEXTURE1, which
  /// can differ from the pixels actually covered by patches, so alignment must
  /// use this rather than the composited image's bounds.
  TextureDef? textureDef(String name);
}

/// Adapts a real [WadResources] to [TextureSource].
///
/// The method set lines up one for one, so this is a pass-through with
/// memoisation: compositing a texture is expensive and one level asks for the
/// same handful of names thousands of times.
class ResourceTextureSource implements TextureSource {
  ResourceTextureSource(this.resources);

  final WadResources resources;

  late final DoomAnimationResolution _animations = resolveDoomAnimations(
    resources,
  );

  @override
  DoomAnimationResolution get animationResolution => _animations;

  @override
  List<DoomSwitchPair> get switchPairs => vanillaDoomSwitches;

  final Map<String, PatchImage?> _compositeCache = <String, PatchImage?>{};
  final Map<String, FlatImage?> _flatCache = <String, FlatImage?>{};
  final Map<String, PatchImage?> _spriteCache = <String, PatchImage?>{};

  @override
  PatchImage? composite(String name) =>
      _compositeCache.putIfAbsent(name, () => resources.composite(name));

  @override
  FlatImage? flat(String name) =>
      _flatCache.putIfAbsent(name, () => resources.flat(name));

  @override
  PatchImage? sprite(String name) =>
      _spriteCache.putIfAbsent(name, () => resources.sprite(name));

  @override
  TextureDef? textureDef(String name) => resources.textureDef(name);
}

/// [TextureSource] backed by a real parsed WAD.
///
/// Kept deliberately thin: it forwards, it does not reinterpret. Results are
/// memoised because compositing a texture is expensive and a single level asks
/// for the same handful of names thousands of times.
///
/// Lookups arrive as function references rather than a WadResources-typed
/// field so this package does not move in lockstep with the resource loader
/// while both are being written.
class WadTextureSource implements TextureSource {
  WadTextureSource({
    required PatchImage? Function(String name) composite,
    required FlatImage? Function(String name) flat,
    required PatchImage? Function(String name) sprite,
    required TextureDef? Function(String name) textureDef,
    this._animations = const DoomAnimationResolution(
      animations: <DoomAnimation>[],
      failures: <DoomAnimationFailure>[],
    ),
    this._switchPairs = const <DoomSwitchPair>[],
  }) : _compositeFn = composite,
       _flatFn = flat,
       _spriteFn = sprite,
       _defFn = textureDef;

  final PatchImage? Function(String name) _compositeFn;
  final FlatImage? Function(String name) _flatFn;
  final PatchImage? Function(String name) _spriteFn;
  final TextureDef? Function(String name) _defFn;
  final DoomAnimationResolution _animations;
  final List<DoomSwitchPair> _switchPairs;

  @override
  DoomAnimationResolution get animationResolution => _animations;

  @override
  List<DoomSwitchPair> get switchPairs => _switchPairs;

  final Map<String, PatchImage?> _compositeCache = <String, PatchImage?>{};
  final Map<String, FlatImage?> _flatCache = <String, FlatImage?>{};
  final Map<String, PatchImage?> _spriteCache = <String, PatchImage?>{};

  @override
  PatchImage? composite(String name) =>
      _compositeCache.putIfAbsent(name, () => _compositeFn(name));

  @override
  FlatImage? flat(String name) =>
      _flatCache.putIfAbsent(name, () => _flatFn(name));

  @override
  PatchImage? sprite(String name) =>
      _spriteCache.putIfAbsent(name, () => _spriteFn(name));

  @override
  TextureDef? textureDef(String name) => _defFn(name);
}

/// In-memory [TextureSource] for tests and for maps that reference textures the
/// loaded WAD set does not contain.
class MapTextureSource implements TextureSource {
  MapTextureSource({
    Map<String, PatchImage>? composites,
    Map<String, FlatImage>? flats,
    Map<String, PatchImage>? sprites,
    Map<String, TextureDef>? defs,
    this._animations = const DoomAnimationResolution(
      animations: <DoomAnimation>[],
      failures: <DoomAnimationFailure>[],
    ),
    this._switchPairs = const <DoomSwitchPair>[],
  }) : _composites = composites ?? <String, PatchImage>{},
       _flats = flats ?? <String, FlatImage>{},
       _sprites = sprites ?? <String, PatchImage>{},
       _defs = defs ?? <String, TextureDef>{};

  final Map<String, PatchImage> _composites;
  final Map<String, FlatImage> _flats;
  final Map<String, PatchImage> _sprites;
  final Map<String, TextureDef> _defs;
  final DoomAnimationResolution _animations;
  final List<DoomSwitchPair> _switchPairs;

  @override
  DoomAnimationResolution get animationResolution => _animations;

  @override
  List<DoomSwitchPair> get switchPairs => _switchPairs;

  @override
  PatchImage? composite(String name) => _composites[name];

  @override
  FlatImage? flat(String name) => _flats[name];

  @override
  PatchImage? sprite(String name) => _sprites[name];

  @override
  TextureDef? textureDef(String name) {
    final TextureDef? declared = _defs[name];
    if (declared != null) {
      return declared;
    }
    final PatchImage? image = _composites[name];
    if (image == null) {
      return null;
    }
    return TextureDef(
      name: name,
      width: image.width,
      height: image.height,
      patches: const <TexturePatch>[],
    );
  }
}
