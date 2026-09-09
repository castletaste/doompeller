@Tags(['content'])
library;

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/local_iwad.dart';

const String _wadPath = '.local/doom/DOOM1.WAD';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('original E1M8 player crosses the lowered line-141 drop', () async {
    final ByteData asset = await loadLocalIwad(_wadPath);
    final Uint8List bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    final MapData map = MapData.load(
      WadSet(<WadFile>[WadFile.parse(bytes)]),
      'E1M8',
    );
    final Linedef trigger = map.linedefs[141];
    expect((trigger.special, trigger.tag), (23, 1));
    expect(
      (map.sectors[9].floorHeight, map.sectors[10].floorHeight),
      (80, 144),
    );

    final GameState game = GameState.start(
      map,
      const GameConfig(monsters: false),
    );
    expect(
      (fixedToInt(game.player.x), fixedToInt(game.player.y)),
      (-128, -224),
    );

    for (var tic = 0; tic < 24 && game.player.x < toFixed(-96); tic++) {
      game.runTic(const TicCmd(forwardMove: 8));
    }
    game.runTic(const TicCmd(buttons: Buttons.use));
    for (var tic = 0; tic < 110; tic++) {
      game.runTic(TicCmd.empty);
    }
    expect(game.sectors.elementAt(10).floorHeight, toFixed(48));

    for (var tic = 0; tic < 40 && game.player.x < toFixed(-48); tic++) {
      game.runTic(const TicCmd(forwardMove: 8));
    }
    expect(game.playerSectorIndex, 10);
    expect(game.player.x, greaterThan(toFixed(-64)));
    expect(game.player.z, toFixed(48));
  });
}
