import 'package:doom_core/doom_core.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/e1m1_playthrough.dart';

const String _wadPath = '.local/doom/DOOM1.WAD';
const int _productionSeed = 0;
const int _productionKeyboardCommandCount = 2155;
// Independent monster spread and portal sight intentionally change the route.
const int _productionKeyboardHash = 0x55608565;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production keyboard sampling completes original E1M1 with combat',
    () async {
      final ByteData asset = await rootBundle.load(_wadPath);
      final Uint8List bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      expect(bytes.lengthInBytes, 4196020);
      final MapData map = MapData.load(
        WadSet(<WadFile>[WadFile.parse(bytes)]),
        'E1M1',
      );
      final Thing spawn = map.things.singleWhere(
        (Thing thing) => thing.type == 1,
      );
      final Thing armor = map.things.singleWhere(
        (Thing thing) => thing.type == 2018,
      );
      expect((spawn.x, spawn.y, spawn.angle), (1056, -3616, 90));
      expect((armor.x, armor.y), (-224, -3232));
      final DoomInputState input = DoomInputState();
      final _KeyboardSampler keyboard = _KeyboardSampler(input);
      const GameConfig productionConfig = GameConfig();
      final E1m1PlaythroughResult route = E1m1PlaythroughRunner(
        map,
        sampleCommand: keyboard.sample,
        gameConfig: productionConfig,
        seed: _productionSeed,
        includeArmor: true,
      ).run();
      debugPrint(route.summary);
      final GameState game = GameState.start(
        map,
        productionConfig,
        seed: _productionSeed,
      );
      expect(
        (game.player.x, game.player.y, game.player.angle),
        (toFixed(spawn.x), toFixed(spawn.y), degreesToAngle(spawn.angle)),
      );
      expect(
        game.mobjs.where((MobjView actor) => actor.sprite == 'ARM1'),
        hasLength(1),
      );
      final _Milestones milestones = _Milestones(game);
      final _KeyboardSampler replayKeyboard = _KeyboardSampler(
        DoomInputState(),
      );
      for (var index = 0; index < route.commands.length; index++) {
        final TicCmd recorded = route.commands[index];
        final TicCmd sampled = replayKeyboard.sample(recorded);
        expect(
          sampled,
          recorded,
          reason: 'DoomInputState changed recorded command at tic $index',
        );
        game.runTic(sampled);
        milestones.observe(game, sampled);
      }

      expect(
        milestones.armorTic,
        isNotNull,
        reason: milestones.failure('ARM1 pickup was not observed', game),
      );
      expect(
        route.commands.every(
          (TicCmd command) =>
              <int>{
                -DoomInputState.moveSpeed,
                0,
                DoomInputState.moveSpeed,
              }.contains(command.forwardMove) &&
              <int>{
                -DoomInputState.strafeSpeed,
                0,
                DoomInputState.strafeSpeed,
              }.contains(command.sideMove),
        ),
        isTrue,
        reason: 'replay contains movement that DoomInputState cannot emit',
      );
      expect(
        milestones.firstDoorTic,
        isNotNull,
        reason: milestones.failure('no door-open sound was observed', game),
      );
      expect(
        milestones.liftStartTic,
        isNotNull,
        reason: milestones.failure('no lift-start sound was observed', game),
      );
      expect(
        milestones.liftMoveTic,
        isNotNull,
        reason: milestones.failure(
          'no floor moved after lift activation',
          game,
        ),
      );
      expect(
        milestones.firstSwitchTic,
        isNotNull,
        reason: milestones.failure('no switch texture changed', game),
      );
      expect(
        game.levelComplete,
        isTrue,
        reason: milestones.failure('exit did not complete the level', game),
      );
      expect(game.hashState(), route.hash);
      expect(route.commands, hasLength(_productionKeyboardCommandCount));
      expect(route.hash, _productionKeyboardHash);
      expect(route.completed, isTrue);
      expect(route.skill, Skill.medium);
      expect(route.monsters, isTrue);
      expect(route.seed, _productionSeed);
      expect(route.kills, route.totalKills);
      expect(route.totalKills, 6);
      expect(route.doorOpened, isTrue);
      expect(route.liftActivated, isTrue);
      expect(route.liftMoved, isTrue);
      expect(route.damageObserved, isTrue);
      expect(route.floorInvariantHeld, isTrue);
      expect(route.wallInvariantHeld, isTrue);
      expect(game.tic, route.tics);
      expect(milestones.maxArmor, 100);
      expect(route.maxArmor, milestones.maxArmor);
      expect(route.armorTic, milestones.armorTic);
      expect(route.doorTic, milestones.firstDoorTic);
      expect(route.liftStartTic, milestones.liftStartTic);
      expect(route.liftMoveTic, milestones.liftMoveTic);
      expect(route.switchTic, milestones.firstSwitchTic);
      expect(route.exitTic, milestones.exitTic);
      expect(game.player.health, greaterThan(0));
      expect(game.player.armor, inInclusiveRange(1, 100));
      expect(
        milestones.armorTic!,
        lessThan(milestones.firstDoorTic!),
        reason: milestones.failure('door opened before ARM1 pickup', game),
      );
      expect(
        milestones.firstDoorTic!,
        lessThan(milestones.liftStartTic!),
        reason: milestones.failure('lift started before the first door', game),
      );
      expect(
        milestones.liftStartTic!,
        lessThan(milestones.liftMoveTic!),
        reason: milestones.failure('lift floor did not move after start', game),
      );
      expect(
        milestones.firstSwitchTic!,
        lessThanOrEqualTo(milestones.exitTic!),
        reason: milestones.failure('exit completed before switch use', game),
      );
      expect(
        game.mobjs.where((MobjView actor) => actor.sprite == 'ARM1'),
        isEmpty,
      );
      debugPrint(
        'E1M1 keyboard acceptance: tics=${game.tic} '
        'armor=${milestones.armorTic} door=${milestones.firstDoorTic} '
        'lift=${milestones.liftStartTic}/${milestones.liftMoveTic} '
        'switch=${milestones.firstSwitchTic} exit=${milestones.exitTic} '
        'hash=0x${game.hashState().toRadixString(16)}',
      );
    },
  );
}

final class _KeyboardSampler {
  _KeyboardSampler(this.input);

  final DoomInputState input;
  int _forwardResidual = 0;
  int _sideResidual = 0;

  TicCmd sample(TicCmd intent) {
    for (final DoomControl control in <DoomControl>[
      DoomControl.forward,
      DoomControl.backward,
      DoomControl.strafeLeft,
      DoomControl.strafeRight,
      DoomControl.attack,
    ]) {
      input.release(control);
    }
    _forwardResidual += intent.forwardMove;
    _sideResidual += intent.sideMove;
    if (_forwardResidual * 2 >= DoomInputState.moveSpeed) {
      input.press(DoomControl.forward);
      _forwardResidual -= DoomInputState.moveSpeed;
    } else if (_forwardResidual * 2 <= -DoomInputState.moveSpeed) {
      input.press(DoomControl.backward);
      _forwardResidual += DoomInputState.moveSpeed;
    }
    if (_sideResidual * 2 >= DoomInputState.strafeSpeed) {
      input.press(DoomControl.strafeRight);
      _sideResidual -= DoomInputState.strafeSpeed;
    } else if (_sideResidual * 2 <= -DoomInputState.strafeSpeed) {
      input.press(DoomControl.strafeLeft);
      _sideResidual += DoomInputState.strafeSpeed;
    }
    if (intent.attacking) input.press(DoomControl.attack);
    if (intent.using) input.triggerUse();
    if (intent.angleTurn != 0) input.addPointerTurn(intent.angleTurn);
    return input.consume().command;
  }
}

final class _Milestones {
  _Milestones(GameState game)
    : _lastFloors = <int>[
        for (final sector in game.sectors) sector.floorHeight,
      ];

  List<int> _lastFloors;
  int? armorTic;
  int? firstDoorTic;
  int? liftStartTic;
  int? liftMoveTic;
  int? firstSwitchTic;
  int? exitTic;
  int maxArmor = 0;
  int useTics = 0;
  int movementTics = 0;

  void observe(GameState game, TicCmd command) {
    if (command.using) useTics++;
    if (command.forwardMove != 0 || command.sideMove != 0) movementTics++;
    if (game.player.armor > maxArmor) maxArmor = game.player.armor;
    if (armorTic == null && game.player.armor == 100) armorTic = game.tic;
    for (final SoundEvent event in game.consumeSoundJournal()) {
      if (firstDoorTic == null && event.soundId == 'DSDOROPN') {
        firstDoorTic = game.tic;
      }
      if (liftStartTic == null && event.soundId == 'DSPSTART') {
        liftStartTic = game.tic;
      }
    }
    if (firstSwitchTic == null && game.switchJournal.isNotEmpty) {
      firstSwitchTic = game.tic;
    }
    game.consumeSwitchJournal();
    if (exitTic == null && game.levelComplete) exitTic = game.tic;
    final List<int> floors = <int>[
      for (final sector in game.sectors) sector.floorHeight,
    ];
    if (liftStartTic != null &&
        liftMoveTic == null &&
        _floorChanged(_lastFloors, floors)) {
      liftMoveTic = game.tic;
    }
    _lastFloors = floors;
  }

  String failure(String problem, GameState game) {
    final PlayerView player = game.player;
    return '$problem; tic=${game.tic} '
        'position=(${fixedToDouble(player.x).toStringAsFixed(1)},'
        '${fixedToDouble(player.y).toStringAsFixed(1)}) '
        'sector=${game.playerSectorIndex} health=${player.health} '
        'armor=${player.armor}/$maxArmor items=${game.itemCount}/${game.totalItems} '
        'armorTic=$armorTic doorTic=$firstDoorTic '
        'liftTic=$liftStartTic/$liftMoveTic switchTic=$firstSwitchTic '
        'exitTic=$exitTic '
        'useTics=$useTics movementTics=$movementTics '
        'complete=${game.levelComplete} '
        'hash=0x${game.hashState().toRadixString(16)}';
  }
}

bool _floorChanged(List<int> before, List<int> after) {
  for (var index = 0; index < before.length; index++) {
    if (before[index] != after[index]) return true;
  }
  return false;
}
