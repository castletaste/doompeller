import 'resources.dart';
import 'failures.dart';
import 'wad.dart';

/// Namespace used by a classic picture animation.
enum DoomAnimationKind { flat, wall }

/// Data-only description of a classic animation range.
class DoomAnimationDefinition {
  const DoomAnimationDefinition({
    required this.kind,
    required this.startName,
    required this.endName,
    this.speed = 8,
  });

  final DoomAnimationKind kind;
  final String startName;
  final String endName;
  final int speed;
}

/// A definition resolved against the actual resource ordering of a WAD set.
class DoomAnimation {
  const DoomAnimation({required this.definition, required this.frames});

  final DoomAnimationDefinition definition;
  final List<String> frames;
}

/// A definition that cannot be animated safely and therefore stays static.
class DoomAnimationFailure {
  const DoomAnimationFailure(this.definition, this.reason);

  final DoomAnimationDefinition definition;
  final String reason;
}

class DoomAnimationResolution {
  const DoomAnimationResolution({
    required this.animations,
    required this.failures,
  });

  final List<DoomAnimation> animations;
  final List<DoomAnimationFailure> failures;
}

/// One classic two-state wall switch pair.
class DoomSwitchPair {
  const DoomSwitchPair(this.offName, this.onName);

  final String offName;
  final String onName;

  String? opposite(String name) {
    final String key = normaliseLumpName(name);
    if (key == offName) return onName;
    if (key == onName) return offName;
    return null;
  }
}

// Re-expressed as Dart data from the published vanilla engine tables. No C
// implementation is embedded or translated here.
const List<DoomAnimationDefinition> vanillaDoomAnimations =
    <DoomAnimationDefinition>[
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'NUKAGE1',
        endName: 'NUKAGE3',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'FWATER1',
        endName: 'FWATER4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'SWATER1',
        endName: 'SWATER4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'LAVA1',
        endName: 'LAVA4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'BLOOD1',
        endName: 'BLOOD3',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'RROCK05',
        endName: 'RROCK08',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'SLIME01',
        endName: 'SLIME04',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'SLIME05',
        endName: 'SLIME08',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.flat,
        startName: 'SLIME09',
        endName: 'SLIME12',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'BLODGR1',
        endName: 'BLODGR4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'SLADRIP1',
        endName: 'SLADRIP3',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'BLODRIP1',
        endName: 'BLODRIP4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'FIREWALA',
        endName: 'FIREWALL',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'GSTFONT1',
        endName: 'GSTFONT3',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'FIRELAV3',
        endName: 'FIRELAVA',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'FIREMAG1',
        endName: 'FIREMAG3',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'FIREBLU1',
        endName: 'FIREBLU2',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'ROCKRED1',
        endName: 'ROCKRED3',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'BFALL1',
        endName: 'BFALL4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'SFALL1',
        endName: 'SFALL4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'WFALL1',
        endName: 'WFALL4',
      ),
      DoomAnimationDefinition(
        kind: DoomAnimationKind.wall,
        startName: 'DBRAIN1',
        endName: 'DBRAIN4',
      ),
    ];

const List<DoomSwitchPair> vanillaDoomSwitches = <DoomSwitchPair>[
  DoomSwitchPair('SW1BRCOM', 'SW2BRCOM'),
  DoomSwitchPair('SW1BRN1', 'SW2BRN1'),
  DoomSwitchPair('SW1BRN2', 'SW2BRN2'),
  DoomSwitchPair('SW1BRNGN', 'SW2BRNGN'),
  DoomSwitchPair('SW1BROWN', 'SW2BROWN'),
  DoomSwitchPair('SW1COMM', 'SW2COMM'),
  DoomSwitchPair('SW1COMP', 'SW2COMP'),
  DoomSwitchPair('SW1DIRT', 'SW2DIRT'),
  DoomSwitchPair('SW1EXIT', 'SW2EXIT'),
  DoomSwitchPair('SW1GRAY', 'SW2GRAY'),
  DoomSwitchPair('SW1GRAY1', 'SW2GRAY1'),
  DoomSwitchPair('SW1METAL', 'SW2METAL'),
  DoomSwitchPair('SW1PIPE', 'SW2PIPE'),
  DoomSwitchPair('SW1SLAD', 'SW2SLAD'),
  DoomSwitchPair('SW1STARG', 'SW2STARG'),
  DoomSwitchPair('SW1STON1', 'SW2STON1'),
  DoomSwitchPair('SW1STON2', 'SW2STON2'),
  DoomSwitchPair('SW1STONE', 'SW2STONE'),
  DoomSwitchPair('SW1STRTN', 'SW2STRTN'),
  DoomSwitchPair('SW1BLUE', 'SW2BLUE'),
  DoomSwitchPair('SW1CMT', 'SW2CMT'),
  DoomSwitchPair('SW1GARG', 'SW2GARG'),
  DoomSwitchPair('SW1GSTON', 'SW2GSTON'),
  DoomSwitchPair('SW1HOT', 'SW2HOT'),
  DoomSwitchPair('SW1LION', 'SW2LION'),
  DoomSwitchPair('SW1SATYR', 'SW2SATYR'),
  DoomSwitchPair('SW1SKIN', 'SW2SKIN'),
  DoomSwitchPair('SW1VINE', 'SW2VINE'),
  DoomSwitchPair('SW1WOOD', 'SW2WOOD'),
  DoomSwitchPair('SW1PANEL', 'SW2PANEL'),
  DoomSwitchPair('SW1ROCK', 'SW2ROCK'),
  DoomSwitchPair('SW1MET2', 'SW2MET2'),
  DoomSwitchPair('SW1WDMET', 'SW2WDMET'),
  DoomSwitchPair('SW1BRIK', 'SW2BRIK'),
  DoomSwitchPair('SW1MOD1', 'SW2MOD1'),
  DoomSwitchPair('SW1ZIM', 'SW2ZIM'),
  DoomSwitchPair('SW1STON6', 'SW2STON6'),
  DoomSwitchPair('SW1TEK', 'SW2TEK'),
  DoomSwitchPair('SW1MARB', 'SW2MARB'),
  DoomSwitchPair('SW1SKULL', 'SW2SKULL'),
];

DoomAnimationResolution resolveDoomAnimations(
  WadResources resources, {
  List<DoomAnimationDefinition> definitions = vanillaDoomAnimations,
}) {
  final List<DoomAnimation> animations = <DoomAnimation>[];
  final List<DoomAnimationFailure> failures = <DoomAnimationFailure>[];
  for (final DoomAnimationDefinition definition in definitions) {
    final List<String> order = definition.kind == DoomAnimationKind.flat
        ? resources.flatDirectoryOrder
        : resources.textureNames;
    final int first = order.lastIndexOf(definition.startName);
    final int last = order.lastIndexOf(definition.endName);
    // Vanilla treats a missing start as "this episode does not provide this
    // animation". It is not a compilation problem until the start exists.
    if (first < 0) {
      continue;
    }
    if (last < first) {
      failures.add(
        DoomAnimationFailure(definition, 'missing or reversed endpoint'),
      );
      continue;
    }
    final List<String> frames = order.sublist(first, last + 1);
    var complete = frames.length >= 2;
    if (complete) {
      try {
        complete = frames.every(
          (String name) => definition.kind == DoomAnimationKind.flat
              ? resources.flat(name) != null
              : resources.composite(name) != null,
        );
      } on DoomFailure {
        complete = false;
      }
    }
    if (!complete) {
      failures.add(DoomAnimationFailure(definition, 'missing frame data'));
      continue;
    }
    animations.add(
      DoomAnimation(
        definition: definition,
        frames: List<String>.unmodifiable(frames),
      ),
    );
  }
  return DoomAnimationResolution(
    animations: List<DoomAnimation>.unmodifiable(animations),
    failures: List<DoomAnimationFailure>.unmodifiable(failures),
  );
}
