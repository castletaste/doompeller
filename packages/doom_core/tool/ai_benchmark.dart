import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';

const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

void main() {
  _warmUp();

  final MapData hostile = _hostileSoundMap();
  final _Percentiles sound = _measureShotTics(hostile);
  print(
    'sound sectors=${hostile.sectors.length} budget=1 '
    'samples=${sound.count} p50_us=${sound.p50} p95_us=${sound.p95}',
  );

  final MapData arena = _monsterScaleMap();
  final _Percentiles ai = _measureMonsterTics(arena);
  print(
    'ai sectors=${arena.sectors.length} lines=${arena.linedefs.length} '
    'monsters=32 samples=${ai.count} p50_us=${ai.p50} p95_us=${ai.p95}',
  );
}

void _warmUp() {
  final GameState game = GameState.start(
    _emptyMap(sectorCount: 8),
    const GameConfig(maxSoundPropagationVisits: 1),
    seed: 7,
  );
  for (var tic = 0; tic < 300; tic++) {
    game.runTic(const TicCmd(buttons: Buttons.attack));
  }
}

_Percentiles _measureShotTics(MapData map) {
  final GameState game = GameState.start(
    map,
    const GameConfig(monsters: false, maxSoundPropagationVisits: 1),
    seed: 7,
  );
  final List<int> samples = <int>[];
  var bullets = game.player.ammo.bullets;
  while (samples.length < 45) {
    final Stopwatch clock = Stopwatch()..start();
    game.runTic(const TicCmd(buttons: Buttons.attack));
    clock.stop();
    final int nextBullets = game.player.ammo.bullets;
    if (nextBullets < bullets) samples.add(clock.elapsedMicroseconds);
    bullets = nextBullets;
  }
  return _percentiles(samples.sublist(5));
}

_Percentiles _measureMonsterTics(MapData map) {
  final GameState game = GameState.start(map, const GameConfig(), seed: 11);
  for (var tic = 0; tic < 5; tic++) {
    game.runTic(const TicCmd(buttons: Buttons.attack));
  }
  for (var tic = 0; tic < 100; tic++) {
    game.runTic(TicCmd.empty);
  }
  final List<int> samples = <int>[];
  for (var tic = 0; tic < 500; tic++) {
    final Stopwatch clock = Stopwatch()..start();
    game.runTic(TicCmd.empty);
    clock.stop();
    samples.add(clock.elapsedMicroseconds);
  }
  return _percentiles(samples);
}

_Percentiles _percentiles(List<int> samples) {
  samples.sort();
  int at(double fraction) {
    final int rank = (samples.length * fraction).ceil() - 1;
    return samples[rank.clamp(0, samples.length - 1)];
  }

  return _Percentiles(samples.length, at(0.50), at(0.95));
}

MapData _hostileSoundMap() => _emptyMap(sectorCount: 65535);

MapData _emptyMap({required int sectorCount}) => MapData(
  name: 'SOUND_STRESS',
  vertices: const <MapVertex>[],
  linedefs: const <Linedef>[],
  sidedefs: const <Sidedef>[],
  sectors: List<Sector>.filled(sectorCount, _sector, growable: false),
  segs: const <Seg>[],
  subsectors: const <Subsector>[],
  nodes: const <BspNode>[],
  things: const <Thing>[
    Thing(x: 0, y: 0, angle: 0, type: 1, flags: _allSkills),
  ],
  blockmap: null,
  reject: null,
);

MapData _monsterScaleMap() {
  final List<MapVertex> vertices = <MapVertex>[
    const MapVertex(768, 0),
    const MapVertex(768, 2048),
  ];
  final List<Linedef> lines = <Linedef>[
    const Linedef(
      v1: 0,
      v2: 1,
      flags: LinedefFlags.blocking,
      special: 0,
      tag: 0,
      rightSidedef: 0,
      leftSidedef: kNoSidedef,
    ),
  ];
  for (var index = 1; index < 500; index++) {
    final int first = vertices.length;
    final int x = 4096 + index * 4;
    vertices.add(MapVertex(x, 4096));
    vertices.add(MapVertex(x + 1, 4096));
    lines.add(
      Linedef(
        v1: first,
        v2: first + 1,
        flags: LinedefFlags.blocking,
        special: 0,
        tag: 0,
        rightSidedef: 0,
        leftSidedef: kNoSidedef,
      ),
    );
  }

  final List<Thing> things = <Thing>[
    const Thing(x: 256, y: 1024, angle: 0, type: 1, flags: _allSkills),
  ];
  for (var index = 0; index < 32; index++) {
    things.add(
      Thing(
        x: 1024 + (index % 8) * 96,
        y: 352 + (index ~/ 8) * 128,
        angle: 180,
        type: 3004,
        flags: _allSkills,
      ),
    );
  }

  return MapData(
    name: 'AI_SCALE',
    vertices: vertices,
    linedefs: lines,
    sidedefs: const <Sidedef>[_side],
    sectors: List<Sector>.filled(120, _sector, growable: false),
    segs: const <Seg>[],
    subsectors: const <Subsector>[],
    nodes: const <BspNode>[],
    things: things,
    blockmap: null,
    reject: null,
  );
}

const Sector _sector = Sector(
  floorHeight: 0,
  ceilingHeight: 128,
  floorFlat: 'F',
  ceilingFlat: 'C',
  lightLevel: 160,
  special: 0,
  tag: 0,
);

const Sidedef _side = Sidedef(
  xOffset: 0,
  yOffset: 0,
  upperTexture: '-',
  lowerTexture: '-',
  middleTexture: '-',
  sector: 0,
);

final class _Percentiles {
  const _Percentiles(this.count, this.p50, this.p95);

  final int count;
  final int p50;
  final int p95;
}
