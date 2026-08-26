import 'dart:typed_data';

import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

/// Sector the seg's own side faces.
int sectorOfSeg(MapData map, Seg seg) {
  final Linedef line = map.linedefs[seg.linedef];
  final int side = seg.side == 0 ? line.rightSidedef : line.leftSidedef;
  return side == kNoSidedef ? -1 : map.sidedefs[side].sector;
}

/// Descends the BSP to the subsector containing (x, y).
int subsectorAt(MapData map, int x, int y) {
  var child = map.nodes.length - 1;
  var guard = 0;
  while ((child & kSubsectorBit) == 0) {
    expect(guard++, lessThan(1000), reason: 'BSP descent must terminate');
    final BspNode node = map.nodes[child];
    final int side = (x - node.x) * node.dy - (y - node.y) * node.dx;
    child = side >= 0 ? node.rightChild : node.leftChild;
  }
  return child & ~kSubsectorBit;
}

void main() {
  group('fixture WAD', () {
    test('caches one deterministic build', () {
      expect(
        identical(DoomFixtures.pwadBytes(), DoomFixtures.pwadBytes()),
        isTrue,
      );
      expect(DoomFixtures.hash(), DoomFixtures.hash());
    });

    test('has the expected content hash', () {
      // Update this only with a deliberate fixture change: it is the tripwire
      // for accidental drift in the generator, the encoder or the BSP builder.
      // Removing seven impossible weapon lamps deliberately changes the bytes.
      expect(DoomFixtures.hash(), 0x038a0b410fcfa3aa);
    });

    test('parses as a PWAD with the expected structure', () {
      final WadFile wad = DoomFixtures.wad();
      expect(wad.kind, WadKind.pwad);
      expect(DoomFixtures.pwadBytes().lengthInBytes, 434551);
      expect(wad.length, 162);
      expect(DoomFixtures.wadSet().mapNames(), <String>['MAP01']);
    });

    test('contains no commercial lump names', () {
      // A cheap guard against someone dropping real Doom lumps into the
      // generator: none of these names may ever appear.
      const List<String> forbidden = <String>[
        'E1M1',
        'DEMO1',
        'STBAR',
        'TITLEPIC',
        'D_E1M1',
        'ENDOOM',
        'DPHOOF',
        'HELP1',
      ];
      final WadFile wad = DoomFixtures.wad();
      final Set<String> names = <String>{
        for (final LumpEntry entry in wad.lumps) entry.name,
      };
      for (final String name in forbidden) {
        expect(names, isNot(contains(name)));
      }
    });

    test('weapon fixture contains only real body lamps', () {
      expect(
        DoomFixtures.spriteNames.where(
          (String name) => const <String>{
            'PUNG',
            'PISG',
            'SHTG',
            'CHGG',
          }.contains(name.substring(0, 4)),
        ),
        <String>[
          'PUNGA0',
          'PUNGB0',
          'PUNGC0',
          'PUNGD0',
          'PISGA0',
          'PISGB0',
          'PISGC0',
          'SHTGA0',
          'SHTGB0',
          'SHTGC0',
          'SHTGD0',
          'CHGGA0',
          'CHGGB0',
        ],
      );
    });

    test('every lump is reachable and within bounds', () {
      final WadFile wad = DoomFixtures.wad();
      for (var i = 0; i < wad.length; i++) {
        expect(wad.lumpBytes(i).lengthInBytes, wad.lumps[i].size);
      }
    });

    test('fully exercises WadResources', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      expect(res.playpal.length, 14);
      expect(res.colormap.length, 34);
      expect(res.textureNames.length, 11);
      expect(res.flatNames.length, 7);
      expect(res.spriteNames.length, DoomFixtures.spriteNames.length);
      expect(res.soundNames.length, DoomFixtures.soundNames.length);
      for (final String name in res.textureNames) {
        expect(res.composite(name), isNotNull, reason: name);
      }
      for (final String name in res.flatNames) {
        expect(res.flat(name), isNotNull, reason: name);
      }
      for (final String name in res.spriteNames) {
        expect(res.sprite(name), isNotNull, reason: name);
      }
      for (final String name in res.soundNames) {
        expect(res.sound(name), isNotNull, reason: name);
      }
      expect(res.music('D_TEST')?.isMus, isTrue);
      for (var i = 0; i < res.patchNames.length; i++) {
        expect(res.patchAt(i), isNotNull, reason: res.patchNames[i]);
      }
      expect(res.patchByName('PAT1'), isNotNull);
      expect(res.patchByName('SKYPAN'), isNotNull);
      expect(res.patchAt(-1), isNull);
      expect(res.patchAt(999), isNull);
    });
  });

  group('fixture map geometry', () {
    late MapData map;

    setUp(() {
      map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
    });

    test('has a convex sector, a concave sector, a hole and a sky ceiling', () {
      // Sector 0 is the plain box, sector 1 the L, sector 3 the island inside
      // sector 2, sector 4 the sky room.
      expect(map.sectors.length, 5);
      expect(map.sectors[4].ceilingIsSky, isTrue);
      expect(map.sectors.where((Sector s) => s.ceilingIsSky).length, 1);

      // The island's floor sits above the room containing it, which is what
      // makes the containing sector's floor a surface with a hole.
      expect(
        map.sectors[3].floorHeight,
        greaterThan(map.sectors[2].floorHeight),
      );

      // The L-shaped sector needs more than four walls to be concave.
      final Iterable<Linedef> walls = map.linedefs.where(
        (Linedef l) =>
            !l.isTwoSided && map.sidedefs[l.rightSidedef].sector == 1,
      );
      expect(walls.length, greaterThanOrEqualTo(4));
    });

    test('things occupy the intended valid sector polygons', () {
      const Map<int, int> expectedSectorByType = <int, int>{
        1: 0,
        2: 1,
        2014: 3,
        2015: 4,
        3004: 0,
        3001: 2,
        9: 4,
        2035: 4,
        2001: 0,
        2007: 0,
        2008: 2,
        2011: 4,
        2018: 4,
      };
      expect(map.things.length, expectedSectorByType.length);
      for (final Thing thing in map.things) {
        final int leaf = subsectorAt(map, thing.x, thing.y);
        final Subsector subsector = map.subsectors[leaf];
        final int sector = sectorOfSeg(map, map.segs[subsector.firstSeg]);
        expect(
          sector,
          expectedSectorByType[thing.type],
          reason: 'thing ${thing.type}',
        );
        expect(thing.flags, 7, reason: 'thing ${thing.type} skill flags');
      }
    });

    test('every sector is referenced by at least one sidedef', () {
      final Set<int> used = <int>{
        for (final Sidedef side in map.sidedefs) side.sector,
      };
      expect(used.length, map.sectors.length);
    });

    test(
      'every texture named by a sidedef resolves or is the no-texture name',
      () {
        final WadResources res = WadResources.load(DoomFixtures.wadSet());
        for (final Sidedef side in map.sidedefs) {
          for (final String name in <String>[
            side.upperTexture,
            side.lowerTexture,
            side.middleTexture,
          ]) {
            if (name == kNoTextureName) {
              continue;
            }
            expect(res.textureDef(name), isNotNull, reason: name);
          }
        }
      },
    );

    test('every flat named by a sector resolves', () {
      final WadResources res = WadResources.load(DoomFixtures.wadSet());
      for (final Sector sector in map.sectors) {
        expect(res.flat(sector.floorFlat), isNotNull, reason: sector.floorFlat);
        expect(
          res.flat(sector.ceilingFlat),
          isNotNull,
          reason: sector.ceilingFlat,
        );
      }
    });
  });

  group('fixture BSP tree', () {
    late MapData map;

    setUp(() {
      map = MapData.load(DoomFixtures.wadSet(), 'MAP01');
    });

    test('every subsector belongs to exactly one sector', () {
      // This is the defining property of a BSP leaf. If it fails, the tree does
      // not partition the map and everything built on it is wrong.
      for (var i = 0; i < map.subsectors.length; i++) {
        final Subsector ss = map.subsectors[i];
        final Set<int> sectors = <int>{
          for (var s = 0; s < ss.segCount; s++)
            sectorOfSeg(map, map.segs[ss.firstSeg + s]),
        };
        expect(sectors.length, 1, reason: 'subsector $i spans $sectors');
        expect(
          sectors.first,
          isNot(-1),
          reason: 'subsector $i has a seg with no sidedef',
        );
      }
    });

    test('every seg is claimed by exactly one subsector', () {
      final List<int> claims = List<int>.filled(map.segs.length, 0);
      for (final Subsector ss in map.subsectors) {
        for (var s = 0; s < ss.segCount; s++) {
          claims[ss.firstSeg + s]++;
        }
      }
      expect(claims.every((int c) => c == 1), isTrue);
    });

    test('point queries land in the sector the geometry says they should', () {
      // Each probe is x, y and the sector the point is inside.
      const List<List<int>> probes = <List<int>>[
        <int>[128, 128, 0], // convex room
        <int>[300, 64, 1], // L room, lower arm
        <int>[460, 60, 1], // L room, far arm
        <int>[540, 60, 2], // hole room, left of the island
        <int>[740, 220, 2], // hole room, above the island
        <int>[640, 128, 3], // on the island
        <int>[900, 128, 4], // sky room
      ];
      for (var i = 0; i < probes.length; i++) {
        final List<int> probe = probes[i];
        final int leaf = subsectorAt(map, probe[0], probe[1]);
        final Subsector sub = map.subsectors[leaf];
        final int sector = sectorOfSeg(map, map.segs[sub.firstSeg]);
        expect(sector, probe[2], reason: 'probe $i landed in subsector $leaf');
      }
    });

    test('every node child index is in range', () {
      for (final BspNode node in map.nodes) {
        if (node.rightIsSubsector) {
          expect(node.rightIndex, lessThan(map.subsectors.length));
        } else {
          expect(node.rightIndex, lessThan(map.nodes.length));
        }
        if (node.leftIsSubsector) {
          expect(node.leftIndex, lessThan(map.subsectors.length));
        } else {
          expect(node.leftIndex, lessThan(map.nodes.length));
        }
      }
    });

    test('node bounding boxes are well formed', () {
      for (final BspNode node in map.nodes) {
        for (final Int16List box in <Int16List>[node.rightBox, node.leftBox]) {
          // Stored as top, bottom, left, right.
          expect(box[0], greaterThanOrEqualTo(box[1]));
          expect(box[3], greaterThanOrEqualTo(box[2]));
        }
      }
    });

    test('no seg is degenerate', () {
      for (var i = 0; i < map.segs.length; i++) {
        final Seg seg = map.segs[i];
        final MapVertex a = map.vertices[seg.v1];
        final MapVertex b = map.vertices[seg.v2];
        expect(
          a.x == b.x && a.y == b.y,
          isFalse,
          reason: 'seg $i is zero length',
        );
      }
    });

    test('the root node is the last one, as the lump layout requires', () {
      expect(map.bspRoot, map.nodes.length - 1);
      expect(map.hasBsp, isTrue);
    });
  });

  group('buildBspTree', () {
    test('leaves an already convex set as a single subsector', () {
      // A square wound so every seg faces inward is convex, so no partition is
      // needed and the tree is one leaf with no nodes.
      const List<BspSeg> square = <BspSeg>[
        BspSeg(x1: 0, y1: 0, x2: 0, y2: 64, linedef: 0, side: 0),
        BspSeg(x1: 0, y1: 64, x2: 64, y2: 64, linedef: 1, side: 0),
        BspSeg(x1: 64, y1: 64, x2: 64, y2: 0, linedef: 2, side: 0),
        BspSeg(x1: 64, y1: 0, x2: 0, y2: 0, linedef: 3, side: 0),
      ];
      final BspTree tree = buildBspTree(square);
      expect(tree.nodes, isEmpty);
      expect(tree.subsectors.length, 1);
      expect(tree.segs.length, 4);
      expect(tree.rootChild & kBspSubsectorBit, isNot(0));
    });

    test('splits a set that is not convex', () {
      const List<BspSeg> input = <BspSeg>[
        BspSeg(x1: 0, y1: 0, x2: 0, y2: 64, linedef: 0, side: 0),
        BspSeg(x1: 0, y1: 64, x2: 64, y2: 64, linedef: 1, side: 0),
        BspSeg(x1: 64, y1: 64, x2: 64, y2: 0, linedef: 2, side: 0),
        BspSeg(x1: 64, y1: 0, x2: 0, y2: 0, linedef: 3, side: 0),
        // A wall through the middle, facing the other way.
        BspSeg(x1: 32, y1: 64, x2: 32, y2: 0, linedef: 4, side: 0),
      ];
      final BspTree tree = buildBspTree(input);
      expect(tree.nodes, isNotEmpty);
      expect(tree.subsectors.length, greaterThan(1));
    });

    test('is deterministic across runs', () {
      const List<BspSeg> input = <BspSeg>[
        BspSeg(x1: 0, y1: 0, x2: 0, y2: 64, linedef: 0, side: 0),
        BspSeg(x1: 0, y1: 64, x2: 64, y2: 64, linedef: 1, side: 0),
        BspSeg(x1: 64, y1: 64, x2: 64, y2: 0, linedef: 2, side: 0),
        BspSeg(x1: 64, y1: 0, x2: 0, y2: 0, linedef: 3, side: 0),
        BspSeg(x1: 32, y1: 64, x2: 32, y2: 0, linedef: 4, side: 0),
      ];
      final BspTree a = buildBspTree(input);
      final BspTree b = buildBspTree(input);
      expect(a.nodes.length, b.nodes.length);
      expect(a.subsectors.length, b.subsectors.length);
      expect(a.segs.length, b.segs.length);
      for (var i = 0; i < a.segs.length; i++) {
        expect(a.segs[i].x1, b.segs[i].x1);
        expect(a.segs[i].y1, b.segs[i].y1);
        expect(a.segs[i].linedef, b.segs[i].linedef);
      }
    });

    test('handles an empty input', () {
      final BspTree tree = buildBspTree(<BspSeg>[]);
      expect(tree.subsectors.length, 1);
      expect(tree.segs, isEmpty);
    });

    test('bamAngle maps the cardinal directions', () {
      expect(bamAngle(1, 0), 0);
      expect(bamAngle(0, 1), 16384);
      expect(bamAngle(-1, 0), 32768);
      expect(bamAngle(0, -1), 49152);
    });

    test('distanceBetween measures whole units', () {
      expect(distanceBetween(0, 0, 3, 4), 5);
      expect(distanceBetween(10, 10, 10, 10), 0);
    });
  });
}
