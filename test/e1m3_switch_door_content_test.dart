@Tags(['content'])
library;

import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/local_iwad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'original E1M3 yellow-key return door stays open after switch 535',
    () async {
      final ByteData asset = await loadLocalIwad('.local/doom/DOOM1.WAD');
      final MapData source = MapData.load(
        WadSet(<WadFile>[
          WadFile.parse(
            asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
          ),
        ]),
        'E1M3',
      );
      expect(
        (source.linedefs[535].special, source.linedefs[535].tag),
        (103, 10),
      );
      expect(
        (source.sectors[121].floorHeight, source.sectors[121].ceilingHeight),
        (64, 64),
      );

      // Focused component probe, not a level playthrough: retain every original
      // geometry/special lump, but start an isolated player at the switch front.
      final MapData map = MapData(
        name: source.name,
        vertices: source.vertices,
        linedefs: source.linedefs,
        sidedefs: source.sidedefs,
        sectors: source.sectors,
        segs: source.segs,
        subsectors: source.subsectors,
        nodes: source.nodes,
        blockmap: source.blockmap,
        reject: source.reject,
        things: <Thing>[
          const Thing(
            x: -1936,
            y: -2104,
            angle: 90,
            type: 1,
            flags: ThingFlags.easy | ThingFlags.medium | ThingFlags.hard,
          ),
        ],
      );

      int replay() {
        final GameState game = GameState.start(
          map,
          const GameConfig(monsters: false),
          seed: 0,
        );
        expect(game.playerSectorIndex, 101);
        game.runTic(const TicCmd(buttons: Buttons.use));
        expect(game.switchJournal.single.linedef, 535);
        game.consumeSwitchJournal();
        for (var tic = 0; tic < 700; tic++) {
          game.runTic(TicCmd.empty);
          if (tic >= 70) {
            expect(game.sectors.elementAt(121).ceilingHeight, toFixed(172));
          }
        }
        expect(game.switchJournal, isEmpty, reason: 'S1 switch never resets');
        game.runTic(const TicCmd(buttons: Buttons.use));
        expect(game.switchJournal, isEmpty, reason: 'S1 cannot be used twice');
        expect(game.sectors.elementAt(121).ceilingHeight, toFixed(172));
        return game.hashState();
      }

      expect(replay(), replay());
    },
  );
}
