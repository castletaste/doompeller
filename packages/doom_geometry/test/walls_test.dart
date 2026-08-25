import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/synthetic_map.dart';

/// Wall bands and classic Doom texture alignment.
///
/// Pegging is the most visible thing to get wrong: a mis-pegged door track
/// slides with the door, and a mis-pegged step shows the wrong slice of its
/// texture. These tests pin the exact texel row each band starts at.
void main() {
  group('band selection', () {
    test('one-sided linedef makes exactly one solid band', () {
      final WallSet walls = _wallsOf(_simpleRoom());
      expect(walls.quads.length, 4);
      for (final WallQuad q in walls.quads) {
        expect(q.band, WallBandKind.solid);
        expect(q.kind, SurfaceKind.opaque);
        expect(q.backSector, -1);
        expect(q.bottom, 0);
        expect(q.top, 128);
      }
    });

    test('two-sided step makes a lower band on the low side only', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 32,
        lowCeil: 128,
        highCeil: 128,
      ));
      final List<WallQuad> lowers = walls.quads
          .where((WallQuad q) => q.band == WallBandKind.lower)
          .toList();
      expect(lowers.length, 1, reason: 'only the lower side sees the step');
      expect(lowers.single.bottom, 0);
      expect(lowers.single.top, 32);
      expect(
        walls.quads.where((WallQuad q) => q.band == WallBandKind.upper),
        isEmpty,
      );
    });

    test('two-sided ceiling drop makes an upper band', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 0,
        lowCeil: 128,
        highCeil: 96,
      ));
      final List<WallQuad> uppers = walls.quads
          .where((WallQuad q) => q.band == WallBandKind.upper)
          .toList();
      expect(uppers.length, 1);
      expect(uppers.single.bottom, 96);
      expect(uppers.single.top, 128);
    });

    test('upper between two sky ceilings is not drawn', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 0,
        lowCeil: 128,
        highCeil: 96,
        skyBoth: true,
      ));
      expect(
        walls.quads.where((WallQuad q) => q.band == WallBandKind.upper),
        isEmpty,
        reason: 'sky must run continuously across the boundary',
      );
      expect(walls.skippedSkyUppers, 1);
    });

    test('upper between sky and non-sky IS drawn', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 0,
        lowCeil: 128,
        highCeil: 96,
        skyFront: true,
      ));
      expect(
        walls.quads.where((WallQuad q) => q.band == WallBandKind.upper).length,
        1,
      );
      expect(walls.skippedSkyUppers, 0);
    });

    test('middle texture on a two-sided line is masked', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 0,
        lowCeil: 128,
        highCeil: 128,
        middle: 'MIDGRATE',
      ));
      final List<WallQuad> mids = walls.quads
          .where((WallQuad q) => q.band == WallBandKind.middle)
          .toList();
      expect(mids.length, 2, reason: 'both sides hang the same grate');
      for (final WallQuad m in mids) {
        expect(m.kind, SurfaceKind.masked);
      }
    });
  });

  group('texture alignment', () {
    test('x offset advances with distance along the linedef', () {
      final WallSet walls = _wallsOf(_simpleRoom(xOffset: 16));
      final WallQuad q = walls.quads.first;
      expect(q.uLeft, 16, reason: 'starts at the sidedef offset');
      expect(q.uRight, 16 + 256, reason: 'plus the linedef length');
    });

    test('one-sided pegged normally starts at the sidedef y offset', () {
      final WallSet walls = _wallsOf(_simpleRoom(yOffset: 8));
      expect(walls.quads.first.yOffset, 8);
    });

    test('one-sided lower-unpegged anchors the texture bottom at the floor',
        () {
      // Room is 128 tall, STARTAN3 is 128 tall, so an exact fit means the
      // unpegged anchor lands on the same row as the pegged one.
      final WallSet walls = _wallsOf(
        _simpleRoom(flags: LinedefFlags.lowerUnpegged),
      );
      expect(walls.quads.first.yOffset, 0);

      // A shorter room must shift the visible slice down by the difference, so
      // the texture's bottom row still sits on the floor.
      final WallSet shorter = _wallsOf(
        _simpleRoom(flags: LinedefFlags.lowerUnpegged, ceiling: 96),
      );
      expect(shorter.quads.first.yOffset, 128 - 96);
    });

    test('lower band pegged normally starts at the top of the step', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 32,
        lowCeil: 128,
        highCeil: 128,
      ));
      final WallQuad lower = walls.quads
          .firstWhere((WallQuad q) => q.band == WallBandKind.lower);
      expect(lower.yOffset, 0);
    });

    test('lower band lower-unpegged anchors at the near ceiling', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 32,
        lowCeil: 128,
        highCeil: 128,
        flags: LinedefFlags.lowerUnpegged,
      ));
      final WallQuad lower = walls.quads
          .firstWhere((WallQuad q) => q.band == WallBandKind.lower);
      // Texels counted from the near ceiling (128) down to the step top (32).
      expect(lower.yOffset, 128 - 32);
    });

    test('upper band pegged normally hangs from the far ceiling', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 0,
        lowCeil: 128,
        highCeil: 96,
      ));
      final WallQuad upper = walls.quads
          .firstWhere((WallQuad q) => q.band == WallBandKind.upper);
      // The band is 32 tall and STARTAN3 is 128, so the visible slice is the
      // texture's bottom 32 rows.
      expect(upper.yOffset, 128 - 32);
    });

    test('upper band upper-unpegged draws down from the near ceiling', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 0,
        lowCeil: 128,
        highCeil: 96,
        flags: LinedefFlags.upperUnpegged,
      ));
      final WallQuad upper = walls.quads
          .firstWhere((WallQuad q) => q.band == WallBandKind.upper);
      expect(upper.yOffset, 0, reason: 'top row of the texture at the top');
    });

    test('sidedef y offset adds on top of the pegging rule', () {
      final WallSet walls = _wallsOf(_twoRooms(
        lowFloor: 0,
        highFloor: 0,
        lowCeil: 128,
        highCeil: 96,
        flags: LinedefFlags.upperUnpegged,
        yOffset: 12,
      ));
      final WallQuad upper = walls.quads
          .firstWhere((WallQuad q) => q.band == WallBandKind.upper);
      expect(upper.yOffset, 12);
    });
  });

  group('fake contrast', () {
    test('north-south walls read brighter than east-west ones', () {
      final WallSet walls = _wallsOf(_simpleRoom());
      // The room is axis-aligned, so every wall is purely horizontal or
      // vertical and the two groups must differ.
      final Set<double> lights =
          walls.quads.map((WallQuad q) => q.lightLevel).toSet();
      expect(lights.length, 2);
      expect(lights.reduce((double a, double b) => a > b ? a : b),
          greaterThan(lights.reduce((double a, double b) => a < b ? a : b)));
    });

    test('can be disabled', () {
      final WallSet walls = _wallsOf(
        _simpleRoom(),
        options: const GeometryOptions(fakeContrast: false),
      );
      expect(walls.quads.map((WallQuad q) => q.lightLevel).toSet().length, 1);
    });
  });

  test('missing textures are reported, not fatal', () {
    final MapBuilder b = MapBuilder('MISSING');
    final int s = b.sector();
    b.solidLoop(<int>[0, 0, 256, 0, 256, 256, 0, 256], s, middle: 'NOSUCHTEX');
    final WallSet walls = _wallsOf(b.build());
    expect(walls.missingTextures, contains('NOSUCHTEX'));
    expect(walls.quads.length, 4, reason: 'geometry is still emitted');
  });
}

WallSet _wallsOf(
  MapData map, {
  GeometryOptions options = GeometryOptions.defaults,
}) =>
    WallBuilder(map, testTextures(), options).build();

MapData _simpleRoom({
  int xOffset = 0,
  int yOffset = 0,
  int flags = 0,
  int ceiling = 128,
}) {
  final MapBuilder b = MapBuilder('ROOM');
  final int s = b.sector(floorHeight: 0, ceilingHeight: ceiling);
  b.solidLoop(
    <int>[0, 0, 256, 0, 256, 256, 0, 256],
    s,
    xOffset: xOffset,
    yOffset: yOffset,
    flags: flags,
  );
  return b.build(buildNodes: false);
}

/// Two rooms sharing one two-sided wall, with controllable heights.
MapData _twoRooms({
  required int lowFloor,
  required int highFloor,
  required int lowCeil,
  required int highCeil,
  int flags = 0,
  int yOffset = 0,
  String middle = '-',
  bool skyBoth = false,
  bool skyFront = false,
}) {
  final MapBuilder b = MapBuilder('TWO');
  final int front = b.sector(
    floorHeight: lowFloor,
    ceilingHeight: lowCeil,
    ceilingFlat: skyBoth || skyFront ? kSkyFlatName : 'CEIL1_1',
  );
  final int back = b.sector(
    floorHeight: highFloor,
    ceilingHeight: highCeil,
    ceilingFlat: skyBoth ? kSkyFlatName : 'CEIL1_1',
  );
  final int v1 = b.vertex(0, 0);
  final int v2 = b.vertex(0, 256);
  final int frontSide = b.sidedef(
    sector: front,
    upper: 'STARTAN3',
    lower: 'STARTAN3',
    middle: middle,
    yOffset: yOffset,
  );
  final int backSide = b.sidedef(
    sector: back,
    upper: 'STARTAN3',
    lower: 'STARTAN3',
    middle: middle,
    yOffset: yOffset,
  );
  b.line(v1: v1, v2: v2, right: frontSide, left: backSide, flags: flags);
  return b.build(buildNodes: false);
}

