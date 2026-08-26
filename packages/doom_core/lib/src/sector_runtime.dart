import 'package:doom_wad/doom_wad.dart';

import 'fixed.dart';

/// Mutable per-sector state.
///
/// The static [Sector] from the WAD never changes; everything a door, lift,
/// crusher or light flicker touches lives here. The renderer reads
/// [floorHeight] and [ceilingHeight] each frame and rewrites the affected
/// vertex ranges in place, which is why heights are the only geometry the GPU
/// buffers ever see change.
class SectorRuntime {
  SectorRuntime({required this.index, required this.staticData})
    : floorHeight = toFixed(staticData.floorHeight),
      ceilingHeight = toFixed(staticData.ceilingHeight),
      lightLevel = staticData.lightLevel,
      special = staticData.special,
      floorFlat = staticData.floorFlat,
      ceilingFlat = staticData.ceilingFlat;

  final int index;
  final Sector staticData;

  /// Fixed-point current heights.
  int floorHeight;
  int ceilingHeight;

  int lightLevel;
  int special;
  String floorFlat;
  String ceilingFlat;

  /// Set while a door, lift, crusher or floor mover owns this sector. Vanilla
  /// allows only one active mover per sector, which is why repeatedly bumping a
  /// door does not stack.
  SectorMover? activeMover;

  /// Linedefs whose front or back side touches this sector. Populated at load
  /// so a height change can find the wall bands it invalidates without a scan.
  final List<int> touchingLinedefs = <int>[];

  /// Actors currently standing in this sector.
  final List<int> mobjIndices = <int>[];

  bool get isSkyCeiling => staticData.ceilingIsSky;
  bool get hasMover => activeMover != null;

  /// Height the sector's ceiling would move to for a normal door: four units
  /// below the lowest neighbouring ceiling, so the door head never clips.
  int get openTop => ceilingHeight - toFixed(4);
}

/// Base class for anything that animates a sector plane over time.
abstract class SectorMover {
  SectorMover(this.sector);

  final SectorRuntime sector;

  /// Set when the mover has finished and should be removed after the tic.
  bool finished = false;

  /// Advances one tic. Returns true when the plane actually moved, so the
  /// caller knows whether to mark geometry dirty.
  bool tick();

  /// Integer state included in the replay hash. A mere "mover present" bit is
  /// insufficient because opening, waiting and closing have different futures.
  Iterable<int> get hashWords;
}

/// Result of trying to move a plane one step.
enum MoveResult {
  /// The plane moved the full requested amount.
  ok,

  /// The plane reached its destination this tic.
  reachedDestination,

  /// Something solid was in the way.
  crushed,
}
