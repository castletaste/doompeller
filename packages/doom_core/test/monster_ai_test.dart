import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

import 'specials_test.dart' show testMap, twoSectors, twoSides;

const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

Linedef _sightBlocker() => const Linedef(
  v1: 0,
  v2: 2,
  flags: LinedefFlags.blocking,
  special: 0,
  tag: 0,
  rightSidedef: 0,
  leftSidedef: kNoSidedef,
);

MapData _aroundCornerMap({int portalFlags = LinedefFlags.twoSided}) => testMap(
  sectors: twoSectors(),
  sides: twoSides(),
  lines: <Linedef>[
    _sightBlocker(),
    Linedef(
      v1: 2,
      v2: 1,
      flags: portalFlags,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: 1,
    ),
  ],
  things: const <Thing>[
    Thing(x: 32, y: 96, angle: 0, type: 1, flags: _skills),
    Thing(x: 200, y: 96, angle: 180, type: 3004, flags: _skills),
  ],
);

MobjView _monster(GameState game, String sprite) =>
    game.mobjs.firstWhere((MobjView actor) => actor.sprite == sprite);

MapData _obstacleMap() => MapData(
  name: 'OBSTACLE',
  vertices: const <MapVertex>[
    MapVertex(0, 0),
    MapVertex(256, 0),
    MapVertex(256, 256),
    MapVertex(0, 256),
    MapVertex(128, 96),
    MapVertex(128, 160),
  ],
  linedefs: const <Linedef>[
    Linedef(
      v1: 0,
      v2: 1,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
    Linedef(
      v1: 1,
      v2: 2,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
    Linedef(
      v1: 2,
      v2: 3,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
    Linedef(
      v1: 3,
      v2: 0,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
    Linedef(
      v1: 4,
      v2: 5,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
  ],
  sidedefs: const <Sidedef>[
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 0,
    ),
  ],
  sectors: const <Sector>[
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'F',
      ceilingFlat: 'C',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
  ],
  segs: const <Seg>[],
  subsectors: const <Subsector>[],
  nodes: const <BspNode>[],
  things: const <Thing>[
    Thing(x: 32, y: 128, angle: 0, type: 1, flags: _skills),
    Thing(x: 224, y: 128, angle: 180, type: 3004, flags: _skills),
  ],
  blockmap: null,
  reject: null,
);

MapData _openMap(List<Thing> things) => MapData(
  name: 'OPEN',
  vertices: const <MapVertex>[],
  linedefs: const <Linedef>[],
  sidedefs: const <Sidedef>[],
  sectors: const <Sector>[
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'F',
      ceilingFlat: 'C',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
  ],
  segs: const <Seg>[],
  subsectors: const <Subsector>[],
  nodes: const <BspNode>[],
  things: things,
  blockmap: null,
  reject: null,
);

MapData _firstVisitSoundMap() {
  const List<Sector> sectors = <Sector>[
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'F',
      ceilingFlat: 'C',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'F',
      ceilingFlat: 'C',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'F',
      ceilingFlat: 'C',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
    Sector(
      floorHeight: 0,
      ceilingHeight: 128,
      floorFlat: 'F',
      ceilingFlat: 'C',
      lightLevel: 160,
      special: 0,
      tag: 0,
    ),
  ];
  const List<Sidedef> sides = <Sidedef>[
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 0,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 1,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 2,
    ),
    Sidedef(
      xOffset: 0,
      yOffset: 0,
      upperTexture: '-',
      lowerTexture: '-',
      middleTexture: '-',
      sector: 3,
    ),
  ];
  return MapData(
    name: 'SOUND_FIRST_VISIT',
    vertices: const <MapVertex>[
      MapVertex(-16, -16),
      MapVertex(-16, 16),
      MapVertex(1016, -16),
      MapVertex(1016, 16),
      MapVertex(500, -128),
      MapVertex(500, 128),
      MapVertex(0, 1000),
      MapVertex(32, 1000),
      MapVertex(64, 1000),
      MapVertex(96, 1000),
    ],
    linedefs: const <Linedef>[
      Linedef(
        v1: 0,
        v2: 1,
        flags: LinedefFlags.blocking,
        special: 0,
        tag: 0,
        rightSidedef: 0,
        leftSidedef: kNoSidedef,
      ),
      Linedef(
        v1: 2,
        v2: 3,
        flags: LinedefFlags.blocking,
        special: 0,
        tag: 0,
        rightSidedef: 3,
        leftSidedef: kNoSidedef,
      ),
      Linedef(
        v1: 4,
        v2: 5,
        flags: LinedefFlags.blocking,
        special: 0,
        tag: 0,
        rightSidedef: 0,
        leftSidedef: kNoSidedef,
      ),
      Linedef(
        v1: 6,
        v2: 7,
        flags: LinedefFlags.twoSided | LinedefFlags.soundBlock,
        special: 0,
        tag: 0,
        rightSidedef: 0,
        leftSidedef: 1,
      ),
      Linedef(
        v1: 7,
        v2: 8,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 0,
        leftSidedef: 2,
      ),
      Linedef(
        v1: 8,
        v2: 9,
        flags: LinedefFlags.twoSided,
        special: 0,
        tag: 0,
        rightSidedef: 2,
        leftSidedef: 1,
      ),
      Linedef(
        v1: 6,
        v2: 9,
        flags: LinedefFlags.twoSided | LinedefFlags.soundBlock,
        special: 0,
        tag: 0,
        rightSidedef: 1,
        leftSidedef: 3,
      ),
    ],
    sidedefs: sides,
    sectors: sectors,
    segs: const <Seg>[],
    subsectors: const <Subsector>[],
    nodes: const <BspNode>[],
    things: const <Thing>[
      Thing(x: 0, y: 0, angle: 0, type: 1, flags: _skills),
      Thing(x: 1000, y: 0, angle: 180, type: 3004, flags: _skills),
    ],
    blockmap: null,
    reject: null,
  );
}

void _firePistol(GameState game) {
  for (var tic = 0; tic < 5; tic++) {
    game.runTic(const TicCmd(buttons: Buttons.attack));
  }
}

void main() {
  test('AI ruleset and ambush state participate in replay hashing', () {
    final MapData ordinary = testMap(
      things: const <Thing>[
        Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
        Thing(x: 96, y: 64, angle: 180, type: 3004, flags: _skills),
      ],
    );
    final MapData ambush = testMap(
      things: const <Thing>[
        Thing(x: 32, y: 64, angle: 0, type: 1, flags: _skills),
        Thing(
          x: 96,
          y: 64,
          angle: 180,
          type: 3004,
          flags: _skills | ThingFlags.ambush,
        ),
      ],
    );
    expect(
      GameState.start(
        ordinary,
        const GameConfig(maxSoundPropagationVisits: 1),
      ).hashState(),
      isNot(
        GameState.start(
          ordinary,
          const GameConfig(maxSoundPropagationVisits: 2),
        ).hashState(),
      ),
    );
    expect(
      GameState.start(ordinary, const GameConfig()).hashState(),
      isNot(GameState.start(ambush, const GameConfig()).hashState()),
    );
  });

  test('weapon noise wakes an unseen monster in an adjacent sector', () {
    final GameState game = GameState.start(
      _aroundCornerMap(),
      const GameConfig(),
      seed: 7,
    );
    final int startX = _monster(game, 'POSS').x;
    for (var tic = 0; tic < 40; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(_monster(game, 'POSS').x, startX, reason: 'sight is blocked');

    _firePistol(game);
    for (var tic = 0; tic < 80; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(_monster(game, 'POSS').x, isNot(startX));
  });

  test('weapon noise crosses one ML_SOUNDBLOCK but not two', () {
    final List<Sector> sectors = <Sector>[
      ...twoSectors(),
      const Sector(
        floorHeight: 0,
        ceilingHeight: 128,
        floorFlat: 'F',
        ceilingFlat: 'C',
        lightLevel: 160,
        special: 0,
        tag: 0,
      ),
    ];
    final List<Sidedef> sides = <Sidedef>[
      ...twoSides(),
      const Sidedef(
        xOffset: 0,
        yOffset: 0,
        upperTexture: '-',
        lowerTexture: '-',
        middleTexture: '-',
        sector: 2,
      ),
    ];
    final GameState game = GameState.start(
      testMap(
        sectors: sectors,
        sides: sides,
        lines: <Linedef>[
          _sightBlocker(),
          const Linedef(
            v1: 2,
            v2: 1,
            flags: LinedefFlags.twoSided | LinedefFlags.soundBlock,
            special: 0,
            tag: 0,
            rightSidedef: 0,
            leftSidedef: 1,
          ),
          const Linedef(
            v1: 5,
            v2: 4,
            flags: LinedefFlags.twoSided | LinedefFlags.soundBlock,
            special: 0,
            tag: 0,
            rightSidedef: 1,
            leftSidedef: 2,
          ),
        ],
        things: const <Thing>[
          Thing(x: 32, y: 96, angle: 0, type: 1, flags: _skills),
          Thing(x: 200, y: 96, angle: 180, type: 3004, flags: _skills),
          Thing(x: 300, y: 96, angle: 180, type: 9, flags: _skills),
        ],
      ),
      const GameConfig(),
      seed: 7,
    );
    final int oneBlockStart = _monster(game, 'POSS').x;
    final int twoBlockStart = _monster(game, 'SPOS').x;
    _firePistol(game);
    for (var tic = 0; tic < 100; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(
      _monster(game, 'POSS').x,
      isNot(oneBlockStart),
      reason: 'one sound-blocking boundary must still pass the alert',
    );
    expect(
      _monster(game, 'SPOS').x,
      twoBlockStart,
      reason: 'a second sound-blocking boundary must stop the alert',
    );
  });

  test('sound traversal keeps the first route to a sector', () {
    final GameState game = GameState.start(
      _firstVisitSoundMap(),
      const GameConfig(),
      seed: 7,
    );
    final int startX = _monster(game, 'POSS').x;
    _firePistol(game);
    for (var tic = 0; tic < 100; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(
      _monster(game, 'POSS').x,
      startX,
      reason: 'a later cheaper route must not reopen the first visited sector',
    );
  });

  test('max-sector shot tics stay close to idle with budget one', () {
    final GameState game = GameState.start(
      MapData(
        name: 'SOUND_SCALE',
        vertices: const <MapVertex>[],
        linedefs: const <Linedef>[],
        sidedefs: const <Sidedef>[],
        sectors: List<Sector>.filled(
          65535,
          const Sector(
            floorHeight: 0,
            ceilingHeight: 128,
            floorFlat: 'F',
            ceilingFlat: 'C',
            lightLevel: 160,
            special: 0,
            tag: 0,
          ),
          growable: false,
        ),
        segs: const <Seg>[],
        subsectors: const <Subsector>[],
        nodes: const <BspNode>[],
        things: const <Thing>[
          Thing(x: 0, y: 0, angle: 0, type: 1, flags: _skills),
        ],
        blockmap: null,
        reject: null,
      ),
      const GameConfig(monsters: false, maxSoundPropagationVisits: 1),
    );
    final List<int> shotTics = <int>[];
    final List<int> idleTics = <int>[];
    var bullets = game.player.ammo.bullets;
    while (shotTics.length < 45) {
      final Stopwatch clock = Stopwatch()..start();
      game.runTic(const TicCmd(buttons: Buttons.attack));
      clock.stop();
      final int nextBullets = game.player.ammo.bullets;
      (nextBullets < bullets ? shotTics : idleTics).add(
        clock.elapsedMicroseconds,
      );
      bullets = nextBullets;
    }
    int median(List<int> values) {
      values.sort();
      return values[values.length ~/ 2];
    }

    final int shotMedian = median(shotTics.sublist(5));
    final int idleMedian = median(idleTics);
    expect(
      shotMedian,
      lessThan(idleMedian * 3 ~/ 2 + 50),
      reason: 'shot median: $shotMedian us; idle median: $idleMedian us',
    );
  });

  test('sound traversal obeys the hostile-map sector visit budget', () {
    final GameState game = GameState.start(
      _aroundCornerMap(),
      const GameConfig(maxSoundPropagationVisits: 1),
      seed: 7,
    );
    final int startX = _monster(game, 'POSS').x;
    _firePistol(game);
    for (var tic = 0; tic < 100; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(_monster(game, 'POSS').x, startX);
  });

  test('blocked monster full-search order follows the shared RNG', () {
    final Set<int> detours = <int>{};
    for (var seed = 0; seed < 32; seed++) {
      final GameState game = GameState.start(
        _obstacleMap(),
        const GameConfig(),
        seed: seed,
      );
      _firePistol(game);
      final MobjView start = _monster(game, 'POSS');
      MobjView moved = start;
      for (var tic = 0; tic < 100 && moved.y == start.y; tic++) {
        game.runTic(TicCmd.empty);
        moved = _monster(game, 'POSS');
      }
      expect(moved.y, isNot(start.y), reason: 'seed $seed never detoured');
      detours.add(moved.angle);
    }
    expect(detours, contains(kAng45));
    expect(detours, contains(normalizeAngle(kAng270 + kAng45)));
  });

  test('missile chance falls with distance without actor-id scheduling', () {
    int attacksAt(int x) {
      var attacks = 0;
      for (var seed = 0; seed < 64; seed++) {
        final GameState game = GameState.start(
          _openMap(<Thing>[
            const Thing(x: 0, y: 0, angle: 0, type: 1, flags: _skills),
            Thing(x: x, y: 0, angle: 180, type: 3004, flags: _skills),
          ]),
          const GameConfig(),
          seed: seed,
        );
        game.runTic(TicCmd.empty);
        if (_monster(game, 'POSS').frame == 4) attacks++;
      }
      return attacks;
    }

    final int near = attacksAt(72);
    final int far = attacksAt(300);
    expect(near, greaterThan(50));
    expect(far, greaterThan(0));
    expect(far, lessThan(near * 3 ~/ 4), reason: 'near=$near far=$far');
  });

  test('JUSTATTACKED forces a chase step before another missile check', () {
    final GameState game = GameState.start(
      _openMap(const <Thing>[
        Thing(x: 0, y: 0, angle: 0, type: 1, flags: _skills),
        Thing(x: 72, y: 0, angle: 180, type: 3004, flags: _skills),
      ]),
      const GameConfig(),
      seed: 0,
    );
    game.runTic(TicCmd.empty);
    expect(_monster(game, 'POSS').frame, 4);
    for (var tic = 0; tic < 26; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(
      _monster(game, 'POSS').frame,
      0,
      reason: 'the completed attack must return to chase, not immediately fire',
    );
  });

  test('monster hit redirects a different species onto the attacker', () {
    final GameState game = GameState.start(
      testMap(
        things: const <Thing>[
          Thing(x: 16, y: 64, angle: 0, type: 1, flags: _skills),
          Thing(x: 112, y: 64, angle: 180, type: 3004, flags: _skills),
          Thing(x: 64, y: 64, angle: 180, type: 3001, flags: _skills),
        ],
      ),
      const GameConfig(),
      seed: 13,
    );
    for (
      var tic = 0;
      tic < 1000 && _monster(game, 'POSS').health == 20;
      tic++
    ) {
      game.runTic(TicCmd.empty);
    }
    expect(_monster(game, 'POSS').health, lessThan(20));
  });

  test('same-species hit redirects while the victim threshold is zero', () {
    final GameState game = GameState.start(
      _openMap(const <Thing>[
        Thing(x: 0, y: 0, angle: 0, type: 1, flags: _skills),
        Thing(x: 160, y: 0, angle: 180, type: 3004, flags: _skills),
        Thing(x: 80, y: 0, angle: 180, type: 3004, flags: _skills),
      ]),
      const GameConfig(),
      seed: 13,
    );
    final List<MobjView> monsters = game.mobjs
        .where((MobjView actor) => actor.sprite == 'POSS')
        .toList();
    final int rearId = monsters.first.id;
    for (var tic = 0; tic < 1000; tic++) {
      game.runTic(TicCmd.empty);
      final MobjView rear = game.mobjs.firstWhere(
        (MobjView actor) => actor.id == rearId,
      );
      if (rear.health < 20) break;
    }
    expect(
      game.mobjs.firstWhere((MobjView actor) => actor.id == rearId).health,
      lessThan(20),
    );
  });

  test('dead player ignores input while view descends and faces killer', () {
    final GameState game = GameState.start(
      testMap(
        things: const <Thing>[
          Thing(x: 32, y: 64, angle: 180, type: 1, flags: _skills),
          Thing(x: 72, y: 64, angle: 180, type: 3001, flags: _skills),
          Thing(x: 76, y: 40, angle: 180, type: 3001, flags: _skills),
          Thing(x: 76, y: 88, angle: 180, type: 3001, flags: _skills),
        ],
      ),
      const GameConfig(),
      seed: 3,
    );
    for (var tic = 0; tic < 2000 && game.player.health > 0; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(game.player.health, 0);
    final PlayerView dead = game.player;
    for (var tic = 0; tic < 40; tic++) {
      game.runTic(
        const TicCmd(
          forwardMove: 50,
          sideMove: 50,
          angleTurn: 0x400,
          buttons: Buttons.attack,
        ),
      );
    }
    expect(game.player.x, dead.x);
    expect(game.player.y, dead.y);
    expect(
      game.player.angle,
      isIn(<int>{
        0,
        Trig.atan2(toFixed(-24), toFixed(44)),
        Trig.atan2(toFixed(24), toFixed(44)),
      }),
    );
    expect(game.player.ammo.bullets, dead.ammo.bullets);
    expect(game.player.viewZ, lessThan(dead.viewZ));
  });
}
