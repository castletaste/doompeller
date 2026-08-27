import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/e1m1_playthrough.dart';

const String _defaultWadPath = '.local/doom/DOOM1.WAD';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'original E1M1 is physically traversable through lift and nukage to exit',
    () async {
      final ByteData asset = await rootBundle.load(_defaultWadPath);
      final Uint8List bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      expect(bytes.lengthInBytes, 4196020);
      final WadFile wad = WadFile.parse(bytes);
      final MapData map = MapData.load(WadSet(<WadFile>[wad]), 'E1M1');
      final E1m1PlaythroughResult first = E1m1PlaythroughRunner(map).run();

      expect(first.completed, isTrue);
      expect(first.doorOpened, isTrue);
      expect(first.liftActivated, isTrue);
      expect(first.liftMoved, isTrue);
      expect(first.damageObserved, isTrue);
      expect(first.floorInvariantHeld, isTrue);
      expect(first.wallInvariantHeld, isTrue);
      expect(first.p95Micros, lessThan(1000000 ~/ kTicRate));

      final GameState replay = GameState.start(
        map,
        const GameConfig(monsters: false),
        seed: 0xE1,
      );
      for (final TicCmd command in first.commands) {
        replay.runTic(command);
      }
      expect(replay.levelComplete, isTrue);
      expect(replay.hashState(), first.hash);
      debugPrint(first.summary);
    },
  );
}
