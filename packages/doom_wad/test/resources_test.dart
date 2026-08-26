import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

/// Wraps [lumps] into a set that already contains the mandatory palettes.
WadSet setWith(List<LumpSource> lumps) => WadSet(<WadFile>[
  WadFile.parse(
    buildWad(<LumpSource>[
      LumpSource('PLAYPAL', buildFixturePlaypal()),
      LumpSource('COLORMAP', buildFixtureColormap()),
      ...lumps,
    ]),
  ),
]);

/// A patch with a known pattern and a transparent gap in the middle column.
PatchImage sample() {
  const int w = 5;
  const int h = 7;
  final Uint8List indices = Uint8List(w * h);
  final Uint8List coverage = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // Leave a hole so coverage is not uniformly opaque.
      if (x == 2 && y > 1 && y < 5) {
        continue;
      }
      indices[y * w + x] = (x * 16 + y + 1) & 0xFF;
      coverage[y * w + x] = 255;
    }
  }
  return PatchImage(
    width: w,
    height: h,
    leftOffset: -3,
    topOffset: 4,
    indices: indices,
    coverage: coverage,
  );
}

void main() {
  group('patch codec', () {
    test('round-trips pixels, coverage and offsets', () {
      final PatchImage original = sample();
      final PatchImage decoded = decodeDoomPatch(encodeDoomPatch(original));

      expect(decoded.width, original.width);
      expect(decoded.height, original.height);
      expect(decoded.leftOffset, -3);
      expect(decoded.topOffset, 4);
      expect(decoded.coverage, original.coverage);
      // Transparent pixels are not stored, so only covered ones must match.
      for (var i = 0; i < original.indices.length; i++) {
        if (original.coverage[i] != 0) {
          expect(decoded.indices[i], original.indices[i], reason: 'pixel $i');
        }
      }
      expect(decoded.isFullyOpaque, isFalse);
    });

    test('round-trips a fully opaque patch', () {
      final PatchImage original = buildFixturePatch('PAT1');
      final PatchImage decoded = decodeDoomPatch(encodeDoomPatch(original));
      expect(decoded.isFullyOpaque, isTrue);
      expect(decoded.indices, original.indices);
    });

    test('round-trips a tall patch using relative topdeltas', () {
      // Over 254 rows the topdelta byte cannot address the bottom of the patch
      // directly, so the encoder must emit relative posts.
      const int w = 3;
      const int h = 400;
      final Uint8List indices = Uint8List(w * h);
      final Uint8List coverage = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          // Two bands, one of them entirely below row 254.
          if (y < 40 || y > 300) {
            indices[y * w + x] = (y + x) & 0xFF;
            coverage[y * w + x] = 255;
          }
        }
      }
      final PatchImage original = PatchImage(
        width: w,
        height: h,
        leftOffset: 0,
        topOffset: 0,
        indices: indices,
        coverage: coverage,
      );
      final PatchImage decoded = decodeDoomPatch(encodeDoomPatch(original));
      expect(decoded.height, h);
      expect(decoded.coverage, coverage);
      for (var i = 0; i < indices.length; i++) {
        if (coverage[i] != 0) {
          expect(decoded.indices[i], indices[i], reason: 'pixel $i');
        }
      }
    });

    test('round-trips a run longer than one post', () {
      // A 300 row solid column must be chunked into multiple posts.
      const int w = 1;
      const int h = 300;
      final PatchImage original = PatchImage(
        width: w,
        height: h,
        leftOffset: 0,
        topOffset: 0,
        indices: Uint8List.fromList(
          List<int>.generate(h, (int i) => (i + 1) & 0xFF),
        ),
        coverage: Uint8List(h)..fillRange(0, h, 255),
      );
      final PatchImage decoded = decodeDoomPatch(encodeDoomPatch(original));
      expect(decoded.isFullyOpaque, isTrue);
      expect(decoded.indices, original.indices);
    });

    test('rejects a truncated patch header', () {
      expect(
        () => decodeDoomPatch(Uint8List(4)),
        throwsA(isA<DoomFormatFailure>()),
      );
    });

    test('rejects zero and negative dimensions', () {
      final Uint8List lump = Uint8List(64);
      ByteData.sublistView(lump).setInt16(0, 0, Endian.little);
      ByteData.sublistView(lump).setInt16(2, 8, Endian.little);
      expect(() => decodeDoomPatch(lump), throwsA(isA<DoomFormatFailure>()));
    });

    test('rejects a column offset outside the lump', () {
      final Uint8List lump = encodeDoomPatch(sample());
      ByteData.sublistView(lump).setInt32(8, 100000, Endian.little);
      expect(() => decodeDoomPatch(lump), throwsA(isA<DoomFormatFailure>()));
    });

    test('rejects a post running past the end of the lump', () {
      final Uint8List lump = encodeDoomPatch(sample());
      // First post of the first column claims a huge length.
      final int column = ByteData.sublistView(lump).getInt32(8, Endian.little);
      lump[column + 1] = 250;
      expect(() => decodeDoomPatch(lump), throwsA(isA<DoomFormatFailure>()));
    });

    test('honours maxCompositePixels', () {
      final PatchImage big = PatchImage.empty(64, 64);
      expect(
        () => decodeDoomPatch(
          encodeDoomPatch(big),
          limits: const DoomLimits(maxCompositePixels: 16),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxCompositePixels',
          ),
        ),
      );
    });
  });

  group('WadResources.load', () {
    test('decodes palettes and colormaps from the fixture', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      expect(res.playpal.length, 14);
      expect(res.playpal.base.length, 768);
      expect(res.colormap.length, 34);
      expect(res.colormap.brightest.length, 256);
      // The colormap's brightest level must be the identity on the palette's
      // brightness axis, otherwise lighting would shift at full brightness.
      for (var i = 0; i < 256; i++) {
        expect(res.colormap.brightest[i], i);
      }
      expect(res.colormap.toPlane().length, 34 * 256);
      expect(res.playpal.toArgb(0).length, 256);
    });

    test('requires PLAYPAL and COLORMAP', () {
      final WadSet bare = WadSet(<WadFile>[
        WadFile.parse(buildWad(<LumpSource>[LumpSource('X', Uint8List(1))])),
      ]);
      expect(
        () => WadResources.load(bare),
        throwsA(isA<DoomMissingLumpFailure>()),
      );
    });

    test('reads the texture directory in declaration order', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      expect(res.textureNames, <String>[
        ...DoomFixtures.texture1Names,
        ...DoomFixtures.texture2Names,
      ]);
      expect(res.patchNames, DoomFixtures.patchNames);

      final TextureDef wall2 = res.textureDef('WALL2')!;
      expect(wall2.width, 128);
      expect(wall2.height, 128);
      expect(wall2.patches.length, 2);
      expect(wall2.patches[1].originX, 64);
      expect(wall2.patches[1].patchIndex, 1);

      final TextureDef sky = res.textureDef('SKY1')!;
      expect(sky.width, 256);
      expect(sky.height, 128);
      expect(sky.patches.single.patchIndex, 4);
    });

    test(
      'texture lookup is case insensitive and handles the no-texture name',
      () {
        final WadResources res = WadResources.load(DoomFixtures.wadSet());
        expect(res.textureDef('wall1'), isNotNull);
        expect(res.textureDef('WaLl1'), isNotNull);
        expect(res.textureDef('-'), isNull);
        expect(res.composite('-'), isNull);
        expect(res.composite('NOSUCHTEX'), isNull);
        expect(res.textureDef('NOSUCHTEX'), isNull);
      },
    );

    test('TEXTURE1 wins a duplicate texture name over TEXTURE2', () {
      final WadResources res = WadResources.load(
        setWith(<LumpSource>[
          LumpSource('PNAMES', _pnames(<String>['FIRST', 'SECOND'])),
          LumpSource('FIRST', encodeDoomPatch(_solidPatch(16, 24, 11))),
          LumpSource('SECOND', encodeDoomPatch(_solidPatch(32, 40, 29))),
          LumpSource(
            'TEXTURE1',
            _textureDirectory(<_TextureSpec>[
              const _TextureSpec('DUPL', 16, 24, 0),
            ]),
          ),
          LumpSource(
            'TEXTURE2',
            _textureDirectory(<_TextureSpec>[
              const _TextureSpec('DUPL', 32, 40, 1),
            ]),
          ),
        ]),
      );

      expect(res.textureNames, <String>['DUPL']);
      expect(
        (res.textureDef('dupl')!.width, res.textureDef('DUPL')!.height),
        (16, 24),
      );
      expect(res.composite('DUPL')!.indexAt(0, 0), 11);
    });

    test('unused PNAMES entry may be absent when every texture resolves', () {
      final WadResources res = WadResources.load(
        setWith(<LumpSource>[
          LumpSource('PNAMES', _pnames(<String>['USED', 'UNUSED'])),
          LumpSource('USED', encodeDoomPatch(_solidPatch(16, 16, 7))),
          LumpSource(
            'TEXTURE1',
            _textureDirectory(<_TextureSpec>[
              const _TextureSpec('COMPLETE', 16, 16, 0),
            ]),
          ),
        ]),
      );

      expect(res.patchNames, <String>['USED', 'UNUSED']);
      expect(res.patchAt(0), isNotNull);
      expect(res.patchAt(1), isNull);
      expect(res.composite('COMPLETE'), isNotNull);
    });

    test('a PWAD replacement TEXTURE1 still wins over an IWAD TEXTURE1', () {
      final WadFile iwad = WadFile.parse(
        buildWad(<LumpSource>[
          LumpSource('PLAYPAL', buildFixturePlaypal()),
          LumpSource('COLORMAP', buildFixtureColormap()),
          LumpSource('PNAMES', _pnames(<String>['FIRST', 'SECOND'])),
          LumpSource('FIRST', encodeDoomPatch(_solidPatch(16, 24, 11))),
          LumpSource('SECOND', encodeDoomPatch(_solidPatch(32, 40, 29))),
          LumpSource(
            'TEXTURE1',
            _textureDirectory(<_TextureSpec>[
              const _TextureSpec('OVERRIDE', 16, 24, 0),
            ]),
          ),
        ], kind: WadKind.iwad),
      );
      final WadFile pwad = WadFile.parse(
        buildWad(<LumpSource>[
          LumpSource(
            'TEXTURE1',
            _textureDirectory(<_TextureSpec>[
              const _TextureSpec('OVERRIDE', 32, 40, 1),
            ]),
          ),
        ]),
      );

      final WadResources res = WadResources.load(WadSet(<WadFile>[iwad, pwad]));
      expect(
        (res.textureDef('OVERRIDE')!.width, res.textureDef('OVERRIDE')!.height),
        (32, 40),
      );
      expect(res.composite('OVERRIDE')!.indexAt(0, 0), 29);
    });
  });

  group('composite', () {
    test('single-patch texture reproduces the patch pixels', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      final PatchImage composed = res.composite('WALL1')!;
      final PatchImage source = buildFixturePatch('PAT1');
      expect(composed.width, 64);
      expect(composed.height, 128);
      expect(composed.indices, source.indices);
      expect(composed.isFullyOpaque, isTrue);
    });

    test(
      'generated sky panorama is opaque and has diagnostic bands and columns',
      () {
        final WadResources res = WadResources.load(DoomFixtures.wadSet());
        final PatchImage composed = res.composite('SKY1')!;
        final PatchImage source = buildFixturePatch('SKYPAN');
        expect(composed.width, 256);
        expect(composed.height, 128);
        expect(composed.isFullyOpaque, isTrue);
        expect(composed.indices, source.indices);
        expect(composed.indexAt(0, 0), isNot(composed.indexAt(16, 0)));
        expect(composed.indexAt(0, 0), isNot(composed.indexAt(0, 16)));
        expect(composed.indexAt(0, 0), isNot(composed.indexAt(240, 112)));
      },
    );

    test('two-patch texture places each patch at its origin', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      final PatchImage composed = res.composite('WALL2')!;
      final PatchImage left = buildFixturePatch('PAT1');
      final PatchImage right = buildFixturePatch('PAT2');
      expect(composed.width, 128);
      for (var y = 0; y < 128; y++) {
        expect(
          composed.indexAt(0, y),
          left.indexAt(0, y),
          reason: 'left column row $y',
        );
        expect(
          composed.indexAt(63, y),
          left.indexAt(63, y),
          reason: 'left edge row $y',
        );
        expect(
          composed.indexAt(64, y),
          right.indexAt(0, y),
          reason: 'right column row $y',
        );
        expect(
          composed.indexAt(127, y),
          right.indexAt(63, y),
          reason: 'right edge row $y',
        );
      }
    });

    test('masked patch leaves holes transparent', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      final PatchImage composed = res.composite('WALL3')!;
      final PatchImage source = buildFixturePatch('PAT3');
      expect(composed.isFullyOpaque, isFalse);
      expect(composed.coverage, source.coverage);
    });

    test('clips patches that hang off both edges of the canvas', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      final PatchImage composed = res.composite('WALLOVR')!;
      final PatchImage tile = buildFixturePatch('PAT4');
      expect(composed.width, 96);
      expect(composed.height, 64);
      // Patch 0 sits at x = -16, so canvas x maps to patch x + 16.
      for (var y = 0; y < 64; y++) {
        expect(composed.coverageAt(0, y), tile.coverageAt(16, y));
      }
      // Patch 1 sits at x = 48 and runs to 112, past the 96 wide canvas.
      expect(composed.coverageAt(95, 32), tile.coverageAt(47, 32));
      // Nothing wrote outside the canvas.
      expect(composed.indices.length, 96 * 64);
    });

    test('is memoised, returning the identical instance', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      expect(identical(res.composite('WALL1'), res.composite('WALL1')), isTrue);
    });

    test('honours maxCompositePixels when reading the texture directory', () {
      expect(
        () => WadResources.load(
          DoomFixtures.wadSet(),
          limits: const DoomLimits(maxCompositePixels: 64),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxCompositePixels',
          ),
        ),
      );
    });

    test('honours maxTextures', () {
      expect(
        () => WadResources.load(
          DoomFixtures.wadSet(),
          limits: const DoomLimits(maxTextures: 2),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxTextures',
          ),
        ),
      );
    });

    test('honours maxPatchesPerTexture', () {
      expect(
        () => WadResources.load(
          DoomFixtures.wadSet(),
          limits: const DoomLimits(maxPatchesPerTexture: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxPatchesPerTexture',
          ),
        ),
      );
    });

    test('honours maxPatchNames', () {
      expect(
        () => WadResources.load(
          DoomFixtures.wadSet(),
          limits: const DoomLimits(maxPatchNames: 2),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxPatchNames',
          ),
        ),
      );
    });

    test('rejects a texture referencing a patch outside PNAMES', () {
      // One PNAMES entry, but the texture asks for index 3.
      final Uint8List pnames = Uint8List(4 + 8);
      ByteData.sublistView(pnames).setInt32(0, 1, Endian.little);

      final Uint8List texture = Uint8List(4 + 4 + 22 + 10);
      final ByteData view = ByteData.sublistView(texture);
      view.setInt32(0, 1, Endian.little);
      view.setInt32(4, 8, Endian.little);
      view.setInt16(8 + 12, 16, Endian.little);
      view.setInt16(8 + 14, 16, Endian.little);
      view.setInt16(8 + 20, 1, Endian.little);
      view.setInt16(8 + 22 + 4, 3, Endian.little);

      expect(
        () => WadResources.load(
          setWith(<LumpSource>[
            LumpSource('PNAMES', pnames),
            LumpSource('TEXTURE1', texture),
          ]),
        ),
        throwsA(
          isA<DoomFormatFailure>().having(
            (DoomFormatFailure f) => f.message,
            'message',
            contains('PNAMES'),
          ),
        ),
      );
    });
  });

  group('flats and sprites', () {
    test('finds flats between F_START and F_END', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      expect(res.flatNames, DoomFixtures.flatNames.toList()..sort());

      final FlatImage floor = res.flat('FLOOR0')!;
      expect(floor.width, 64);
      expect(floor.height, 64);
      expect(floor.indices.length, 4096);
      expect(floor.indices, buildFixtureFlat('FLOOR0'));
      expect(floor.isSky, isFalse);
      expect(res.flat('F_SKY1')!.isSky, isTrue);
    });

    test('flat lookup is case insensitive and rejects the no-texture name', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      expect(res.flat('floor0'), isNotNull);
      expect(res.flat('-'), isNull);
      expect(res.flat('NOSUCHFLAT'), isNull);
      expect(identical(res.flat('FLOOR0'), res.flat('FLOOR0')), isTrue);
    });

    test('accepts the FF_START and F1_START marker variants', () {
      final WadSet set = setWith(<LumpSource>[
        LumpSource.marker('FF_START'),
        LumpSource('MYFLAT', buildFixtureFlat('FLAT1')),
        LumpSource.marker('FF_END'),
        LumpSource.marker('F1_START'),
        LumpSource('OTHFLAT', buildFixtureFlat('FLOOR0')),
        LumpSource.marker('F1_END'),
      ]);
      final WadResources res = WadResources.load(set);
      expect(res.flatNames, containsAll(<String>['MYFLAT', 'OTHFLAT']));
      expect(res.flat('MYFLAT'), isNotNull);
    });

    test('finds sprites between S_START and S_END', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      expect(res.spriteNames.length, DoomFixtures.spriteNames.length);
      expect(res.spriteNames, containsAll(DoomFixtures.spriteNames));

      final PatchImage sprite = res.sprite('TESTA0')!;
      expect(sprite.width, 64);
      expect(sprite.height, 64);
      expect(sprite.leftOffset, 32);
      expect(sprite.topOffset, 60);
      expect(sprite.isFullyOpaque, isFalse);
      expect(sprite.coverage, buildFixtureSprite('TESTA0').coverage);
    });

    test(
      'generated gameplay sprites decode distinctly with useful offsets',
      () {
        final WadResources res = WadResources.load(DoomFixtures.wadSet());
        final Set<int> fingerprints = <int>{};
        for (final String name in DoomFixtures.spriteNames) {
          expect(name.length, lessThanOrEqualTo(8), reason: name);
          expect(name, name.toUpperCase(), reason: name);
          final PatchImage decoded = res.sprite(name)!;
          final PatchImage generated = buildFixtureSprite(name);
          expect(decoded.indices, generated.indices, reason: '$name indices');
          expect(
            decoded.coverage,
            generated.coverage,
            reason: '$name coverage',
          );
          expect(decoded.isFullyOpaque, isFalse, reason: '$name cutout');
          expect(decoded.coverage, contains(0), reason: '$name transparency');
          expect(
            decoded.coverage,
            contains(255),
            reason: '$name opaque pixels',
          );
          fingerprints.add(
            fnv1a64(
              Uint8List.fromList(<int>[
                decoded.width,
                decoded.height,
                decoded.leftOffset,
                decoded.topOffset,
                ...decoded.indices,
                ...decoded.coverage,
              ]),
            ),
          );
        }
        expect(fingerprints.length, DoomFixtures.spriteNames.length);

        for (final String name in <String>[
          'POSSA0',
          'SPOSA0',
          'TROOA0',
          'BAR1A0',
          'BEXPA0',
          'BAL1A0',
          'PUFFA0',
          'BLUDA0',
        ]) {
          final PatchImage sprite = res.sprite(name)!;
          expect((sprite.width, sprite.height), (64, 64), reason: name);
          expect((sprite.leftOffset, sprite.topOffset), (32, 60), reason: name);
        }
        for (final String name in <String>[
          'CLIPA0',
          'SHOTA0',
          'STIMA0',
          'ARM1A0',
          'BON1A0',
          'BON2A0',
          'SHELA0',
        ]) {
          final PatchImage sprite = res.sprite(name)!;
          expect((sprite.width, sprite.height), (40, 40), reason: name);
          expect((sprite.leftOffset, sprite.topOffset), (20, 36), reason: name);
        }
        for (final String name in <String>[
          'PISGA0',
          'PUNGA0',
          'SHTGA0',
          'CHGGA0',
        ]) {
          final PatchImage sprite = res.sprite(name)!;
          expect((sprite.width, sprite.height), (96, 64), reason: name);
          expect((sprite.leftOffset, sprite.topOffset), (48, 64), reason: name);
        }
      },
    );

    test(
      'sprite lookup is case insensitive, memoised and namespace scoped',
      () {
        final WadResources res = WadResources.load(DoomFixtures.wadSet());
        expect(res.sprite('testa0'), isNotNull);
        expect(identical(res.sprite('TESTA0'), res.sprite('TESTA0')), isTrue);
        // PLAYPAL is a real lump but lives outside S_START/S_END.
        expect(res.sprite('PLAYPAL'), isNull);
        expect(res.sprite('NOSUCHSPRITE'), isNull);
        expect(res.sprite(''), isNull);
      },
    );

    test('accepts the SS_START marker variant', () {
      final WadSet set = setWith(<LumpSource>[
        LumpSource.marker('SS_START'),
        LumpSource('MYSPRA0', encodeDoomPatch(buildFixtureSprite('TESTB0'))),
        LumpSource.marker('SS_END'),
      ]);
      expect(WadResources.load(set).sprite('MYSPRA0'), isNotNull);
    });

    test('a PWAD flat overrides an IWAD flat of the same name', () {
      final WadFile iwad = WadFile.parse(
        buildWad(<LumpSource>[
          LumpSource('PLAYPAL', buildFixturePlaypal()),
          LumpSource('COLORMAP', buildFixtureColormap()),
          LumpSource.marker('F_START'),
          LumpSource('SHAREDF', buildFixtureFlat('FLOOR0')),
          LumpSource.marker('F_END'),
        ], kind: WadKind.iwad),
      );
      final WadFile pwad = WadFile.parse(
        buildWad(<LumpSource>[
          LumpSource.marker('F_START'),
          LumpSource('SHAREDF', buildFixtureFlat('FLAT1')),
          LumpSource.marker('F_END'),
        ]),
      );
      final WadResources res = WadResources.load(WadSet(<WadFile>[iwad, pwad]));
      expect(res.flat('SHAREDF')!.indices, buildFixtureFlat('FLAT1'));
    });
  });
}

class _TextureSpec {
  const _TextureSpec(this.name, this.width, this.height, this.patch);

  final String name;
  final int width;
  final int height;
  final int patch;
}

Uint8List _pnames(List<String> names) {
  final Uint8List bytes = Uint8List(4 + names.length * 8);
  final ByteData data = ByteData.sublistView(bytes);
  data.setInt32(0, names.length, Endian.little);
  for (var i = 0; i < names.length; i++) {
    encodeLumpName(bytes, 4 + i * 8, names[i]);
  }
  return bytes;
}

Uint8List _textureDirectory(List<_TextureSpec> textures) {
  const int headerBytes = 22;
  const int patchBytes = 10;
  final int first = 4 + textures.length * 4;
  final Uint8List bytes = Uint8List(
    first + textures.length * (headerBytes + patchBytes),
  );
  final ByteData data = ByteData.sublistView(bytes);
  data.setInt32(0, textures.length, Endian.little);
  var offset = first;
  for (var i = 0; i < textures.length; i++) {
    final _TextureSpec texture = textures[i];
    data.setInt32(4 + i * 4, offset, Endian.little);
    encodeLumpName(bytes, offset, texture.name);
    data.setInt16(offset + 12, texture.width, Endian.little);
    data.setInt16(offset + 14, texture.height, Endian.little);
    data.setInt16(offset + 20, 1, Endian.little);
    data.setInt16(offset + headerBytes + 4, texture.patch, Endian.little);
    offset += headerBytes + patchBytes;
  }
  return bytes;
}

PatchImage _solidPatch(int width, int height, int index) => PatchImage(
  width: width,
  height: height,
  leftOffset: 0,
  topOffset: 0,
  indices: Uint8List(width * height)..fillRange(0, width * height, index),
  coverage: Uint8List(width * height)..fillRange(0, width * height, 255),
);
