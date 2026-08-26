import 'dart:math' as math;

import 'package:doom_geometry/doom_geometry.dart' as geometry;
import 'package:doom_wad/doom_wad.dart' as wad;

/// One camera pose sampled from [RendererSmokeTrajectory].
typedef RendererSmokeCameraPose = ({
  int sector,
  double x,
  double y,
  double z,
  double targetX,
  double targetY,
  double targetZ,
});

/// A renderer-smoke camera path whose every sampled position is on a real
/// compiled floor triangle rather than inside the map's overall AABB.
///
/// The scale fixture deliberately contains disconnected rooms. Legs therefore
/// switch instantly between distributed rooms, then move continuously inside
/// one convex floor triangle. There is no sampled interpolation through the
/// void between rooms. Eye height is derived from the current sector floor, so
/// the path remains valid if a selected floor is moved by the harness.
final class RendererSmokeTrajectory {
  RendererSmokeTrajectory._(this.legs);

  factory RendererSmokeTrajectory.fromLevel(
    wad.MapData map,
    geometry.CompiledLevel level, {
    Set<int> excludedSectors = const <int>{},
  }) {
    final candidates = <RendererSmokeLeg>[];
    for (final plane in level.floorPlanes) {
      final int sector = plane.sector;
      if (excludedSectors.contains(sector)) continue;
      final mapSector = map.sectors[sector];
      if (mapSector.ceilingHeight - mapSector.floorHeight < playerHeight) {
        continue;
      }
      final triangle = _largestTriangle(level, plane);
      if (triangle == null) continue;
      candidates.add(RendererSmokeLeg._fromTriangle(sector, triangle));
    }
    if (candidates.isEmpty) {
      throw StateError('renderer smoke map has no playable floor triangles');
    }
    if (candidates.length <= maxLegs) {
      return RendererSmokeTrajectory._(candidates);
    }

    // Even sector-order sampling spreads the measurement over the whole map
    // instead of biasing it toward the first cluster of rooms.
    final selected = <RendererSmokeLeg>[];
    for (var i = 0; i < maxLegs; i++) {
      final int index = (i * (candidates.length - 1) / (maxLegs - 1)).round();
      selected.add(candidates[index]);
    }
    return RendererSmokeTrajectory._(selected);
  }

  static const int maxLegs = 12;
  static const double legSeconds = 1;
  static const double eyeHeight = 41;
  static const double playerHeight = 56;

  final List<RendererSmokeLeg> legs;

  RendererSmokeCameraPose sample(double seconds, List<double> sectorFloors) {
    final double cycle = legs.length * legSeconds;
    final double wrapped = seconds % cycle;
    final int index = (wrapped / legSeconds).floor().clamp(0, legs.length - 1);
    final double t = (wrapped - index * legSeconds) / legSeconds;
    final leg = legs[index];
    final double x = _lerp(leg.startX, leg.endX, t);
    final double mapY = _lerp(leg.startY, leg.endY, t);
    final double eyeY = sectorFloors[leg.sector] + eyeHeight;
    final double dx = leg.endX - leg.startX;
    final double dy = leg.endY - leg.startY;
    final double length = math.sqrt(dx * dx + dy * dy);
    final double targetScale = length == 0 ? 0 : 64 / length;
    return (
      sector: leg.sector,
      x: x,
      y: eyeY,
      z: -mapY,
      targetX: x + dx * targetScale,
      targetY: eyeY,
      targetZ: -(mapY + dy * targetScale),
    );
  }

  static _FloorTriangle? _largestTriangle(
    geometry.CompiledLevel level,
    geometry.SectorPlaneRef plane,
  ) {
    _FloorTriangle? largest;
    for (final range in plane.ranges) {
      final mesh = level.meshes[range.meshIndex];
      final int first = range.firstVertex;
      final int end = first + range.vertexCount;
      for (var i = 0; i < mesh.indices.length; i += 3) {
        final int ia = mesh.indices[i];
        final int ib = mesh.indices[i + 1];
        final int ic = mesh.indices[i + 2];
        if (ia < first ||
            ia >= end ||
            ib < first ||
            ib >= end ||
            ic < first ||
            ic >= end) {
          continue;
        }
        final triangle = _FloorTriangle(
          _point(mesh, ia),
          _point(mesh, ib),
          _point(mesh, ic),
        );
        if (triangle.area2 <= 1e-6) continue;
        if (largest == null || triangle.area2 > largest.area2) {
          largest = triangle;
        }
      }
    }
    return largest;
  }

  static _MapPoint _point(geometry.PackedMesh mesh, int vertex) {
    final int offset = vertex * geometry.DoomVertexAbi.floatsPerVertex;
    return _MapPoint(mesh.vertices[offset], -mesh.vertices[offset + 2]);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// A continuous in-room leg. [start] and [end] are strict convex combinations
/// of the source triangle, so every interpolated pose is inside walkable floor.
final class RendererSmokeLeg {
  RendererSmokeLeg._({
    required this.sector,
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    required this.triangleAx,
    required this.triangleAy,
    required this.triangleBx,
    required this.triangleBy,
    required this.triangleCx,
    required this.triangleCy,
  });

  factory RendererSmokeLeg._fromTriangle(int sector, _FloorTriangle triangle) {
    final center = triangle.center;
    final vertices = <_MapPoint>[triangle.a, triangle.b, triangle.c];
    var first = triangle.a;
    var second = triangle.b;
    var greatestDistance2 = -1.0;
    for (var i = 0; i < vertices.length; i++) {
      for (var j = i + 1; j < vertices.length; j++) {
        final double dx = vertices[i].x - vertices[j].x;
        final double dy = vertices[i].y - vertices[j].y;
        final double distance2 = dx * dx + dy * dy;
        if (distance2 > greatestDistance2) {
          greatestDistance2 = distance2;
          first = vertices[i];
          second = vertices[j];
        }
      }
    }
    // Keep both endpoints well away from walls while still crossing a useful
    // portion of the triangle.
    final start = _MapPoint.mix(center, first, 0.45);
    final end = _MapPoint.mix(center, second, 0.45);
    return RendererSmokeLeg._(
      sector: sector,
      startX: start.x,
      startY: start.y,
      endX: end.x,
      endY: end.y,
      triangleAx: triangle.a.x,
      triangleAy: triangle.a.y,
      triangleBx: triangle.b.x,
      triangleBy: triangle.b.y,
      triangleCx: triangle.c.x,
      triangleCy: triangle.c.y,
    );
  }

  final int sector;
  final double startX;
  final double startY;
  final double endX;
  final double endY;
  final double triangleAx;
  final double triangleAy;
  final double triangleBx;
  final double triangleBy;
  final double triangleCx;
  final double triangleCy;

  bool contains(double x, double y) {
    double side(
      double px,
      double py,
      double ax,
      double ay,
      double bx,
      double by,
    ) => (px - bx) * (ay - by) - (ax - bx) * (py - by);

    final double d1 = side(
      x,
      y,
      triangleAx,
      triangleAy,
      triangleBx,
      triangleBy,
    );
    final double d2 = side(
      x,
      y,
      triangleBx,
      triangleBy,
      triangleCx,
      triangleCy,
    );
    final double d3 = side(
      x,
      y,
      triangleCx,
      triangleCy,
      triangleAx,
      triangleAy,
    );
    final bool hasNegative = d1 < -1e-5 || d2 < -1e-5 || d3 < -1e-5;
    final bool hasPositive = d1 > 1e-5 || d2 > 1e-5 || d3 > 1e-5;
    return !(hasNegative && hasPositive);
  }
}

final class _FloorTriangle {
  const _FloorTriangle(this.a, this.b, this.c);

  final _MapPoint a;
  final _MapPoint b;
  final _MapPoint c;

  double get area2 =>
      ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs();

  _MapPoint get center =>
      _MapPoint((a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3);
}

final class _MapPoint {
  const _MapPoint(this.x, this.y);

  final double x;
  final double y;

  static _MapPoint mix(_MapPoint a, _MapPoint b, double t) =>
      _MapPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
}
