/// Classic linedef and sector numbers deliberately supported by the E1M1 core.
///
/// Values are the map-format special numbers, not inferred labels. They are
/// intentionally centralized so unsupported data is visible during map review.
abstract final class LineSpecial {
  // Walk-once / use normal doors.
  static const int doorOpenWaitClose = 1;
  static const int doorOpenStay = 31;
  static const int blueDoorOpenWaitClose = 26;
  static const int yellowDoorOpenWaitClose = 27;
  static const int redDoorOpenWaitClose = 28;
  static const int blueDoorOpenStay = 32;
  static const int redDoorOpenStay = 33;
  static const int yellowDoorOpenStay = 34;
  // Switch doors found in classic episode maps.
  static const int switchDoorOpenWaitClose = 103;
  static const int switchDoorOpenStay = 61;
  static const int switchBlueDoorOpenWaitClose = 99;
  static const int switchRedDoorOpenWaitClose = 134;
  // Floors/lifts.
  static const int floorRaiseToLowestCeiling = 5;
  static const int floorRaise24 = 24;
  static const int liftDownWaitUp = 10;
  static const int liftDownWaitUpSwitch = 21;
  static const int liftDownWaitUpFast = 88;
  static const int liftDownWaitUpTurbo = 62;
  static const int liftBlazeDownWaitUp = 120;
  static const int liftBlazeDownWaitUpSwitch = 121;
  static const int liftBlazeDownWaitUpOnce = 122;
  static const int liftBlazeDownWaitUpRepeat = 123;
  // Completion.
  static const int exit = 11;
  static const int secretExit = 51;
}

abstract final class SectorSpecial {
  static const int lightFlicker = 1;
  static const int strobeFast = 2;
  static const int strobeSlow = 3;
  static const int strobeFastSync = 4;
  static const int damage10 = 5;
  static const int damage5 = 7;
  static const int glow = 8;
  static const int secret = 9;
  static const int damage20 = 11;
  static const int strobeSlowSync = 12;
  static const int strobeFastSync2 = 13;
  static const int lightFlickerSync = 17;
}
