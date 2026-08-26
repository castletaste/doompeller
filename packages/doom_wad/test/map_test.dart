import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

/// Rebuilds the fixture WAD with one map lump replaced, so a single malformed
/// structure can be tested without hand-writing a whole level.
WadSet fixtureWithLump(String lumpName, Uint8List replacement) {
  final WadFile original = DoomFixtures.wad();
  final List<LumpSource> lumps = <LumpSource>[];
  for (var i = 0; i < original.length; i++) {
    final LumpEntry entry = original.lumps[i];
    lumps.add(
      entry.name == lumpName
          ? LumpSource(entry.name, replacement)
          : LumpSource(entry.name, original.lumpBytes(i)),
    );
  }
  return WadSet(<WadFile>[WadFile.parse(buildWad(lumps))]);
}

/// Copy of a fixture map lump, for targeted corruption.
Uint8List lumpCopy(String lumpName) {
  final WadSet set = DoomFixtures.wadSet();
  return Uint8List.fromList(set.read(lumpName)!);
}

void main() {
  group('MapData.load', () {
    test('reads every lump of the fixture map', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');

      expect(map.name, 'MAP01');
      expect(map.sectors.length, 5);
      expect(map.things.length, 26);
      expect(map.vertices, isNotEmpty);
      expect(map.linedefs, isNotEmpty);
      expect(map.sidedefs, isNotEmpty);
      expect(map.hasBsp, isTrue);
      expect(map.blockmap, isNotNull);
      expect(map.reject, isNotNull);
      expect(map.bspRoot, map.nodes.length - 1);
    });

    test('map name lookup is case insensitive', () {
      expect(MapData.load(DoomFixtures.wadSet(), 'map01').name, 'MAP01');
    });

    test('reports a missing map', () {
      expect(
        () => MapData.load(DoomFixtures.wadSet(), 'MAP99'),
        throwsA(isA<DoomMissingLumpFailure>()),
      );
    });

    test('sector fields survive the round trip', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      expect(map.sectors[0].floorHeight, 0);
      expect(map.sectors[0].ceilingHeight, 128);
      expect(map.sectors[0].floorFlat, 'NUKAGE1');
      expect(map.sectors[0].lightLevel, 192);
      // Sector 2 sits below the others, exercising negative floor heights.
      expect(map.sectors[2].floorHeight, -32);
      // Sector 4 is the sky room.
      expect(map.sectors[4].ceilingIsSky, isTrue);
      expect(map.sectors[0].ceilingIsSky, isFalse);
      // Sector 1 starts as the closed tag-0 manual door.
      expect(map.sectors[1].floorHeight, 16);
      expect(map.sectors[1].ceilingHeight, 16);
    });

    test('two-sided linedefs keep both sidedefs and differing heights', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final Iterable<Linedef> portals = map.linedefs.where(
        (Linedef l) => l.isTwoSided,
      );
      expect(portals, isNotEmpty);

      var withStep = 0;
      for (final Linedef line in portals) {
        expect(line.leftSidedef, isNot(kNoSidedef));
        expect(line.rightSidedef, isNot(kNoSidedef));
        final Sector front =
            map.sectors[map.sidedefs[line.rightSidedef].sector];
        final Sector back = map.sectors[map.sidedefs[line.leftSidedef].sector];
        if (front.floorHeight != back.floorHeight ||
            front.ceilingHeight != back.ceilingHeight) {
          withStep++;
        }
      }
      expect(
        withStep,
        greaterThan(0),
        reason: 'fixture must exercise upper and lower wall bands',
      );
    });

    test('one-sided linedefs report no left sidedef', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final Iterable<Linedef> solid = map.linedefs.where(
        (Linedef l) => !l.isTwoSided,
      );
      expect(solid, isNotEmpty);
      for (final Linedef line in solid) {
        expect(line.leftSidedef, kNoSidedef);
        expect(line.rightSidedef, isNot(kNoSidedef));
      }
    });

    test('things carry position, angle, type and flags', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final Thing start = map.things.first;
      expect(start.type, 1); // player 1 start
      expect(start.x, 128);
      expect(start.y, 128);
      expect(start.angle, 90);
      expect(start.flags & ThingFlags.easy, isNot(0));
    });

    test('fixture exposes the supported enemy and pickup roster', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      expect(
        map.things.map((Thing thing) => thing.type).toSet(),
        containsAll(<int>{
          1,
          2,
          9,
          3001,
          3004,
          2035,
          2001,
          2007,
          2008,
          2011,
          2014,
          2015,
          2018,
        }),
      );
      expect(map.things.every((Thing thing) => thing.flags == 7), isTrue);
    });

    test('sector 0 portal is a closed tag-0 manual door', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final Linedef door = map.linedefs.singleWhere((Linedef line) {
        if (!line.isTwoSided || line.special != 1 || line.tag != 0) {
          return false;
        }
        final Sidedef front = map.sidedefs[line.rightSidedef];
        final Sidedef back = map.sidedefs[line.leftSidedef];
        return front.sector == 0 && back.sector == 1;
      });
      final MapVertex from = map.vertices[door.v1];
      final MapVertex to = map.vertices[door.v2];
      expect((from.x, from.y), (256, 256));
      expect((to.x, to.y), (256, 0));
      expect(map.sectors[1].ceilingHeight, map.sectors[1].floorHeight);
    });

    test('sky-room east wall is a front-facing S1 exit switch', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final Linedef exit = map.linedefs.singleWhere(
        (Linedef line) => line.special == 11,
      );
      final MapVertex from = map.vertices[exit.v1];
      final MapVertex to = map.vertices[exit.v2];
      expect((from.x, from.y), (1024, 256));
      expect((to.x, to.y), (1024, 0));
      expect(exit.isTwoSided, isFalse);
      expect(exit.leftSidedef, kNoSidedef);
      expect(map.sidedefs[exit.rightSidedef].sector, 4);
    });
  });

  group('reference validation', () {
    test('rejects a linedef pointing at a missing vertex', () {
      final Uint8List linedefs = lumpCopy('LINEDEFS');
      ByteData.sublistView(linedefs).setUint16(0, 9999, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('LINEDEFS', linedefs), 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('v1'),
          ),
        ),
      );
    });

    test('rejects a linedef pointing at a missing sidedef', () {
      final Uint8List linedefs = lumpCopy('LINEDEFS');
      ByteData.sublistView(linedefs).setUint16(10, 4000, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('LINEDEFS', linedefs), 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('sidedef'),
          ),
        ),
      );
    });

    test('rejects a linedef with no sidedef on either side', () {
      final Uint8List linedefs = lumpCopy('LINEDEFS');
      ByteData.sublistView(linedefs).setUint16(10, 0xFFFF, Endian.little);
      ByteData.sublistView(linedefs).setUint16(12, 0xFFFF, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('LINEDEFS', linedefs), 'MAP01'),
        throwsA(isA<DoomMapFailure>()),
      );
    });

    test('rejects a sidedef pointing at a missing sector', () {
      final Uint8List sidedefs = lumpCopy('SIDEDEFS');
      ByteData.sublistView(sidedefs).setInt16(28, 77, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('SIDEDEFS', sidedefs), 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('sector'),
          ),
        ),
      );
    });

    test('rejects a seg pointing at a missing linedef', () {
      final Uint8List segs = lumpCopy('SEGS');
      ByteData.sublistView(segs).setUint16(6, 5000, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('SEGS', segs), 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('linedef'),
          ),
        ),
      );
    });

    test('rejects a seg with an impossible side', () {
      final Uint8List segs = lumpCopy('SEGS');
      ByteData.sublistView(segs).setUint16(8, 7, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('SEGS', segs), 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('side'),
          ),
        ),
      );
    });

    test('rejects a subsector whose seg run overflows SEGS', () {
      final Uint8List ssectors = lumpCopy('SSECTORS');
      ByteData.sublistView(ssectors).setUint16(0, 9000, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('SSECTORS', ssectors), 'MAP01'),
        throwsA(isA<DoomMapFailure>()),
      );
    });

    test('rejects an empty subsector', () {
      final Uint8List ssectors = lumpCopy('SSECTORS');
      ByteData.sublistView(ssectors).setUint16(0, 0, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('SSECTORS', ssectors), 'MAP01'),
        throwsA(isA<DoomMapFailure>()),
      );
    });

    test('rejects a node child pointing outside NODES', () {
      final Uint8List nodes = lumpCopy('NODES');
      // Clear the subsector bit so it reads as a node index, then overflow it.
      ByteData.sublistView(nodes).setUint16(24, 900, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('NODES', nodes), 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('node'),
          ),
        ),
      );
    });

    test('rejects a node child pointing outside SSECTORS', () {
      final Uint8List nodes = lumpCopy('NODES');
      ByteData.sublistView(
        nodes,
      ).setUint16(24, kSubsectorBit | 800, Endian.little);
      expect(
        () => MapData.load(fixtureWithLump('NODES', nodes), 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('subsector'),
          ),
        ),
      );
    });

    test(
      'rejects a lump whose length is not a multiple of its record size',
      () {
        final Uint8List vertexes = lumpCopy('VERTEXES');
        expect(
          () => MapData.load(
            fixtureWithLump(
              'VERTEXES',
              Uint8List.sublistView(vertexes, 0, vertexes.length - 1),
            ),
            'MAP01',
          ),
          throwsA(
            isA<DoomMapFailure>().having(
              (DoomMapFailure f) => f.message,
              'message',
              contains('multiple'),
            ),
          ),
        );
      },
    );

    test('rejects a Hexen-format map', () {
      final WadSet set = WadSet(<WadFile>[
        WadFile.parse(
          buildWad(<LumpSource>[
            LumpSource.marker('MAP01'),
            LumpSource('THINGS', Uint8List(0)),
            LumpSource('LINEDEFS', Uint8List(0)),
            LumpSource('SIDEDEFS', Uint8List(0)),
            LumpSource('VERTEXES', Uint8List(0)),
            LumpSource('SECTORS', Uint8List(0)),
            LumpSource('BEHAVIOR', Uint8List(4)),
          ]),
        ),
      ]);
      expect(
        () => MapData.load(set, 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('Hexen'),
          ),
        ),
      );
    });

    test('reports a map missing a mandatory lump', () {
      final WadSet set = WadSet(<WadFile>[
        WadFile.parse(
          buildWad(<LumpSource>[
            LumpSource.marker('MAP01'),
            LumpSource('THINGS', Uint8List(0)),
          ]),
        ),
      ]);
      expect(
        () => MapData.load(set, 'MAP01'),
        throwsA(
          isA<DoomMapFailure>().having(
            (DoomMapFailure f) => f.message,
            'message',
            contains('LINEDEFS'),
          ),
        ),
      );
    });
  });

  group('map limits', () {
    test('maxVertices produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxVertices: 2),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxVertices',
          ),
        ),
      );
    });

    test('maxSectors produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxSectors: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxSectors',
          ),
        ),
      );
    });

    test('maxSidedefs produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxSidedefs: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxSidedefs',
          ),
        ),
      );
    });

    test('maxLinedefs produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxLinedefs: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxLinedefs',
          ),
        ),
      );
    });

    test('maxSegs produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxSegs: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxSegs',
          ),
        ),
      );
    });

    test('maxSubsectors produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxSubsectors: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxSubsectors',
          ),
        ),
      );
    });

    test('maxNodes produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxNodes: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxNodes',
          ),
        ),
      );
    });

    test('maxThings produces a typed limit failure', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxThings: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxThings',
          ),
        ),
      );
    });

    test('maxBlockmapCells propagates through MapData.load', () {
      expect(
        () => MapData.load(
          DoomFixtures.wadSet(),
          'MAP01',
          limits: const DoomLimits(maxBlockmapCells: 1),
        ),
        throwsA(
          isA<DoomLimitFailure>().having(
            (DoomLimitFailure f) => f.limitName,
            'limitName',
            'maxBlockmapCells',
          ),
        ),
      );
    });
  });

  group('blockmap', () {
    test('parses the fixture blockmap and indexes its cells', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final Blockmap blockmap = map.blockmap!;

      expect(blockmap.columns, greaterThan(0));
      expect(blockmap.rows, greaterThan(0));
      expect(blockmap.cells.length, blockmap.columns * blockmap.rows);

      var populated = 0;
      for (final Uint16List cell in blockmap.cells) {
        for (final int line in cell) {
          expect(line, lessThan(map.linedefs.length));
        }
        if (cell.isNotEmpty) {
          populated++;
        }
      }
      expect(populated, greaterThan(0));

      expect(blockmap.cellAt(0, 0), isNotNull);
      expect(blockmap.cellAt(-1, 0), isNull);
      expect(blockmap.cellAt(0, blockmap.rows), isNull);
      expect(blockmap.cellAt(blockmap.columns, 0), isNull);
    });

    test('every linedef appears in at least one cell', () {
      final MapData map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
      final Set<int> seen = <int>{};
      for (final Uint16List cell in map.blockmap!.cells) {
        seen.addAll(cell);
      }
      expect(seen.length, map.linedefs.length);
    });

    test('a truncated blockmap yields null rather than failing the map', () {
      final Uint8List blockmap = lumpCopy('BLOCKMAP');
      final MapData map = MapData.load(
        fixtureWithLump('BLOCKMAP', Uint8List.sublistView(blockmap, 0, 16)),
        'MAP01',
      );
      expect(map.blockmap, isNull);
      expect(
        map.sectors,
        isNotEmpty,
        reason: 'the rest of the map must still load',
      );
    });

    test('an odd-length blockmap yields null', () {
      expect(parseBlockmap(Uint8List(9), 4), isNull);
    });

    test('a blockmap with zero columns or rows yields null', () {
      final Uint8List lump = Uint8List(16);
      final ByteData view = ByteData.sublistView(lump);
      view.setUint16(4, 0, Endian.little);
      view.setUint16(6, 4, Endian.little);
      expect(parseBlockmap(lump, 4), isNull);
    });

    test(
      'huge dimensions in a tiny lump yield null before the cell budget',
      () {
        final Uint8List lump = Uint8List(8);
        final ByteData view = ByteData.sublistView(lump);
        view.setUint16(4, 0xFFFF, Endian.little);
        view.setUint16(6, 0xFFFF, Endian.little);

        expect(
          parseBlockmap(lump, 4, limits: const DoomLimits(maxBlockmapCells: 1)),
          isNull,
        );
      },
    );

    test(
      'a valid-shaped blockmap over the cell budget fails with a typed limit',
      () {
        final List<int> words = <int>[0, 0, 1, 1, 5, 0, 0xFFFF];
        final Uint8List lump = Uint8List(words.length * 2);
        final ByteData view = ByteData.sublistView(lump);
        for (var i = 0; i < words.length; i++) {
          view.setUint16(i * 2, words[i], Endian.little);
        }

        expect(
          () => parseBlockmap(
            lump,
            4,
            limits: const DoomLimits(maxBlockmapCells: 0),
          ),
          throwsA(
            isA<DoomLimitFailure>().having(
              (DoomLimitFailure f) => f.limitName,
              'limitName',
              'maxBlockmapCells',
            ),
          ),
        );
      },
    );

    test(
      'a valid-shaped blockmap over the entry budget fails with a typed limit',
      () {
        final List<int> words = <int>[0, 0, 1, 1, 5, 0, 0xFFFF];
        final Uint8List lump = Uint8List(words.length * 2);
        final ByteData view = ByteData.sublistView(lump);
        for (var i = 0; i < words.length; i++) {
          view.setUint16(i * 2, words[i], Endian.little);
        }

        expect(
          () => parseBlockmap(
            lump,
            4,
            limits: const DoomLimits(maxBlockmapEntries: 1),
          ),
          throwsA(
            isA<DoomLimitFailure>().having(
              (DoomLimitFailure f) => f.limitName,
              'limitName',
              'maxBlockmapEntries',
            ),
          ),
        );
      },
    );

    test('an unterminated cell list yields null', () {
      // One cell whose list runs to the end of the lump with no 0xFFFF.
      final Uint8List lump = Uint8List(16);
      final ByteData view = ByteData.sublistView(lump);
      view.setInt16(0, 0, Endian.little);
      view.setInt16(2, 0, Endian.little);
      view.setUint16(4, 1, Endian.little);
      view.setUint16(6, 1, Endian.little);
      view.setUint16(8, 5, Endian.little); // offset word 5
      view.setUint16(10, 0, Endian.little);
      view.setUint16(12, 0, Endian.little);
      view.setUint16(14, 0, Endian.little);
      expect(parseBlockmap(lump, 4), isNull);
    });

    test('an offset that overflowed into the header leaves the cell empty', () {
      // Two cells; the second points back into the offset table, which is what
      // the 16-bit overflow in large vanilla maps looks like.
      final List<int> words = <int>[
        0, 0, 2, 1, // origin and dimensions
        6, 2, //      offsets: cell 0 valid, cell 1 wrapped into the header
        0, 0xFFFF, // cell 0 list: pad then terminator
      ];
      final Uint8List lump = Uint8List(words.length * 2);
      final ByteData view = ByteData.sublistView(lump);
      for (var i = 0; i < words.length; i++) {
        view.setUint16(i * 2, words[i], Endian.little);
      }
      final Blockmap? blockmap = parseBlockmap(lump, 8);
      expect(blockmap, isNotNull);
      expect(blockmap!.cellAt(0, 0), isEmpty);
      expect(blockmap.cellAt(1, 0), isEmpty);
    });

    test('drops linedef references the map cannot satisfy', () {
      final List<int> words = <int>[
        0, 0, 1, 1,
        5,
        0, 3, 99, 0xFFFF, // 3 is valid, 99 is not
      ];
      final Uint8List lump = Uint8List(words.length * 2);
      final ByteData view = ByteData.sublistView(lump);
      for (var i = 0; i < words.length; i++) {
        view.setUint16(i * 2, words[i], Endian.little);
      }
      final Blockmap? blockmap = parseBlockmap(lump, 8);
      expect(blockmap, isNotNull);
      expect(blockmap!.cellAt(0, 0), <int>[3]);
    });

    test('tolerates a cell list with no leading pad word', () {
      final List<int> words = <int>[
        0, 0, 1, 1,
        5,
        2, 0xFFFF, // no 0x0000 pad, straight into linedef 2
      ];
      final Uint8List lump = Uint8List(words.length * 2);
      final ByteData view = ByteData.sublistView(lump);
      for (var i = 0; i < words.length; i++) {
        view.setUint16(i * 2, words[i], Endian.little);
      }
      expect(parseBlockmap(lump, 8)!.cellAt(0, 0), <int>[2]);
    });
  });
}
