import 'dart:math' as math;

import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/material.dart';

import '../game/doom_automap.dart';

/// Classic north-up Doom automap, intentionally drawn outside Flame 3D.
final class DoomAutomapOverlay extends StatelessWidget {
  const DoomAutomapOverlay({
    super.key,
    required this.map,
    required this.snapshot,
  });

  final MapData map;
  final DoomAutomapSnapshot snapshot;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      key: const Key('doom-automap'),
      child: CustomPaint(
        painter: DoomAutomapPainter(map: map, snapshot: snapshot),
        child: const SizedBox.expand(),
      ),
    ),
  );
}

/// Painter for automap lines and the player arrow. Coordinates remain north-up:
/// map X increases right and map Y increases up on screen.
final class DoomAutomapPainter extends CustomPainter {
  DoomAutomapPainter({required this.map, required this.snapshot});

  static const Color oneSidedColor = Color(0xFFE65A4F);
  // Vanilla renders special 39 with the midpoint of its wall-red palette.
  static const Color teleporterColor = Color(0xFFC54D43);
  static const Color floorStepColor = Color(0xFFC69B4C);
  static const Color ceilingStepColor = Color(0xFFE1D45A);
  static const Color playerColor = Color(0xFFF4F4F0);
  static const Color backgroundColor = Color(0xE6121519);
  static final Paint _backgroundPaint = Paint()..color = backgroundColor;
  static final Paint _linePaint = Paint()
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.square
    ..style = PaintingStyle.stroke;
  static final Paint _playerPaint = Paint()
    ..color = playerColor
    ..style = PaintingStyle.fill;
  static final Path _playerPath = Path();

  final MapData map;
  final DoomAutomapSnapshot snapshot;

  /// Returns the vanilla-style semantic colour, or null for a hidden line.
  static Color? colorForLine(
    MapData map,
    DoomAutomapSnapshot snapshot,
    int index,
  ) {
    final line = map.linedefs[index];
    if ((line.flags & LinedefFlags.dontDraw) != 0) {
      return null;
    }
    if (!line.isTwoSided) {
      return oneSidedColor;
    }
    if (line.special == 39) {
      return teleporterColor;
    }
    if ((line.flags & LinedefFlags.secret) != 0) {
      return oneSidedColor;
    }
    final frontSector = map.sidedefs[line.rightSidedef].sector;
    final backSector = map.sidedefs[line.leftSidedef].sector;
    if (frontSector >= snapshot.sectorFloors.length ||
        backSector >= snapshot.sectorFloors.length ||
        frontSector >= snapshot.sectorCeilings.length ||
        backSector >= snapshot.sectorCeilings.length) {
      return null;
    }
    if (snapshot.sectorFloors[frontSector] !=
        snapshot.sectorFloors[backSector]) {
      return floorStepColor;
    }
    if (snapshot.sectorCeilings[frontSector] !=
        snapshot.sectorCeilings[backSector]) {
      return ceilingStepColor;
    }
    return null;
  }

  /// Testable projection helper. A line is only a candidate after discovery.
  Iterable<int> visibleLineIndices() sync* {
    for (final index in snapshot.visitedLines) {
      if (index >= 0 &&
          index < map.linedefs.length &&
          colorForLine(map, snapshot, index) != null) {
        yield index;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _backgroundPaint);
    final center = Offset(size.width / 2, size.height / 2);
    final scale = snapshot.zoom;
    for (final index in snapshot.visitedLines) {
      if (index < 0 || index >= map.linedefs.length) continue;
      final color = colorForLine(map, snapshot, index);
      if (color == null) continue;
      final line = map.linedefs[index];
      _linePaint.color = color;
      canvas.drawLine(
        projectVertex(map.vertices[line.v1], center, scale),
        projectVertex(map.vertices[line.v2], center, scale),
        _linePaint,
      );
    }
    _paintPlayer(canvas, center, snapshot.playerAngle);
  }

  /// Testable projection helper. Snapshot coordinates are map units.
  Offset projectVertex(MapVertex vertex, Offset center, double scale) => Offset(
    center.dx + (vertex.x - snapshot.playerX) * scale,
    center.dy - (vertex.y - snapshot.playerY) * scale,
  );

  static void _paintPlayer(Canvas canvas, Offset center, int bamAngle) {
    final radians = (bamAngle & 0xffffffff) * (math.pi * 2 / 0x100000000);
    final forward = Offset(math.cos(radians), -math.sin(radians));
    final right = Offset(-forward.dy, forward.dx);
    _playerPath
      ..reset()
      ..moveTo(center.dx + forward.dx * 12, center.dy + forward.dy * 12)
      ..lineTo(
        center.dx - forward.dx * 7 + right.dx * 6,
        center.dy - forward.dy * 7 + right.dy * 6,
      )
      ..lineTo(center.dx - forward.dx * 4, center.dy - forward.dy * 4)
      ..lineTo(
        center.dx - forward.dx * 7 - right.dx * 6,
        center.dy - forward.dy * 7 - right.dy * 6,
      )
      ..close();
    canvas.drawPath(_playerPath, _playerPaint);
  }

  @override
  bool shouldRepaint(covariant DoomAutomapPainter oldDelegate) =>
      oldDelegate.map != map ||
      oldDelegate.snapshot.isOpen != snapshot.isOpen ||
      oldDelegate.snapshot.zoom != snapshot.zoom ||
      oldDelegate.snapshot.playerX != snapshot.playerX ||
      oldDelegate.snapshot.playerY != snapshot.playerY ||
      oldDelegate.snapshot.playerAngle != snapshot.playerAngle ||
      !identical(oldDelegate.snapshot.visitedLines, snapshot.visitedLines) ||
      !identical(oldDelegate.snapshot.sectorFloors, snapshot.sectorFloors) ||
      !identical(oldDelegate.snapshot.sectorCeilings, snapshot.sectorCeilings);
}
