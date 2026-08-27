import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/e1m1_playthrough.dart';

const String _defaultWadPath = '.local/doom/DOOM1.WAD';
const int _productionSeed = 0;
const int _productionCommandCount = 2151;
const int _productionHash = 0x36d1d056;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production rules complete original E1M1 from ARM1 through lift to exit',
    () async {
      final ByteData asset = await rootBundle.load(_defaultWadPath);
      final Uint8List bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      expect(bytes.lengthInBytes, 4196020);
      final WadFile wad = WadFile.parse(bytes);
      final MapData map = MapData.load(WadSet(<WadFile>[wad]), 'E1M1');
      final Thing spawn = map.things.singleWhere(
        (Thing thing) => thing.type == 1,
      );
      expect((spawn.x, spawn.y, spawn.angle), (1056, -3616, 90));
      const GameConfig productionConfig = GameConfig();
      expect(productionConfig.monsters, isTrue);
      expect(productionConfig.skill, Skill.medium);
      final E1m1PlaythroughResult first = E1m1PlaythroughRunner(
        map,
        gameConfig: productionConfig,
        seed: _productionSeed,
        includeArmor: true,
      ).run();

      expect(first.completed, isTrue);
      expect(first.skill, Skill.medium);
      expect(first.monsters, isTrue);
      expect(first.seed, _productionSeed);
      expect(first.maxArmor, 100);
      expect(first.armorTic, isNotNull);
      expect(first.doorOpened, isTrue);
      expect(first.doorTic, isNotNull);
      expect(first.liftActivated, isTrue);
      expect(first.liftMoved, isTrue);
      expect(first.liftStartTic, isNotNull);
      expect(first.liftMoveTic, isNotNull);
      expect(first.damageObserved, isTrue);
      expect(first.damageTic, isNotNull);
      expect(first.switchTic, isNotNull);
      expect(first.exitTic, isNotNull);
      expect(first.kills, first.totalKills);
      expect(first.totalKills, 6);
      expect(first.floorInvariantHeld, isTrue);
      expect(first.wallInvariantHeld, isTrue);
      expect(first.p95Micros, lessThan(1000000 ~/ kTicRate));
      expect(first.armorTic!, lessThan(first.doorTic!));
      expect(first.doorTic!, lessThan(first.liftStartTic!));
      expect(first.liftStartTic!, lessThan(first.liftMoveTic!));
      expect(first.switchTic!, lessThanOrEqualTo(first.exitTic!));
      expect(first.commands, hasLength(_productionCommandCount));
      expect(first.hash, _productionHash);
      final GameState replay = GameState.start(
        map,
        productionConfig,
        seed: _productionSeed,
      );
      expect(
        (replay.player.x, replay.player.y, replay.player.angle),
        (toFixed(spawn.x), toFixed(spawn.y), degreesToAngle(spawn.angle)),
      );
      for (final TicCmd command in first.commands) {
        replay.runTic(command);
      }
      expect(replay.levelComplete, isTrue);
      expect(replay.player.health, greaterThan(0));
      expect(replay.killCount, replay.totalKills);
      expect(replay.hashState(), first.hash);
      debugPrint(first.summary);
    },
  );
}
