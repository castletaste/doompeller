import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/foundation.dart';

typedef AutomapSectorHeights = ({
  int sectorIndex,
  double floorHeight,
  double ceilingHeight,
});

/// Immutable UI-only state consumed by the Flutter automap overlay.
///
/// It deliberately contains no simulation state. In particular, visited lines
/// live here rather than in [GameState], so opening the map can never alter a
/// deterministic replay hash. Player coordinates and sector heights are map
/// units, keeping 16.16 fixed-point values out of the UI layer.
@immutable
final class DoomAutomapSnapshot {
  const DoomAutomapSnapshot({
    required this.isOpen,
    required this.zoom,
    required this.playerX,
    required this.playerY,
    required this.playerAngle,
    required this.visitedLines,
    this.sectorFloors = const <double>[],
    this.sectorCeilings = const <double>[],
  });

  final bool isOpen;
  final double zoom;
  final double playerX;
  final double playerY;
  final int playerAngle;
  final Set<int> visitedLines;

  /// Current sector heights in map units, indexed by sector.
  final List<double> sectorFloors;
  final List<double> sectorCeilings;
}

/// Owns ephemeral automap discovery and controls for one prepared level.
///
/// A sector entry reveals nearby boundary lines. This is a deliberately small
/// classic-style fog approximation: it never feeds data back into the 35 Hz
/// simulation and is reset when the runtime is replaced.
final class DoomAutomapState extends ValueNotifier<DoomAutomapSnapshot> {
  factory DoomAutomapState(MapData map, PlayerView player) {
    final visitedLines = <int>{
      for (var index = 0; index < map.linedefs.length; index++)
        if ((map.linedefs[index].flags & LinedefFlags.mapped) != 0) index,
    };
    final sectorFloors = <double>[
      for (final sector in map.sectors) sector.floorHeight.toDouble(),
    ];
    final sectorCeilings = <double>[
      for (final sector in map.sectors) sector.ceilingHeight.toDouble(),
    ];
    return DoomAutomapState._(
      map,
      visitedLines,
      sectorFloors,
      sectorCeilings,
      DoomAutomapSnapshot(
        isOpen: false,
        zoom: initialZoom,
        playerX: fixedToDouble(player.x),
        playerY: fixedToDouble(player.y),
        playerAngle: player.angle,
        visitedLines: Set<int>.unmodifiable(visitedLines),
        sectorFloors: List<double>.unmodifiable(sectorFloors),
        sectorCeilings: List<double>.unmodifiable(sectorCeilings),
      ),
    );
  }

  DoomAutomapState._(
    this._map,
    this._visitedLines,
    this._sectorFloors,
    this._sectorCeilings,
    super.initialValue,
  );

  static const double initialZoom = 0.32;
  static const double minZoom = 0.08;
  static const double maxZoom = 2.4;
  static const double _zoomStep = 1.25;

  /// Broad enough for normal rooms/courtyards, but finite so disconnected
  /// islands in one sector do not reveal each other on entry.
  static const double discoveryRadius = 1536;

  final MapData _map;
  final Set<int> _visitedLines;
  final List<double> _sectorFloors;
  final List<double> _sectorCeilings;
  int? _lastDiscoveredSector;
  bool _hasComputerMap = false;

  @visibleForTesting
  int discoveryScanCount = 0;

  @visibleForTesting
  int publicationCount = 0;

  /// Restores the same UI-only state used when this notifier was constructed.
  /// The notifier itself is retained so widget listeners never accumulate.
  void reset(PlayerView player) {
    _visitedLines
      ..clear()
      ..addAll(<int>{
        for (var index = 0; index < _map.linedefs.length; index++)
          if ((_map.linedefs[index].flags & LinedefFlags.mapped) != 0) index,
      });
    for (var index = 0; index < _map.sectors.length; index++) {
      _sectorFloors[index] = _map.sectors[index].floorHeight.toDouble();
      _sectorCeilings[index] = _map.sectors[index].ceilingHeight.toDouble();
    }
    _lastDiscoveredSector = null;
    _hasComputerMap = false;
    value = DoomAutomapSnapshot(
      isOpen: false,
      zoom: initialZoom,
      playerX: fixedToDouble(player.x),
      playerY: fixedToDouble(player.y),
      playerAngle: player.angle,
      visitedLines: Set<int>.unmodifiable(_visitedLines),
      sectorFloors: List<double>.unmodifiable(_sectorFloors),
      sectorCeilings: List<double>.unmodifiable(_sectorCeilings),
    );
  }

  void toggle() => _publish(isOpen: !value.isOpen);

  void zoomIn() => _setZoom(value.zoom * _zoomStep);

  void zoomOut() => _setZoom(value.zoom / _zoomStep);

  void updatePlayer(
    PlayerView player, {
    required int sectorIndex,
    Iterable<AutomapSectorHeights> sectorHeights = const [],
  }) {
    var heightsChanged = false;
    for (final heights in sectorHeights) {
      heightsChanged = _applySectorHeights(heights) || heightsChanged;
    }
    Set<int>? visitedLines;
    if (player.powers.computerMap && !_hasComputerMap) {
      _hasComputerMap = true;
      final before = _visitedLines.length;
      for (var index = 0; index < _map.linedefs.length; index++) {
        if ((_map.linedefs[index].flags & LinedefFlags.dontDraw) == 0) {
          _visitedLines.add(index);
        }
      }
      if (before != _visitedLines.length) {
        visitedLines = Set<int>.unmodifiable(_visitedLines);
      }
    }
    if (sectorIndex >= 0 &&
        sectorIndex < _map.sectors.length &&
        sectorIndex != _lastDiscoveredSector) {
      _lastDiscoveredSector = sectorIndex;
      if (_discoverSector(
        sectorIndex,
        fixedToDouble(player.x),
        fixedToDouble(player.y),
      )) {
        visitedLines = Set<int>.unmodifiable(_visitedLines);
      }
    }
    _publish(
      playerX: fixedToDouble(player.x),
      playerY: fixedToDouble(player.y),
      playerAngle: player.angle,
      visitedLines: visitedLines,
      sectorFloors: heightsChanged
          ? List<double>.unmodifiable(_sectorFloors)
          : null,
      sectorCeilings: heightsChanged
          ? List<double>.unmodifiable(_sectorCeilings)
          : null,
    );
  }

  /// Publishes changed runtime heights after the adapter has extracted them
  /// from [GameState]. The UI never observes mutable core state directly.
  void updateSectorHeights({
    required int sectorIndex,
    required double floorHeight,
    required double ceilingHeight,
  }) {
    if (!_applySectorHeights((
      sectorIndex: sectorIndex,
      floorHeight: floorHeight,
      ceilingHeight: ceilingHeight,
    ))) {
      return;
    }
    _publish(
      sectorFloors: List<double>.unmodifiable(_sectorFloors),
      sectorCeilings: List<double>.unmodifiable(_sectorCeilings),
    );
  }

  bool _applySectorHeights(AutomapSectorHeights heights) {
    final (:sectorIndex, :floorHeight, :ceilingHeight) = heights;
    if (sectorIndex < 0 || sectorIndex >= _sectorFloors.length) return false;
    if (_sectorFloors[sectorIndex] == floorHeight &&
        _sectorCeilings[sectorIndex] == ceilingHeight) {
      return false;
    }
    _sectorFloors[sectorIndex] = floorHeight;
    _sectorCeilings[sectorIndex] = ceilingHeight;
    return true;
  }

  bool _discoverSector(int sectorIndex, double playerX, double playerY) {
    discoveryScanCount++;
    var changed = false;
    for (var index = 0; index < _map.linedefs.length; index++) {
      final line = _map.linedefs[index];
      if (!_touchesSector(line, sectorIndex) ||
          _distanceToLine(playerX, playerY, line) > discoveryRadius) {
        continue;
      }
      changed = _visitedLines.add(index) || changed;
    }
    return changed;
  }

  bool _touchesSector(Linedef line, int sectorIndex) =>
      _map.sidedefs[line.rightSidedef].sector == sectorIndex ||
      (line.leftSidedef != kNoSidedef &&
          _map.sidedefs[line.leftSidedef].sector == sectorIndex);

  double _distanceToLine(double x, double y, Linedef line) {
    final a = _map.vertices[line.v1];
    final b = _map.vertices[line.v2];
    final dx = (b.x - a.x).toDouble();
    final dy = (b.y - a.y).toDouble();
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) {
      return math.sqrt((x - a.x) * (x - a.x) + (y - a.y) * (y - a.y));
    }
    final t = (((x - a.x) * dx + (y - a.y) * dy) / lengthSquared)
        .clamp(0, 1)
        .toDouble();
    final nearestX = a.x + dx * t;
    final nearestY = a.y + dy * t;
    return math.sqrt(
      (x - nearestX) * (x - nearestX) + (y - nearestY) * (y - nearestY),
    );
  }

  void _setZoom(double zoom) =>
      _publish(zoom: zoom.clamp(minZoom, maxZoom).toDouble());

  void _publish({
    bool? isOpen,
    double? zoom,
    double? playerX,
    double? playerY,
    int? playerAngle,
    Set<int>? visitedLines,
    List<double>? sectorFloors,
    List<double>? sectorCeilings,
  }) {
    final current = value;
    final nextIsOpen = isOpen ?? current.isOpen;
    final nextZoom = zoom ?? current.zoom;
    final nextPlayerX = playerX ?? current.playerX;
    final nextPlayerY = playerY ?? current.playerY;
    final nextPlayerAngle = playerAngle ?? current.playerAngle;
    final nextVisitedLines = visitedLines ?? current.visitedLines;
    final nextSectorFloors = sectorFloors ?? current.sectorFloors;
    final nextSectorCeilings = sectorCeilings ?? current.sectorCeilings;
    if (nextIsOpen == current.isOpen &&
        nextZoom == current.zoom &&
        nextPlayerX == current.playerX &&
        nextPlayerY == current.playerY &&
        nextPlayerAngle == current.playerAngle &&
        identical(nextVisitedLines, current.visitedLines) &&
        identical(nextSectorFloors, current.sectorFloors) &&
        identical(nextSectorCeilings, current.sectorCeilings)) {
      return;
    }
    publicationCount++;
    value = DoomAutomapSnapshot(
      isOpen: nextIsOpen,
      zoom: nextZoom,
      playerX: nextPlayerX,
      playerY: nextPlayerY,
      playerAngle: nextPlayerAngle,
      visitedLines: nextVisitedLines,
      sectorFloors: nextSectorFloors,
      sectorCeilings: nextSectorCeilings,
    );
  }
}
