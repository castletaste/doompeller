import 'mobj_info.dart';
import 'specials.dart';
import 'config.dart';

enum DoorKind { openWaitClose, openStay, close, closeWaitOpen }

enum LineActivation { use, cross, shoot }

enum LineDispatchKind {
  useDoor,
  useCrusher,
  useDonut,
  useLift,
  useFloor,
  useStair,
  useExit,
  walkDoor,
  walkCrusher,
  walkCrusherStop,
  walkLift,
  walkFloor,
  walkStair,
  walkLight,
  walkTeleport,
  walkExit,
  shootFloor,
  shootDoor,
}

enum FloorTargetKind {
  raise24,
  raise24AndChange,
  raiseToLowestCeilingMinus8,
  raiseToLowestCeiling,
  raiseToNextHigher,
  raiseToNextHigherAndChange,
  lowerToHighest,
  lowerToLowest,
  lowerToLowestAndChange,
  lowerTurbo,
}

const Set<int> useDoorSpecials = <int>{
  1,
  26,
  27,
  28,
  31,
  32,
  33,
  34,
  61,
  63,
  99,
  103,
  134,
};
const Set<int> walkDoorSpecials = <int>{2, 3, 4, 16, 75, 76, 86, 90};
const Set<int> useCrusherSpecials = <int>{49};
const Set<int> walkCrusherSpecials = <int>{6, 25, 73, 77};
const Set<int> walkCrusherStopSpecials = <int>{57, 74};
const Set<int> useDonutSpecials = <int>{9};
const Set<int> switchDoorSpecials = <int>{61, 63, 99, 103, 134};
const Set<int> walkLiftSpecials = <int>{10, 88, 120, 121};
const Set<int> useLiftSpecials = <int>{21, 62, 122, 123};
const Set<int> walkFloorSpecials = <int>{
  5,
  19,
  22,
  36,
  37,
  38,
  58,
  59,
  82,
  91,
  98,
  119,
  128,
};
const Set<int> useFloorSpecials = <int>{18, 20, 23, 70};
const Set<int> walkStairSpecials = <int>{8};
const Set<int> useStairSpecials = <int>{7};
const Set<int> walkLightSpecials = <int>{35};
const Set<int> walkTeleportSpecials = <int>{39, 97, 125, 126};
const Set<int> monsterOnlyTeleportSpecials = <int>{125, 126};
const Set<int> walkExitSpecials = <int>{52, 124};
const Set<int> useExitSpecials = <int>{11, 51};
const Set<int> shootFloorSpecials = <int>{24};
const Set<int> shootDoorSpecials = <int>{46};
const Set<int> monsterWalkSpecials = <int>{4, 10, 39, 88, 97, 125, 126};
const Map<int, FloorTargetKind> floorTargetKinds = <int, FloorTargetKind>{
  5: FloorTargetKind.raiseToLowestCeilingMinus8,
  18: FloorTargetKind.raiseToNextHigher,
  19: FloorTargetKind.lowerToHighest,
  20: FloorTargetKind.raiseToNextHigherAndChange,
  22: FloorTargetKind.raiseToNextHigherAndChange,
  23: FloorTargetKind.lowerToLowest,
  24: FloorTargetKind.raise24,
  36: FloorTargetKind.lowerTurbo,
  70: FloorTargetKind.lowerTurbo,
  98: FloorTargetKind.lowerTurbo,
  37: FloorTargetKind.lowerToLowestAndChange,
  38: FloorTargetKind.lowerToLowest,
  58: FloorTargetKind.raise24,
  59: FloorTargetKind.raise24AndChange,
  82: FloorTargetKind.lowerToLowest,
  91: FloorTargetKind.raiseToLowestCeiling,
  119: FloorTargetKind.raiseToNextHigher,
  128: FloorTargetKind.raiseToNextHigher,
};
final Set<int> supportedLineSpecials = Set<int>.unmodifiable(<int>{
  ...useDoorSpecials,
  ...walkDoorSpecials,
  ...useCrusherSpecials,
  ...walkCrusherSpecials,
  ...walkCrusherStopSpecials,
  ...useDonutSpecials,
  ...switchDoorSpecials,
  ...walkLiftSpecials,
  ...useLiftSpecials,
  ...walkFloorSpecials,
  ...useFloorSpecials,
  ...walkStairSpecials,
  ...useStairSpecials,
  ...walkLightSpecials,
  ...walkTeleportSpecials,
  ...walkExitSpecials,
  ...useExitSpecials,
  ...shootFloorSpecials,
  ...shootDoorSpecials,
});
const Set<int> supportedSectorSpecials = <int>{
  1,
  2,
  3,
  4,
  5,
  7,
  8,
  9,
  11,
  12,
  13,
  16,
  17,
};
const Set<String> coreSoundIds = <String>{
  'DSDORCLS',
  'DSDOROPN',
  'DSDMPAIN',
  'DSDMACT',
  'DSBAREXP',
  'DSITEMUP',
  'DSPISTOL',
  'DSPLPAIN',
  'DSPODTH1',
  'DSPSTART',
  'DSPSTOP',
  'DSPUNCH',
  'DSRLAUNC',
  'DSSAWFUL',
  'DSSHOTGN',
  'DSSGTATK',
  'DSSGTDTH',
  'DSSGTSIT',
  'DSSWTCHN',
  'DSSWTCHX',
  'DSTELEPT',
  'DSBRSSIT',
  'DSCLAW',
  'DSBRSDTH',
  'DSFIRSHT',
  'DSFIRXPL',
  'DSWPNUP',
};

bool isSwitchDoorSpecial(int special) => switchDoorSpecials.contains(special);
DoorKind doorKind(int special) => switch (special) {
  LineSpecial.walkDoorCloseOnce ||
  LineSpecial.walkDoorCloseRepeat => DoorKind.close,
  LineSpecial.walkDoorCloseWaitOpenOnce => DoorKind.closeWaitOpen,
  LineSpecial.walkDoorCloseWaitOpenRepeat => DoorKind.closeWaitOpen,
  LineSpecial.doorOpenStay ||
  LineSpecial.blueDoorOpenStay ||
  LineSpecial.redDoorOpenStay ||
  LineSpecial.yellowDoorOpenStay ||
  LineSpecial.shootDoorOpenStayRepeat ||
  LineSpecial.switchDoorOpenStayOnce ||
  LineSpecial.switchDoorOpenStay ||
  LineSpecial.walkDoorOpenStayOnce ||
  LineSpecial.walkDoorOpenStayRepeat => DoorKind.openStay,
  _ => DoorKind.openWaitClose,
};
Key? requiredKey(int special) => switch (special) {
  26 || 32 || 99 => Key.blue,
  27 || 34 => Key.yellow,
  28 || 33 || 134 => Key.red,
  _ => null,
};
Key? keyForMobjType(MobjType type) => switch (type) {
  MobjType.misc2 => Key.blue,
  MobjType.misc3 => Key.yellow,
  MobjType.misc4 => Key.red,
  _ => null,
};
bool isOneShotWalkSpecial(int special) => <int>{
  2,
  3,
  4,
  5,
  6,
  8,
  10,
  16,
  19,
  22,
  25,
  36,
  37,
  38,
  57,
  58,
  59,
  119,
  121,
  35,
  39,
  125,
}.contains(special);
bool isRepeatableSwitchSpecial(int special) =>
    <int>{46, 61, 62, 63, 70, 99, 123, 134}.contains(special);
bool isOneShotSwitchSpecial(int special) =>
    <int>{7, 9, 11, 18, 20, 21, 23, 24, 49, 51, 103, 122}.contains(special);

LineDispatchKind? lineDispatchKind(int special, LineActivation activation) =>
    switch (activation) {
      LineActivation.use when useDoorSpecials.contains(special) =>
        LineDispatchKind.useDoor,
      LineActivation.use when useCrusherSpecials.contains(special) =>
        LineDispatchKind.useCrusher,
      LineActivation.use when useDonutSpecials.contains(special) =>
        LineDispatchKind.useDonut,
      LineActivation.use when useLiftSpecials.contains(special) =>
        LineDispatchKind.useLift,
      LineActivation.use when useFloorSpecials.contains(special) =>
        LineDispatchKind.useFloor,
      LineActivation.use when useStairSpecials.contains(special) =>
        LineDispatchKind.useStair,
      LineActivation.use when useExitSpecials.contains(special) =>
        LineDispatchKind.useExit,
      LineActivation.cross when walkDoorSpecials.contains(special) =>
        LineDispatchKind.walkDoor,
      LineActivation.cross when walkCrusherSpecials.contains(special) =>
        LineDispatchKind.walkCrusher,
      LineActivation.cross when walkCrusherStopSpecials.contains(special) =>
        LineDispatchKind.walkCrusherStop,
      LineActivation.cross when walkLiftSpecials.contains(special) =>
        LineDispatchKind.walkLift,
      LineActivation.cross when walkFloorSpecials.contains(special) =>
        LineDispatchKind.walkFloor,
      LineActivation.cross when walkStairSpecials.contains(special) =>
        LineDispatchKind.walkStair,
      LineActivation.cross when walkLightSpecials.contains(special) =>
        LineDispatchKind.walkLight,
      LineActivation.cross when walkTeleportSpecials.contains(special) =>
        LineDispatchKind.walkTeleport,
      LineActivation.cross when walkExitSpecials.contains(special) =>
        LineDispatchKind.walkExit,
      LineActivation.shoot when shootFloorSpecials.contains(special) =>
        LineDispatchKind.shootFloor,
      LineActivation.shoot when shootDoorSpecials.contains(special) =>
        LineDispatchKind.shootDoor,
      _ => null,
    };

/// Internal structural tripwire used by package tests. It compares the public
/// catalog with the classifier sets consumed by the three runtime dispatchers,
/// and also verifies that every classified floor special has target semantics.
/// This is deliberately not exported from doom_core.dart.
List<String> linedefDispatcherCoverageIssuesForTesting() {
  final Map<LineActivation, List<Set<int>>> classifiers =
      <LineActivation, List<Set<int>>>{
        LineActivation.use: <Set<int>>[
          useDoorSpecials,
          useCrusherSpecials,
          useDonutSpecials,
          useLiftSpecials,
          useFloorSpecials,
          useStairSpecials,
          useExitSpecials,
        ],
        LineActivation.cross: <Set<int>>[
          walkDoorSpecials,
          walkCrusherSpecials,
          walkCrusherStopSpecials,
          walkLiftSpecials,
          walkFloorSpecials,
          walkStairSpecials,
          walkLightSpecials,
          walkTeleportSpecials,
          walkExitSpecials,
        ],
        LineActivation.shoot: <Set<int>>[shootFloorSpecials, shootDoorSpecials],
      };
  final List<String> issues = <String>[];
  final Set<int> dispatched = <int>{};
  for (final MapEntry<LineActivation, List<Set<int>>> entry
      in classifiers.entries) {
    for (final Set<int> classifier in entry.value) {
      for (final int special in classifier) {
        if (!dispatched.add(special)) {
          issues.add('special $special has more than one activation path');
        }
        if (lineDispatchKind(special, entry.key) == null) {
          issues.add('special $special is not dispatched for ${entry.key}');
        }
      }
    }
  }
  if (!dispatched.containsAll(supportedLineSpecials) ||
      !supportedLineSpecials.containsAll(dispatched)) {
    issues.add('catalog and runtime classifier union differ');
  }
  final Set<int> classifiedFloors = <int>{
    ...useFloorSpecials,
    ...walkFloorSpecials,
    ...shootFloorSpecials,
  };
  if (!classifiedFloors.containsAll(floorTargetKinds.keys) ||
      !floorTargetKinds.keys.toSet().containsAll(classifiedFloors)) {
    issues.add('floor classifiers and target semantics differ');
  }
  if (!<int>{
    ...walkDoorSpecials,
    ...walkLiftSpecials,
    ...walkTeleportSpecials,
  }.containsAll(monsterWalkSpecials)) {
    issues.add('monster walk classifier contains an unsupported special');
  }
  return List<String>.unmodifiable(issues);
}
