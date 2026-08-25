import 'dart:typed_data';

import 'package:doom_geometry/doom_geometry.dart';
import 'package:test/test.dart';

import 'support/synthetic_map.dart';

/// The oracle stands alone: it must be right without any help from the BSP,
/// because everything else is judged against it.
void main() {
  group('loop classification', () {
    test('a simple room is one outer loop and no holes', () {
      final SectorLoopResult r = _loops(_room(<int>[
        0, 0, 256, 0, 256, 256, 0, 256, //
      ]))[0];
      expect(r.outers.length, 1);
      expect(r.holes.single, isEmpty);
      expect(r.area, 256 * 256);
      expect(r.openChains, 0);
    });

    test('an island becomes a hole in the surrounding sector', () {
      final MapBuilder b = MapBuilder('ISLAND');
      final int room = b.sector();
      final int island = b.sector(floorHeight: 64);
      b.solidLoop(<int>[0, 0, 512, 0, 512, 512, 0, 512], room);
      b.twoSidedLoop(
        <int>[192, 192, 192, 320, 320, 320, 320, 192],
        room,
        island,
      );
      final List<SectorLoopResult> loops = _loops(b.build(buildNodes: false));

      expect(loops[room].outers.length, 1);
      expect(loops[room].holes.single.length, 1,
          reason: 'the island must be subtracted, not added');
      expect(loops[room].area, 512 * 512 - 128 * 128);

      expect(loops[island].outers.length, 1);
      expect(loops[island].holes.single, isEmpty);
      expect(loops[island].area, 128 * 128);
    });

    test('a sector split into two disjoint rooms yields two outer loops', () {
      final MapBuilder b = MapBuilder('SPLIT');
      final int s = b.sector();
      b.solidLoop(<int>[0, 0, 128, 0, 128, 128, 0, 128], s);
      b.solidLoop(<int>[512, 0, 640, 0, 640, 128, 512, 128], s);
      final SectorLoopResult r = _loops(b.build(buildNodes: false))[s];
      expect(r.outers.length, 2);
      expect(r.area, 2 * 128 * 128);
    });

    test('a hole inside a hole is an outer loop again', () {
      final MapBuilder b = MapBuilder('NEST');
      final int outer = b.sector();
      final int middle = b.sector(floorHeight: 16);
      final int inner = b.sector(floorHeight: 32);
      b.solidLoop(<int>[0, 0, 768, 0, 768, 768, 0, 768], outer);
      b.twoSidedLoop(
        <int>[128, 128, 128, 640, 640, 640, 640, 128],
        outer,
        middle,
      );
      b.twoSidedLoop(
        <int>[256, 256, 256, 512, 512, 512, 512, 256],
        middle,
        inner,
      );
      final List<SectorLoopResult> loops = _loops(b.build(buildNodes: false));
      // The middle ring is a hole in the outer sector but an outer loop of its
      // own, with the inner room punched out of it.
      expect(loops[outer].holes.single.length, 1);
      expect(loops[middle].outers.length, 1);
      expect(loops[middle].holes.single.length, 1);
      expect(loops[middle].area, 512 * 512 - 256 * 256);
      expect(loops[inner].area, 256 * 256);
    });

    test('winding of the source loop does not change the result', () {
      // solidLoop reorients internally, so both orders must agree.
      final double clockwise =
          _loops(_room(<int>[0, 0, 256, 0, 256, 256, 0, 256]))[0].area;
      final double counter =
          _loops(_room(<int>[0, 256, 256, 256, 256, 0, 0, 0]))[0].area;
      expect(clockwise, counter);
    });
  });

  group('triangulation', () {
    test('a convex polygon triangulates to n - 2 triangles', () {
      final Loop hexagon = Loop(Float64List.fromList(<double>[
        0, 0, 100, 0, 150, 87, 100, 174, 0, 174, -50, 87, //
      ]));
      final TriangulationResult r =
          EarClipper().triangulate(hexagon, const <Loop>[], CheckBudget(10000));
      expect(r.triangleCount, 4);
      expect(r.isComplete, isTrue);
      expect(r.area, closeTo(hexagon.area, 1e-9));
    });

    test('a concave polygon preserves its area', () {
      final Loop l = Loop(Float64List.fromList(<double>[
        0, 0, 256, 0, 256, 128, 128, 128, 128, 256, 0, 256, //
      ]));
      final TriangulationResult r =
          EarClipper().triangulate(l, const <Loop>[], CheckBudget(10000));
      expect(r.area, closeTo(256 * 256 - 128 * 128, 1e-9));
    });

    test('a hole is subtracted, not covered over', () {
      final Loop outer = Loop(Float64List.fromList(<double>[
        0, 0, 400, 0, 400, 400, 0, 400, //
      ]));
      final Loop hole = Loop(Float64List.fromList(<double>[
        100, 100, 100, 300, 300, 300, 300, 100, //
      ]));
      final TriangulationResult r = EarClipper()
          .triangulate(outer, <Loop>[hole], CheckBudget(100000));
      expect(r.area, closeTo(400 * 400 - 200 * 200, 1e-6));
      expect(r.isComplete, isTrue);
    });

    test('two holes are both subtracted', () {
      final Loop outer = Loop(Float64List.fromList(<double>[
        0, 0, 600, 0, 600, 400, 0, 400, //
      ]));
      final Loop a = Loop(Float64List.fromList(<double>[
        50, 50, 50, 150, 150, 150, 150, 50, //
      ]));
      final Loop b = Loop(Float64List.fromList(<double>[
        400, 200, 400, 300, 500, 300, 500, 200, //
      ]));
      final TriangulationResult r = EarClipper()
          .triangulate(outer, <Loop>[a, b], CheckBudget(200000));
      expect(r.area, closeTo(600 * 400 - 100 * 100 - 100 * 100, 1e-6));
    });

    test('a collinear-heavy polygon does not emit zero-area triangles', () {
      // A square whose bottom edge is subdivided five times, the shape
      // T-junction repair produces.
      final Loop l = Loop(Float64List.fromList(<double>[
        0, 0, 20, 0, 40, 0, 60, 0, 80, 0, 100, 0, 100, 100, 0, 100, //
      ]));
      final TriangulationResult r =
          EarClipper().triangulate(l, const <Loop>[], CheckBudget(10000));
      expect(r.area, closeTo(100 * 100, 1e-9));
      // Every emitted triangle must have real area.
      for (var t = 0; t < r.indices.length; t += 3) {
        final int ia = r.indices[t] * 2;
        final int ib = r.indices[t + 1] * 2;
        final int ic = r.indices[t + 2] * 2;
        final double cross =
            (r.vertices[ib] - r.vertices[ia]) *
                    (r.vertices[ic + 1] - r.vertices[ia + 1]) -
                (r.vertices[ic] - r.vertices[ia]) *
                    (r.vertices[ib + 1] - r.vertices[ia + 1]);
        expect(cross.abs(), greaterThan(1e-9));
      }
    });

    test('a two-vertex loop triangulates to nothing rather than throwing', () {
      final Loop degenerate =
          Loop(Float64List.fromList(<double>[0, 0, 100, 100]));
      final TriangulationResult r = EarClipper()
          .triangulate(degenerate, const <Loop>[], CheckBudget(1000));
      expect(r.triangleCount, 0);
    });
  });

  group('polygon primitives', () {
    test('signed area is positive for counter-clockwise winding', () {
      final Float64List ccw =
          Float64List.fromList(<double>[0, 0, 100, 0, 100, 100, 0, 100]);
      expect(signedArea2(ccw, 4), greaterThan(0));
      expect(polygonArea(ccw, 4), 100 * 100);

      final Float64List cw =
          Float64List.fromList(<double>[0, 0, 0, 100, 100, 100, 100, 0]);
      expect(signedArea2(cw, 4), lessThan(0));
      expect(polygonArea(cw, 4), 100 * 100);
    });

    test('a growable poly buffer survives past its initial capacity', () {
      final PolyBuffer buffer = PolyBuffer(2);
      for (var i = 0; i < 500; i++) {
        buffer.add(i.toDouble(), -i.toDouble());
      }
      expect(buffer.length, 500);
      expect(buffer.x(499), 499);
      expect(buffer.y(499), -499);
    });

    test('a snapshot does not alias the buffer', () {
      final PolyBuffer buffer = PolyBuffer(4)
        ..add(1, 2)
        ..add(3, 4)
        ..add(5, 6);
      final Float64List snapshot = buffer.toFloat64List();
      buffer
        ..clear()
        ..add(99, 99);
      expect(snapshot[0], 1);
      expect(snapshot[4], 5,
          reason: 'pooled buffers are reused, so a view would be corrupted');
    });
  });
}

List<SectorLoopResult> _loops(MapData map) =>
    SectorLoopBuilder(map, GeometryOptions.defaults)
        .buildAll(CheckBudget(1000000));

MapData _room(List<int> points) {
  final MapBuilder b = MapBuilder('ROOM');
  final int s = b.sector();
  b.solidLoop(points, s);
  return b.build(buildNodes: false);
}
