import 'mobj_info.dart';

/// Behaviour phase exposed by a live actor.
enum MobjState {
  spawn,
  see,
  melee,
  missile,
  pain,
  death,
  gibbedDeath,
  raise,
  dead,
}

/// Deterministic gameplay callback invoked when an actor enters a frame.
enum MobjStateAction {
  monsterHitscan,
  monsterMelee,
  monsterMissile,
  barrelExplode,
}

/// One clean-room actor animation record.
///
/// Frame zero is sprite lamp A. A negative [tics] value keeps the frame
/// forever. [next] is the stable table id of the following record.
final class MobjFrameState {
  const MobjFrameState({
    required this.id,
    required this.name,
    required this.phase,
    required this.sprite,
    required this.frame,
    required this.tics,
    required this.fullBright,
    required this.next,
    this.action,
    this.removeOnExpiry = false,
  });

  final int id;
  final String name;
  final MobjState phase;
  final String sprite;
  final int frame;
  final int tics;
  final bool fullBright;
  final int? next;
  final MobjStateAction? action;
  final bool removeOnExpiry;
}

/// State records for the E1M1 monsters and the projectile/effect actors the
/// current runtime can create.
///
/// The values were independently expressed as Dart data from the published
/// Doom state descriptions. No engine code or commercial content is embedded.
abstract final class MobjStateTable {
  static final _Catalog _catalog = _buildCatalog();

  static MobjFrameState? state(int id) => _catalog.states[id];

  static int? start(MobjType type, MobjState phase) =>
      _catalog.starts[(type, phase)];

  /// Selects the first blood frame from impact damage without consuming RNG.
  /// Light hits skip directly to the later, shorter part of the same chain.
  static int bloodImpactStart(int damage) {
    if (damage <= 0) {
      throw ArgumentError.value(damage, 'damage', 'must be positive');
    }
    final int first = start(MobjType.blood, MobjState.spawn)!;
    if (damage < 9) return first + 2;
    if (damage < 13) return first + 1;
    return first;
  }
}

final class _Frame {
  const _Frame(this.frame, this.tics, {this.fullBright = false, this.action});

  final int frame;
  final int tics;
  final bool fullBright;
  final MobjStateAction? action;
}

final class _Catalog {
  const _Catalog(this.states, this.starts);

  final List<MobjFrameState> states;
  final Map<(MobjType, MobjState), int> starts;
}

final class _TableBuilder {
  final List<MobjFrameState> states = <MobjFrameState>[];
  final Map<(MobjType, MobjState), int> starts = <(MobjType, MobjState), int>{};

  int chain({
    required MobjType type,
    required MobjState phase,
    required String name,
    required String sprite,
    required List<_Frame> frames,
    bool loop = false,
    int? next,
    bool removeOnExpiry = false,
    bool register = true,
  }) {
    final int first = states.length;
    if (register) starts[(type, phase)] = first;
    for (var index = 0; index < frames.length; index++) {
      final bool last = index == frames.length - 1;
      final _Frame frame = frames[index];
      states.add(
        MobjFrameState(
          id: states.length,
          name: '${name}_${index + 1}',
          phase:
              frame.tics < 0 &&
                  (phase == MobjState.death || phase == MobjState.gibbedDeath)
              ? MobjState.dead
              : phase,
          sprite: sprite,
          frame: frame.frame,
          tics: frame.tics,
          fullBright: frame.fullBright,
          next: last ? (loop ? first : next) : states.length + 1,
          action: frame.action,
          removeOnExpiry: last && removeOnExpiry,
        ),
      );
    }
    return first;
  }
}

_Catalog _buildCatalog() {
  final _TableBuilder b = _TableBuilder();

  void monster({
    required MobjType type,
    required String sprite,
    required int walkTics,
    required List<_Frame> missile,
    required List<_Frame> melee,
    required List<_Frame> pain,
    required List<_Frame> death,
    required List<_Frame> gibbedDeath,
    required List<_Frame> raise,
  }) {
    b.chain(
      type: type,
      phase: MobjState.spawn,
      name: '${sprite}_STAND',
      sprite: sprite,
      frames: const <_Frame>[_Frame(0, 10), _Frame(1, 10)],
      loop: true,
    );
    final int see = b.chain(
      type: type,
      phase: MobjState.see,
      name: '${sprite}_WALK',
      sprite: sprite,
      frames: <_Frame>[
        _Frame(0, walkTics),
        _Frame(0, walkTics),
        _Frame(1, walkTics),
        _Frame(1, walkTics),
        _Frame(2, walkTics),
        _Frame(2, walkTics),
        _Frame(3, walkTics),
        _Frame(3, walkTics),
      ],
      loop: true,
    );
    if (melee.isNotEmpty) {
      b.chain(
        type: type,
        phase: MobjState.melee,
        name: '${sprite}_MELEE',
        sprite: sprite,
        frames: melee,
        next: see,
      );
    }
    if (missile.isNotEmpty) {
      b.chain(
        type: type,
        phase: MobjState.missile,
        name: '${sprite}_MISSILE',
        sprite: sprite,
        frames: missile,
        next: see,
      );
    }
    b.chain(
      type: type,
      phase: MobjState.pain,
      name: '${sprite}_PAIN',
      sprite: sprite,
      frames: pain,
      next: see,
    );
    b.chain(
      type: type,
      phase: MobjState.death,
      name: '${sprite}_DEATH',
      sprite: sprite,
      frames: death,
    );
    b.chain(
      type: type,
      phase: MobjState.gibbedDeath,
      name: '${sprite}_GIB',
      sprite: sprite,
      frames: gibbedDeath,
    );
    b.chain(
      type: type,
      phase: MobjState.raise,
      name: '${sprite}_RAISE',
      sprite: sprite,
      frames: raise,
      next: see,
    );
  }

  monster(
    type: MobjType.possessed,
    sprite: 'POSS',
    walkTics: 4,
    melee: const <_Frame>[],
    missile: const <_Frame>[
      _Frame(4, 10),
      _Frame(5, 8, action: MobjStateAction.monsterHitscan),
      _Frame(4, 8),
    ],
    pain: const <_Frame>[_Frame(6, 3), _Frame(6, 3)],
    death: const <_Frame>[
      _Frame(7, 5),
      _Frame(8, 5),
      _Frame(9, 5),
      _Frame(10, 5),
      _Frame(11, -1),
    ],
    gibbedDeath: const <_Frame>[
      _Frame(12, 5),
      _Frame(13, 5),
      _Frame(14, 5),
      _Frame(15, 5),
      _Frame(16, 5),
      _Frame(17, 5),
      _Frame(18, 5),
      _Frame(19, 5),
      _Frame(20, -1),
    ],
    raise: const <_Frame>[
      _Frame(10, 5),
      _Frame(9, 5),
      _Frame(8, 5),
      _Frame(7, 5),
    ],
  );
  monster(
    type: MobjType.shotguy,
    sprite: 'SPOS',
    walkTics: 3,
    melee: const <_Frame>[],
    missile: const <_Frame>[
      _Frame(4, 10),
      _Frame(5, 10, fullBright: true, action: MobjStateAction.monsterHitscan),
      _Frame(4, 10),
    ],
    pain: const <_Frame>[_Frame(6, 3), _Frame(6, 3)],
    death: const <_Frame>[
      _Frame(7, 5),
      _Frame(8, 5),
      _Frame(9, 5),
      _Frame(10, 5),
      _Frame(11, -1),
    ],
    gibbedDeath: const <_Frame>[
      _Frame(12, 5),
      _Frame(13, 5),
      _Frame(14, 5),
      _Frame(15, 5),
      _Frame(16, 5),
      _Frame(17, 5),
      _Frame(18, 5),
      _Frame(19, 5),
      _Frame(20, -1),
    ],
    raise: const <_Frame>[
      _Frame(11, 5),
      _Frame(10, 5),
      _Frame(9, 5),
      _Frame(8, 5),
      _Frame(7, 5),
    ],
  );
  monster(
    type: MobjType.troop,
    sprite: 'TROO',
    walkTics: 3,
    melee: const <_Frame>[
      _Frame(4, 8),
      _Frame(5, 8),
      _Frame(6, 6, action: MobjStateAction.monsterMelee),
    ],
    missile: const <_Frame>[
      _Frame(4, 8),
      _Frame(5, 8),
      _Frame(6, 6, action: MobjStateAction.monsterMissile),
    ],
    pain: const <_Frame>[_Frame(7, 2), _Frame(7, 2)],
    death: const <_Frame>[
      _Frame(8, 8),
      _Frame(9, 8),
      _Frame(10, 6),
      _Frame(11, 6),
      _Frame(12, -1),
    ],
    gibbedDeath: const <_Frame>[
      _Frame(13, 5),
      _Frame(14, 5),
      _Frame(15, 5),
      _Frame(16, 5),
      _Frame(17, 5),
      _Frame(18, 5),
      _Frame(19, 5),
      _Frame(20, -1),
    ],
    raise: const <_Frame>[
      _Frame(12, 8),
      _Frame(11, 8),
      _Frame(10, 6),
      _Frame(9, 6),
      _Frame(8, 6),
    ],
  );

  b.chain(
    type: MobjType.barrel,
    phase: MobjState.spawn,
    name: 'BARREL_STAND',
    sprite: 'BAR1',
    frames: const <_Frame>[_Frame(0, 6), _Frame(1, 6)],
    loop: true,
  );
  b.chain(
    type: MobjType.barrel,
    phase: MobjState.death,
    name: 'BARREL_EXPLODE',
    sprite: 'BEXP',
    frames: const <_Frame>[
      _Frame(0, 5, fullBright: true),
      _Frame(1, 5, fullBright: true),
      _Frame(2, 5, fullBright: true),
      _Frame(3, 10, fullBright: true, action: MobjStateAction.barrelExplode),
      _Frame(4, 10, fullBright: true),
    ],
    removeOnExpiry: true,
  );

  b.chain(
    type: MobjType.troopshot,
    phase: MobjState.spawn,
    name: 'IMP_BALL_FLY',
    sprite: 'BAL1',
    frames: const <_Frame>[
      _Frame(0, 4, fullBright: true),
      _Frame(1, 4, fullBright: true),
    ],
    loop: true,
  );
  b.chain(
    type: MobjType.troopshot,
    phase: MobjState.death,
    name: 'IMP_BALL_IMPACT',
    sprite: 'BAL1',
    frames: const <_Frame>[
      _Frame(2, 6, fullBright: true),
      _Frame(3, 6, fullBright: true),
      _Frame(4, 6, fullBright: true),
    ],
    removeOnExpiry: true,
  );

  b.chain(
    type: MobjType.puff,
    phase: MobjState.spawn,
    name: 'BULLET_PUFF',
    sprite: 'PUFF',
    frames: const <_Frame>[
      _Frame(0, 4, fullBright: true),
      _Frame(1, 4),
      _Frame(2, 4),
      _Frame(3, 4),
    ],
    removeOnExpiry: true,
  );
  b.chain(
    type: MobjType.blood,
    phase: MobjState.spawn,
    name: 'BLOOD_SPATTER',
    sprite: 'BLUD',
    frames: const <_Frame>[_Frame(2, 8), _Frame(1, 8), _Frame(0, 8)],
    removeOnExpiry: true,
  );

  return _Catalog(
    List<MobjFrameState>.unmodifiable(b.states),
    Map<(MobjType, MobjState), int>.unmodifiable(b.starts),
  );
}
