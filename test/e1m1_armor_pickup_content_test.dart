@Tags(['content'])
library;

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/local_iwad.dart';

const String _defaultWadPath = '.local/doom/DOOM1.WAD';
const int _allSkills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('original E1M1 ARM1 uses classic diagonal contact', () async {
    final MapData original = await _loadOriginalE1M1();
    final Thing armor = original.things.singleWhere(
      (Thing thing) => thing.type == 2018,
    );
    expect((armor.x, armor.y), (-224, -3232));

    // Keep the original E1M1 geometry and the real ARM1 thing, but place the
    // player 25 units away on both axes: classic contact accepts each axis
    // below the combined 16+20 unit radii, while approxDistance reports 38.
    final MapData map = _withThings(original, <Thing>[
      Thing(
        x: armor.x + 25,
        y: armor.y + 25,
        angle: 0,
        type: 1,
        flags: _allSkills,
      ),
      armor,
    ]);
    expect(
      approxDistance(toFixed(25), toFixed(25)),
      greaterThanOrEqualTo(toFixed(36)),
    );

    final GameState game = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    expect(game.player.armor, 0);
    expect(
      game.mobjs.where((MobjView actor) => actor.sprite == 'ARM1'),
      hasLength(1),
    );

    game.runTic(TicCmd.empty);

    expect(game.player.armor, 100);
    expect(
      game.mobjs.where((MobjView actor) => actor.sprite == 'ARM1'),
      isEmpty,
    );
  });

  test('original E1M1 ARM1 remains when armor is already 100', () async {
    final MapData original = await _loadOriginalE1M1();
    final Thing armor = original.things.singleWhere(
      (Thing thing) => thing.type == 2018,
    );
    final GameState game = GameState.start(
      _withThings(original, <Thing>[
        Thing(x: armor.x, y: armor.y, angle: 0, type: 1, flags: _allSkills),
        armor,
        armor,
      ]),
      const GameConfig(monsters: false),
    );

    game.runTic(TicCmd.empty);

    expect(game.player.armor, 100);
    expect(
      game.mobjs.where((MobjView actor) => actor.sprite == 'ARM1'),
      hasLength(1),
      reason: 'a second green armor must not disappear without improving armor',
    );
  });
}

Future<MapData> _loadOriginalE1M1() async {
  final ByteData asset = await loadLocalIwad(_defaultWadPath);
  final Uint8List bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  expect(bytes.lengthInBytes, 4196020);
  return MapData.load(WadSet(<WadFile>[WadFile.parse(bytes)]), 'E1M1');
}

MapData _withThings(MapData source, List<Thing> things) => MapData(
  name: source.name,
  vertices: source.vertices,
  linedefs: source.linedefs,
  sidedefs: source.sidedefs,
  sectors: source.sectors,
  segs: source.segs,
  subsectors: source.subsectors,
  nodes: source.nodes,
  things: things,
  blockmap: source.blockmap,
  reject: source.reject,
);
