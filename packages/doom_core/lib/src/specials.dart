/// Classic linedef and sector numbers deliberately supported by the E1M1 core.
///
/// Values are the map-format special numbers, not inferred labels. They are
/// intentionally centralized so unsupported data is visible during map review.
abstract final class LineSpecial {
  // Use normal doors.
  static const int doorOpenWaitClose = 1;
  static const int doorOpenStay = 31;
  static const int blueDoorOpenWaitClose = 26;
  static const int yellowDoorOpenWaitClose = 27;
  static const int redDoorOpenWaitClose = 28;
  static const int blueDoorOpenStay = 32;
  static const int redDoorOpenStay = 33;
  static const int yellowDoorOpenStay = 34;
  // Switch doors found in classic episode maps.
  static const int switchDoorOpenStayOnce = 103;
  // Compatibility only: the old name misidentified special 103 as a timed door.
  @Deprecated('Use switchDoorOpenStayOnce; special 103 never closes on a timer.')
  static const int switchDoorOpenWaitClose = switchDoorOpenStayOnce;
  static const int switchDoorOpenStay = 61;
  static const int switchBlueDoorOpenWaitClose = 99;
  static const int switchRedDoorOpenWaitClose = 134;
  // Walk doors. W1 variants consume the line; WR variants may retrigger after
  // the sector's previous mover has completed.
  static const int walkDoorOpenStayOnce = 2;
  static const int walkDoorCloseOnce = 3;
  static const int walkDoorOpenWaitCloseOnce = 4;
  static const int walkDoorCloseWaitOpenOnce = 16;
  static const int walkDoorCloseWaitOpenRepeat = 76;
  static const int walkDoorCloseRepeat = 75;
  static const int walkDoorOpenStayRepeat = 86;
  static const int walkDoorOpenWaitCloseRepeat = 90;
  static const int switchDoorOpenWaitCloseRepeat = 63;
  static const int shootDoorOpenStayRepeat = 46;
  // Ceiling crushers and their in-stasis controls.
  static const int walkFastCrusherOnce = 6;
  static const int walkCrusherOnce = 25;
  static const int switchCrusherOnce = 49;
  static const int walkCrusherStopOnce = 57;
  static const int walkCrusherRepeat = 73;
  static const int walkCrusherStopRepeat = 74;
  static const int walkFastCrusherRepeat = 77;
  // Floors/lifts.
  static const int floorRaiseToLowestCeiling = 5;
  static const int floorRaise24 = 24;
  static const int switchFloorRaiseToNextHigherOnce = 18;
  static const int walkFloorLowerToHighestOnce = 19;
  static const int switchFloorLowerToLowestOnce = 23;
  static const int switchFloorRaiseToNextHigherAndChangeOnce = 20;
  static const int walkFloorRaiseToNextHigherAndChangeOnce = 22;
  static const int walkFloorLowerTurboOnce = 36;
  static const int switchFloorLowerTurboRepeat = 70;
  static const int walkFloorLowerTurboRepeat = 98;
  static const int walkFloorLowerToLowestOnce = 38;
  static const int walkFloorLowerToLowestAndChangeOnce = 37;
  static const int walkFloorRaise24Once = 58;
  static const int walkFloorRaise24AndChangeOnce = 59;
  static const int walkFloorLowerToLowestRepeat = 82;
  static const int walkFloorRaiseToLowestCeilingRepeat = 91;
  static const int walkFloorRaiseToNextHigherOnce = 119;
  static const int walkFloorRaiseToNextHigherRepeat = 128;
  static const int switchBuildStairs8Once = 7;
  static const int switchDonutOnce = 9;
  static const int walkBuildStairs8Once = 8;
  static const int liftDownWaitUp = 10;
  static const int liftDownWaitUpSwitch = 21;
  static const int liftDownWaitUpFast = 88;
  static const int liftDownWaitUpTurbo = 62;
  static const int liftBlazeDownWaitUp = 120;
  static const int liftBlazeDownWaitUpSwitch = 121;
  static const int liftBlazeDownWaitUpOnce = 122;
  static const int liftBlazeDownWaitUpRepeat = 123;
  static const int walkLightTurnOn35Once = 35;
  static const int walkTeleportOnce = 39;
  static const int walkTeleportRepeat = 97;
  static const int walkMonsterTeleportOnce = 125;
  static const int walkMonsterTeleportRepeat = 126;
  // Completion. 11/51 are S1 (front-side use once); 52/124 are W1
  // (player walk once). Keep the old aliases for source compatibility.
  static const int exitSwitchOnce = 11;
  static const int secretExitSwitchOnce = 51;
  static const int exitWalkOnce = 52;
  static const int secretExitWalkOnce = 124;
  static const int exit = exitSwitchOnce;
  static const int secretExit = secretExitSwitchOnce;
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
  static const int damage20Strong = 16;
}
