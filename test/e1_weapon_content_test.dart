import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const String _wadPath = '.local/doom/DOOM1.WAD';
const int _skills = ThingFlags.easy | ThingFlags.medium | ThingFlags.hard;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'original E1 pickup things grant rockets and both new weapons',
    () async {
      final ByteData asset = await rootBundle.load(_wadPath);
      final Uint8List bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final WadSet set = WadSet(<WadFile>[WadFile.parse(bytes)]);
      final Map<int, (MapData, Thing)> found = <int, (MapData, Thing)>{};
      for (var episodeMap = 1; episodeMap <= 9; episodeMap++) {
        final MapData map = MapData.load(set, 'E1M$episodeMap');
        for (final Thing thing in map.things) {
          if (<int>{2003, 2005, 2010, 2046}.contains(thing.type) &&
              (thing.flags == 0 || (thing.flags & ThingFlags.medium) != 0) &&
              (thing.flags & ThingFlags.multiplayerOnly) == 0) {
            found.putIfAbsent(thing.type, () => (map, thing));
          }
        }
      }
      expect(found.keys, containsAll(<int>[2003, 2005, 2010, 2046]));

      GameState collect(int type) {
        final (MapData source, Thing pickup) = found[type]!;
        final MapData map = MapData(
          name: source.name,
          vertices: source.vertices,
          linedefs: source.linedefs,
          sidedefs: source.sidedefs,
          sectors: source.sectors,
          segs: source.segs,
          subsectors: source.subsectors,
          nodes: source.nodes,
          things: <Thing>[
            Thing(x: pickup.x, y: pickup.y, angle: 0, type: 1, flags: _skills),
            pickup,
          ],
          blockmap: source.blockmap,
          reject: source.reject,
        );
        final GameState game = GameState.start(
          map,
          const GameConfig(monsters: false),
        );
        game.runTic(TicCmd.empty);
        return game;
      }

      expect(collect(2010).player.ammo.rockets, 1);
      expect(collect(2046).player.ammo.rockets, 5);

      final GameState launcher = collect(2003);
      expect(launcher.player.ammo.rockets, 2);
      for (var tic = 0; tic < 40; tic++) {
        launcher.runTic(TicCmd.empty);
      }
      expect(launcher.player.weapon, Weapon.rocketLauncher);

      final GameState chainsaw = collect(2005);
      for (var tic = 0; tic < 40; tic++) {
        chainsaw.runTic(TicCmd.empty);
      }
      expect(chainsaw.player.weapon, Weapon.chainsaw);
    },
  );
}
