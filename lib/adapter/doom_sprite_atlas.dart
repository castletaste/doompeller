import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;

import 'doom_sprite_catalog.dart';

/// Bounded supplemental atlas for actor and first-person weapon sprites.
///
/// World compilation deliberately does not pack every IWAD sprite. Callers
/// must provide an explicit prefix/name allow-list; GeometryOptions' atlas
/// budget is applied to that subset and overflow is a loud failure.
final class DoomSpriteAtlas {
  const DoomSpriteAtlas({required this.atlas, required this.catalog});

  factory DoomSpriteAtlas.build(
    wad.WadResources resources, {
    Set<String> requiredPrefixes = const <String>{},
    Set<String> requiredNames = const <String>{},
    geometry.GeometryOptions options = geometry.GeometryOptions.defaults,
  }) {
    final prefixes = <String>{
      for (final prefix in requiredPrefixes) prefix.toUpperCase(),
    };
    if (prefixes.any((prefix) => prefix.length != 4)) {
      throw ArgumentError.value(
        requiredPrefixes,
        'requiredPrefixes',
        'every sprite prefix must be four characters',
      );
    }
    final exactNames = <String>{
      for (final name in requiredNames) name.toUpperCase(),
    };
    final selected = <String>[
      for (final name in resources.spriteNames)
        if (exactNames.contains(name) ||
            (name.length >= 4 && prefixes.contains(name.substring(0, 4))))
          name,
    ]..sort();
    final missing = exactNames.difference(selected.toSet());
    if (missing.isNotEmpty) {
      throw StateError('Missing requested sprite lumps: ${missing.join(', ')}');
    }

    final builder = geometry.AtlasBuilder(
      geometry.ResourceTextureSource(resources),
      options,
    );
    for (final name in selected) {
      builder.addSprite(name);
    }
    final atlas = builder.build();
    if (atlas.overflowed.isNotEmpty) {
      throw StateError(
        'Supplemental sprite atlas exceeded maxAtlasPixels: '
        '${atlas.overflowed.join(', ')}',
      );
    }
    return DoomSpriteAtlas(atlas: atlas, catalog: DoomSpriteCatalog(selected));
  }

  final geometry.IndexedAtlas atlas;
  final DoomSpriteCatalog catalog;
}
