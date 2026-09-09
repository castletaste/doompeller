import 'fixed.dart';
import 'replay_identity.dart';
import 'sector_runtime.dart';
import 'ticcmd.dart';

class DoorMover extends SectorMover {
  DoorMover(
    super.sector,
    this.target, {
    required this.closeAfterWait,
    required bool startsClosing,
    required this.reopenAfterWait,
    required this.reverseOnObstruction,
    required int closedTarget,
    required this.obstructed,
  }) : _closed = closedTarget,
       _closing = startsClosing;
  final int target;
  final int _closed;
  final bool closeAfterWait;
  final bool reopenAfterWait;
  final bool reverseOnObstruction;
  final bool Function(int nextCeiling) obstructed;
  int _wait = 150;
  bool _closing;
  bool _waitingAtBottom = false;
  bool get isClosing => _closing;
  @override
  bool tick() {
    final int step = toFixed(4);
    if (_waitingAtBottom) {
      if (--_wait <= 0) {
        _waitingAtBottom = false;
        _closing = false;
      }
      return false;
    }
    if (!_closing) {
      sector.ceilingHeight += step;
      if (sector.ceilingHeight >= target) {
        sector.ceilingHeight = target;
        if (!closeAfterWait) finished = true;
        if (closeAfterWait && --_wait <= 0) _closing = true;
      }
    } else {
      final int next = sector.ceilingHeight - step;
      if (obstructed(next)) {
        if (reverseOnObstruction) {
          _closing = false;
          _wait = 150;
        }
        return false;
      }
      sector.ceilingHeight = next;
      if (sector.ceilingHeight <= _closed) {
        sector.ceilingHeight = _closed;
        if (reopenAfterWait) {
          _wait = 30 * kTicRate;
          _waitingAtBottom = true;
        } else {
          finished = true;
        }
      }
    }
    return true;
  }

  @override
  Iterable<int> get hashWords => <int>[
    1,
    target,
    _closed,
    closeAfterWait ? 1 : 0,
    reopenAfterWait ? 1 : 0,
    reverseOnObstruction ? 1 : 0,
    _wait,
    _closing ? 1 : 0,
    _waitingAtBottom ? 1 : 0,
  ];
}

class LiftMover extends SectorMover {
  LiftMover(super.sector, this.bottom) : top = sector.floorHeight;
  final int bottom, top;
  int _wait = 35;
  bool _returning = false;
  @override
  bool tick() {
    const int step = 4 * kFracUnit;
    if (!_returning) {
      sector.floorHeight -= step;
      if (sector.floorHeight <= bottom) {
        sector.floorHeight = bottom;
        if (_wait-- <= 0) _returning = true;
      }
    } else {
      sector.floorHeight += step;
      if (sector.floorHeight >= top) {
        sector.floorHeight = top;
        finished = true;
      }
    }
    return true;
  }

  @override
  Iterable<int> get hashWords => <int>[
    2,
    bottom,
    top,
    _wait,
    _returning ? 1 : 0,
  ];
}

class FloorMover extends SectorMover {
  FloorMover(
    super.sector,
    this.target, {
    required this.obstructed,
    this.speed = kFracUnit,
    this.transferFlat,
    this.transferSpecial,
  });
  final int target;
  final int speed;
  final bool Function(int nextFloor) obstructed;
  final String? transferFlat;
  final int? transferSpecial;

  @override
  bool tick() {
    if (sector.floorHeight == target) {
      finished = true;
      return false;
    }
    final int direction = target > sector.floorHeight ? 1 : -1;
    int next = sector.floorHeight + speed * direction;
    if ((direction > 0 && next > target) || (direction < 0 && next < target)) {
      next = target;
    }
    if (direction > 0 && obstructed(next)) return false;
    sector.floorHeight = next;
    if (next == target) finished = true;
    return true;
  }

  @override
  Iterable<int> get hashWords => <int>[
    3,
    target,
    speed,
    if (transferFlat != null) ...<int>[
      0x464c4154,
      stableReplayIdentity(transferFlat!),
      transferSpecial ?? sector.special,
    ],
  ];
}

class CrusherMover extends SectorMover {
  CrusherMover(
    super.sector, {
    required this.top,
    required this.bottom,
    required this.baseSpeed,
    required this.slowsOnContact,
    required this.crush,
  }) : _speed = baseSpeed;

  final int top;
  final int bottom;
  final int baseSpeed;
  final bool slowsOnContact;
  final bool Function(int nextCeiling) crush;
  int _speed;
  int _direction = -1;
  bool stopped = false;

  void stop() => stopped = true;
  void restart() => stopped = false;

  @override
  bool tick() {
    if (stopped) return false;
    if (_direction < 0) {
      int next = sector.ceilingHeight - _speed;
      if (next < bottom) next = bottom;
      sector.ceilingHeight = next;
      final bool contacted = crush(next);
      if (contacted && slowsOnContact && next > bottom) {
        _speed = kFracUnit ~/ 8;
      }
      if (next <= bottom) {
        _direction = 1;
        _speed = baseSpeed;
      }
      return true;
    }
    int next = sector.ceilingHeight + _speed;
    if (next > top) next = top;
    sector.ceilingHeight = next;
    if (next >= top) {
      _direction = -1;
      _speed = baseSpeed;
    }
    return true;
  }

  @override
  Iterable<int> get hashWords => <int>[
    4,
    top,
    bottom,
    baseSpeed,
    _speed,
    slowsOnContact ? 1 : 0,
    _direction,
    stopped ? 1 : 0,
  ];
}
