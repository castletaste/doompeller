import 'dart:async';
import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:flame/events.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import '../game/doom_hud.dart';
import '../game/doom_automap.dart';
import '../game/doom_input.dart';
import '../game/level_preparer.dart';
import '../game/sound_playback.dart';
import 'doom_scene.dart';
import 'doom_sprite_catalog.dart';
import 'doom_camera.dart';
import 'palette_textures.dart';

typedef DoomLevelCompleteCallback = void Function(bool secretExit);

/// Terminal outcome for an exclusive input-only runtime replay.
enum DoomReplayStatus {
  complete('complete'),
  earlyEnd('early_end'),
  earlyExit('early_exit'),
  hashMismatch('hash_mismatch');

  const DoomReplayStatus(this.label);

  final String label;
}

/// Immutable terminal evidence emitted once by a [DoomReplayInput].
@immutable
final class DoomReplayResult {
  const DoomReplayResult({
    required this.status,
    required this.commandCount,
    required this.commandTotal,
    required this.gameTic,
    required this.levelComplete,
    required this.expectedHash,
    required this.actualHash,
  });

  final DoomReplayStatus status;
  final int commandCount;
  final int commandTotal;
  final int gameTic;
  final bool levelComplete;
  final int expectedHash;
  final int actualHash;

  bool get passed => status == DoomReplayStatus.complete;
}

/// Developer/test command stream sampled instead of device input.
///
/// The runtime copies [commands], supplies exactly one command to each actual
/// simulation tic, and stops at the first terminal outcome. Passing both this
/// and a custom [DoomInputState] is rejected so the two sources cannot mix.
final class DoomReplayInput {
  DoomReplayInput({
    required Iterable<TicCmd> commands,
    required this.expectedFinalHash,
    this.onFinished,
  }) : commands = List<TicCmd>.unmodifiable(commands);

  final List<TicCmd> commands;
  final int expectedFinalHash;
  final ValueChanged<DoomReplayResult>? onFinished;
}

final class _ReplayTerminalDelivery {
  const _ReplayTerminalDelivery({
    required this.result,
    required this.secretExit,
    required this.onFinished,
    required this.onLevelComplete,
  });

  final DoomReplayResult result;
  final bool secretExit;
  final ValueChanged<DoomReplayResult>? onFinished;
  final DoomLevelCompleteCallback? onLevelComplete;
}

// Actor types created by gameplay rather than declared by source THINGS still
// need atlas coverage before the retained scene is assembled.
const Set<String> _dynamicDropSpritePrefixes = <String>{'CLIP', 'SHOT', 'MGUN'};

const Set<String> _completionTransientSprites = <String>{
  'PUFF',
  'BLUD',
  'BEXP',
  'BAL1',
  'BAL7',
  'MISL',
  'TFOG',
};

/// Production 35 Hz simulation and retained Flame 3D scene boundary.
final class DoomRuntimeGame extends FlameGame3D
    with KeyboardEvents
    implements DoomRuntimeView {
  @override
  LevelExit? get levelExit => gameState.levelExit;

  int _damageFlashTics = 0;
  int _pickupFlashTics = 0;
  int _paletteIndex = DoomPaletteVariant.normal;

  /// Current renderer output; it has no effect on replay state.
  int get paletteIndex => _paletteIndex;

  factory DoomRuntimeGame(
    PreparedDoomLevel level, {
    DoomInputState? input,
    DoomReplayInput? replayInput,
    DoomLevelCompleteCallback? onLevelComplete,
    AudioBackend audioBackend = const NoAudioBackend(),
  }) {
    if (input != null && replayInput != null) {
      throw ArgumentError(
        'input and replayInput are mutually exclusive command sources',
      );
    }
    final Set<String> availablePrefixes = <String>{
      for (final name in level.resources.spriteNames)
        if (name.length >= 4) name.substring(0, 4).toUpperCase(),
    };
    final Set<String> requested = <String>{
      ...level.initialSpritePrefixes,
      ..._dynamicDropSpritePrefixes,
      'BAL1',
      'BAL7',
      'MISL',
      'TFOG',
      'BEXP',
      'PUFF',
      'BLUD',
      'PISF',
      'SHTF',
      'CHGF',
      'MISF',
      ...DoomWeaponSprites.supportedPrefixes,
      if (level.content.isFixture) 'TEST',
    };
    final Set<String> packed = requested.intersection(availablePrefixes);
    final GameState gameState = level.createGame();
    final scene = DoomScene.fromCompiledLevel(
      level.geometry,
      level.resources,
      spritePrefixes: packed,
      sectorLights: <int>[
        for (final sector in level.map.sectors) sector.lightLevel,
      ],
    );
    final player = gameState.player;
    return DoomRuntimeGame._(
      level,
      scene,
      gameState,
      input ?? DoomInputState(),
      replayInput,
      onLevelComplete,
      SoundPlaybackManager(
        backend: audioBackend,
        catalog: WadSoundCatalog(level.resources),
      ),
      camera: _cameraFor(player),
      packedSpritePrefixes: packed,
    );
  }

  DoomRuntimeGame._(
    this.level,
    this.scene,
    this.gameState,
    this.input,
    this.replayInput,
    this._onLevelComplete,
    this._soundPlayback, {
    required CameraComponent3D camera,
    required Set<String> packedSpritePrefixes,
  }) : tickDriver = FixedTickDriver(
         maxTicsPerFrame: gameState.config.maxCatchUpTics,
       ),
       _packedSpritePrefixes = Set<String>.unmodifiable(packedSpritePrefixes),
       _previousPlayer = gameState.player,
       _currentPlayer = gameState.player,
       _automap = DoomAutomapState(level.map, gameState.player),
       _sectorFloors = <double>[
         for (final sector in gameState.sectors)
           fixedToDouble(sector.floorHeight),
       ],
       _sectorCeilings = <double>[
         for (final sector in gameState.sectors)
           fixedToDouble(sector.ceilingHeight),
       ],
       super(camera: camera) {
    _automap.updatePlayer(
      gameState.player,
      sectorIndex: gameState.playerSectorIndex,
    );
    _syncActors();
    _syncWeapon(force: true);
    _syncCamera(0);
    _publishHud();
  }

  final PreparedDoomLevel level;
  final DoomScene scene;
  GameState gameState;
  FixedTickDriver tickDriver;
  final DoomInputState input;
  final DoomReplayInput? replayInput;
  final DoomLevelCompleteCallback? _onLevelComplete;
  final Set<String> _packedSpritePrefixes;
  final List<double> _sectorFloors;
  final List<double> _sectorCeilings;
  final Map<int, ActorSpriteComponent> _actors = <int, ActorSpriteComponent>{};
  final Map<PhysicalKeyboardKey, DoomControl> _keyboardControls =
      <PhysicalKeyboardKey, DoomControl>{};
  final Map<int, Set<DoomControl>> _touchControls = <int, Set<DoomControl>>{};
  final Set<String> _reportedMissingSprites = <String>{};
  final _CountingValueNotifier<DoomHudSnapshot> _hud =
      _CountingValueNotifier<DoomHudSnapshot>(const DoomHudSnapshot.initial());
  final DoomAutomapState _automap;
  late final _CountingValueListenable<DoomAutomapSnapshot> _automapListenable =
      _CountingValueListenable<DoomAutomapSnapshot>(_automap);
  final SoundPlaybackManager _soundPlayback;
  late DoomCoreSoundJournal _soundJournal = DoomCoreSoundJournal(gameState);
  Future<void> _soundPlaybackTail = Future<void>.value();
  int _soundPlaybackErrorCount = 0;
  Object? _lastSoundPlaybackError;
  StackTrace? _lastSoundPlaybackStackTrace;

  PlayerView _previousPlayer;
  PlayerView _currentPlayer;
  ViewLockedWeaponSpriteComponent? _weaponSprite;
  ViewLockedWeaponSpriteComponent? _weaponFlashSprite;
  bool _paused = false;
  bool _completionReported = false;
  int? _touchMovementPointer;
  int _replayCommandCount = 0;
  DoomReplayResult? _replayResult;
  _ReplayTerminalDelivery? _pendingReplayTerminal;
  double _fractionalMicros = 0;
  bool _renderClockPrimed = false;

  @override
  ValueListenable<DoomHudSnapshot> get hud => _hud;

  @override
  ValueListenable<DoomAutomapSnapshot> get automap => _automapListenable;

  bool get isPaused => _paused;
  bool get hasReplayInput => replayInput != null;
  int get replayCommandCount => _replayCommandCount;
  DoomReplayResult? get replayResult => _replayResult;
  int get actorComponentCount => _actors.length;
  Set<int> get actorIds => Set<int>.unmodifiable(_actors.keys);
  String? get weaponFrame => _weaponSprite?.lumpName;
  String? get weaponFlashFrame => _weaponFlashSprite?.lumpName;
  bool get weaponFlashVisible => _weaponFlashSprite?.visible ?? false;

  @visibleForTesting
  ViewLockedWeaponSpriteComponent? get weaponFlashComponentForTest =>
      _weaponFlashSprite;

  @visibleForTesting
  int get hudListenerCountForTest => _hud.listenerCount;

  @visibleForTesting
  int get automapListenerCountForTest => _automapListenable.listenerCount;

  ActorSpriteComponent? actorComponentForTest(int id) => _actors[id];

  ({double x, double y, double z})? actorPositionForTest(int id) {
    final actor = _actors[id];
    return actor == null
        ? null
        : (x: actor.position.x, y: actor.position.y, z: actor.position.z);
  }

  void syncActorViewsForTest(Iterable<MobjView> actors) =>
      _syncActorViews(actors);

  @override
  Color backgroundColor() => const Color(0xFF000000);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    world.add(scene.root);
  }

  @override
  void update(double dt) {
    // GameWidget can issue zero-delta lifecycle updates before Flame's ticker
    // reports its first positive interval. Those zeroes do not establish a
    // render-clock origin. The first positive interval can include mounting
    // and first-render work, so let the Flame tree process lifecycle events at
    // zero delta without fast-forwarding either it or the Doom simulation.
    final bool establishingRenderClock = !_renderClockPrimed && dt > 0;
    super.update(establishingRenderClock ? 0 : dt);
    _processPauseToggle();
    if (establishingRenderClock) {
      _renderClockPrimed = true;
    } else if (_renderClockPrimed && _simulationActive) {
      final double micros =
          dt * Duration.microsecondsPerSecond + _fractionalMicros;
      final int wholeMicros = micros.floor();
      _fractionalMicros = micros - wholeMicros;
      _advanceMicros(wholeMicros);
    }
    _syncCamera(tickDriver.interpolationAlpha);
    _publishHud();
  }

  /// Deterministic clock entry point used by runtime tests.
  int advanceMicrosForTest(int elapsedMicros) {
    _processPauseToggle();
    var executed = 0;
    if (_simulationActive) {
      executed = _advanceMicros(elapsedMicros);
    }
    _syncCamera(tickDriver.interpolationAlpha);
    _publishHud();
    return executed;
  }

  void renderCameraAtForTest(double alpha) => _syncCamera(alpha);

  Future<void> get soundPlaybackIdleForTest => _soundPlaybackTail;

  @visibleForTesting
  int get soundPlaybackErrorCountForTest => _soundPlaybackErrorCount;

  @visibleForTesting
  Object? get lastSoundPlaybackErrorForTest => _lastSoundPlaybackError;

  @visibleForTesting
  StackTrace? get lastSoundPlaybackStackTraceForTest =>
      _lastSoundPlaybackStackTrace;

  ({double x, double y, double z, double targetX, double targetZ})
  get cameraSnapshot => (
    x: camera.position.x,
    y: camera.position.y,
    z: camera.position.z,
    targetX: camera.target.x,
    targetZ: camera.target.z,
  );

  bool get _simulationActive =>
      !_paused && !gameState.levelComplete && _replayResult == null;

  int _advanceMicros(int elapsedMicros) {
    final DoomReplayInput? replay = replayInput;
    if (replay == null) {
      return tickDriver.advanceMicros(
        elapsedMicros,
        (_) => _runDueTic(),
        TicCmd.empty,
      );
    }
    if (_replayCommandCount >= replay.commands.length) {
      _stageReplayTerminal(DoomReplayStatus.earlyEnd);
      _deliverReplayTerminal();
      return 0;
    }
    final FixedTickDriver activeDriver = tickDriver;
    final int executed = activeDriver.advanceMicrosWhile(elapsedMicros, (_) {
      _runDueTic();
      return _replayResult == null;
    }, TicCmd.empty);
    _deliverReplayTerminal();
    return executed;
  }

  void _runDueTic() {
    if (!_simulationActive) return;
    final DoomReplayInput? replay = replayInput;
    if (replay == null) {
      _runTic(input.consume().command);
      return;
    }
    if (_replayCommandCount >= replay.commands.length) {
      _stageReplayTerminal(DoomReplayStatus.earlyEnd);
      return;
    }
    final TicCmd command = replay.commands[_replayCommandCount++];
    _runTic(command);
    if (gameState.levelComplete) {
      if (_replayCommandCount != replay.commands.length) {
        _stageReplayTerminal(DoomReplayStatus.earlyExit);
      } else if (gameState.hashState() != replay.expectedFinalHash) {
        _stageReplayTerminal(DoomReplayStatus.hashMismatch);
      } else {
        _stageReplayTerminal(DoomReplayStatus.complete);
      }
    } else if (_replayCommandCount == replay.commands.length) {
      _stageReplayTerminal(DoomReplayStatus.earlyEnd);
    }
  }

  void _stageReplayTerminal(DoomReplayStatus status) {
    if (_replayResult != null) return;
    final DoomReplayInput replay = replayInput!;
    final DoomReplayResult result = DoomReplayResult(
      status: status,
      commandCount: _replayCommandCount,
      commandTotal: replay.commands.length,
      gameTic: gameState.tic,
      levelComplete: gameState.levelComplete,
      expectedHash: replay.expectedFinalHash,
      actualHash: gameState.hashState(),
    );
    _replayResult = result;
    if (status == DoomReplayStatus.complete) {
      _completionReported = true;
    }
    _pendingReplayTerminal = _ReplayTerminalDelivery(
      result: result,
      secretExit: gameState.usedSecretExit,
      onFinished: replay.onFinished,
      onLevelComplete: status == DoomReplayStatus.complete
          ? _onLevelComplete
          : null,
    );
  }

  /// Delivers a successful level callback before the replay callback.
  ///
  /// The delivery is detached first so either callback may restart the game
  /// without changing the completed run's captured result or exit kind.
  void _deliverReplayTerminal() {
    final _ReplayTerminalDelivery? delivery = _pendingReplayTerminal;
    if (delivery == null) return;
    _pendingReplayTerminal = null;
    try {
      delivery.onLevelComplete?.call(delivery.secretExit);
    } finally {
      delivery.onFinished?.call(delivery.result);
    }
  }

  void _runTic(TicCmd command) {
    _previousPlayer = _currentPlayer;
    gameState.runTic(command);
    _currentPlayer = gameState.player;
    if (_damageFlashTics > 0) _damageFlashTics--;
    if (_pickupFlashTics > 0) _pickupFlashTics--;
    final int damage =
        (_previousPlayer.health - _currentPlayer.health) +
        (_previousPlayer.armor - _currentPlayer.armor);
    if (damage > 0) {
      _damageFlashTics = math.max(_damageFlashTics, damage.clamp(6, 32));
    }
    _automap.updatePlayer(
      _currentPlayer,
      sectorIndex: gameState.playerSectorIndex,
    );
    _consumeSectorJournal();
    _consumeSoundJournal();
    _syncPalette();
    _syncActors();
    _syncWeapon();
    if (gameState.levelComplete) {
      _hideCompletionTransients();
      if (!hasReplayInput) _reportLevelComplete();
    }
  }

  void _reportLevelComplete() {
    if (_completionReported) return;
    _completionReported = true;
    _onLevelComplete?.call(gameState.usedSecretExit);
  }

  void _hideCompletionTransients() {
    _weaponFlashSprite?.setVisible(false);
    for (final MobjView actor in gameState.mobjs) {
      if (!_completionTransientSprites.contains(actor.sprite) &&
          (actor.flags & MobjFlags.missile) == 0) {
        continue;
      }
      final ActorSpriteComponent? component = _actors.remove(actor.id);
      if (component != null) {
        scene.releaseActorSprite(component);
      }
    }
  }

  void _consumeSoundJournal() {
    final List<SoundEvent> events = _soundJournal.consumeSoundJournal().toList(
      growable: false,
    );
    if (events.any((event) => event.soundId == 'DSITEMUP')) {
      _pickupFlashTics = 6;
    }
    final AudioListener listener = audioListenerFromPlayer(_currentPlayer);
    final int gameTic = gameState.tic;
    _enqueueSoundPlayback(
      () => _soundPlayback.consumeEvents(
        events: events,
        listener: listener,
        gameTic: gameTic,
      ),
    );
  }

  void _syncPalette() {
    final powers = _currentPlayer.powers;
    final int colorMap = _powerVisible(powers.invulnerabilityTics)
        ? 32
        : _powerVisible(powers.lightAmplificationTics)
        ? 0
        : -1;
    scene.materials.setFixedColorMap(colorMap);
    final int wanted = _damageFlashTics > 0
        ? DoomPaletteVariant.damage(_damageFlashTics / 32)
        : _pickupFlashTics > 0
        ? DoomPaletteVariant.itemPickup(_pickupFlashTics / 6)
        : _powerVisible(powers.radiationSuitTics)
        ? DoomPaletteVariant.radiationSuit
        : DoomPaletteVariant.normal;
    final int available = wanted < level.resources.playpal.palettes.length
        ? wanted
        : DoomPaletteVariant.normal;
    if (_paletteIndex == available) return;
    _paletteIndex = available;
    scene.setPaletteIndex(available);
  }

  static bool _powerVisible(int tics) => tics > 128 || (tics & 8) != 0;

  void _enqueueSoundPlayback(Future<void> Function() operation) {
    final Future<void> previous = _soundPlaybackTail;
    _soundPlaybackTail = () async {
      try {
        await previous;
      } on Object catch (error, stackTrace) {
        _recordSoundPlaybackError(error, stackTrace);
      }
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        _recordSoundPlaybackError(error, stackTrace);
      }
    }();
  }

  void _recordSoundPlaybackError(Object error, StackTrace stackTrace) {
    _soundPlaybackErrorCount++;
    _lastSoundPlaybackError = error;
    _lastSoundPlaybackStackTrace = stackTrace;
    debugPrint(
      'doompeller: audio output failed (${error.runtimeType}); '
      'count=$_soundPlaybackErrorCount',
    );
  }

  void _consumeSectorJournal() {
    scene.updateTextureAnimations(gameState.levelTime);
    for (final SwitchTextureChange change in gameState.consumeSwitchJournal()) {
      scene.updateSwitchTexture(change);
    }
    final Set<int> automapHeightChanges = <int>{};
    for (final change in gameState.consumeChangeJournal()) {
      switch (change.kind) {
        case PlaneKind.floor:
          final double height = fixedToDouble(change.value);
          _sectorFloors[change.sector] = height;
          scene.updateSectorPlane(
            sectorIndex: change.sector,
            height: height,
            isCeiling: false,
          );
          _updateWalls(change.sector);
          automapHeightChanges.add(change.sector);
        case PlaneKind.ceiling:
          final double height = fixedToDouble(change.value);
          _sectorCeilings[change.sector] = height;
          scene.updateSectorPlane(
            sectorIndex: change.sector,
            height: height,
            isCeiling: true,
          );
          _updateWalls(change.sector);
          automapHeightChanges.add(change.sector);
        case PlaneKind.light:
          scene.updateSectorLight(
            sectorIndex: change.sector,
            lightLevel: change.value,
          );
        case PlaneKind.floorFlat:
          scene.updateSectorFloorFlat(
            sectorIndex: change.sector,
            flatName: change.flatName,
          );
      }
    }
    for (final sector in automapHeightChanges) {
      _automap.updateSectorHeights(
        sectorIndex: sector,
        floorHeight: _sectorFloors[sector],
        ceilingHeight: _sectorCeilings[sector],
      );
    }
  }

  void _updateWalls(int sector) {
    scene.updateWallsForSector(
      sectorIndex: sector,
      floorHeight: _sectorFloors[sector],
      ceilingHeight: _sectorCeilings[sector],
      sectorFloors: _sectorFloors,
      sectorCeilings: _sectorCeilings,
    );
  }

  void _syncActors() => _syncActorViews(gameState.mobjs);

  void _syncActorViews(Iterable<MobjView> views) {
    final Map<int, MobjView> live = <int, MobjView>{
      for (final actor in views)
        if (actor.sprite != 'PLAY') actor.id: actor,
    };
    for (final id in _actors.keys.toList(growable: false)) {
      if (live.containsKey(id)) {
        continue;
      }
      final removed = _actors.remove(id);
      if (removed != null) {
        scene.releaseActorSprite(removed);
      }
    }
    for (final actor in live.values) {
      final String prefix = actor.sprite.toUpperCase();
      final existing = _actors[actor.id];
      if (!_packedSpritePrefixes.contains(prefix)) {
        if (existing != null) {
          scene.releaseActorSprite(existing);
          _actors.remove(actor.id);
        }
        if (_reportedMissingSprites.add(prefix)) {
          debugPrint(
            'doompeller: sprite prefix $prefix is unavailable; skipped',
          );
        }
        continue;
      }
      final double x = fixedToDouble(actor.x);
      final double y = fixedToDouble(actor.z);
      final double z = -fixedToDouble(actor.y);
      // Doom BAM 0 faces world +X. The sprite catalog measures yaw from +Z,
      // therefore the same facing is BAM radians plus one quarter turn.
      final double angle = worldActorYawForBam(actor.angle);
      if (existing != null) {
        final updated = scene.updateActorSprite(
          existing,
          ActorSpriteInstance(
            spritePrefix: prefix,
            x: x,
            y: y,
            z: z,
            frame: actor.frame,
            actorAngle: angle,
            light: actor.lightLevel / 255.0,
            fullBright: actor.fullBright,
            fuzz: (actor.flags & MobjFlags.shadow) != 0,
          ),
        );
        if (updated) {
          continue;
        }
        scene.releaseActorSprite(existing);
        _actors.remove(actor.id);
      }
      final component = scene.acquireActorSprite(
        ActorSpriteInstance(
          spritePrefix: prefix,
          x: x,
          y: y,
          z: z,
          frame: actor.frame,
          actorAngle: angle,
          light: actor.lightLevel / 255.0,
          fullBright: actor.fullBright,
          fuzz: (actor.flags & MobjFlags.shadow) != 0,
        ),
      );
      if (component == null) {
        if (_reportedMissingSprites.add('$prefix:${actor.frame}')) {
          debugPrint(
            'doompeller: no sprite for $prefix frame ${actor.frame}; '
            'actor ${actor.id} skipped',
          );
        }
        continue;
      }
      _actors[actor.id] = component;
    }
  }

  void _syncWeapon({bool force = false}) {
    final WeaponAnimation animation = _currentPlayer.weaponAnimation;
    final String? exact = _weaponFrameFor(animation.weapon, animation.frame);
    if (exact == null) {
      return;
    }
    // Doom psprites use a 320x200 screen-space origin. Weapon patches retain
    // their original negative offsets, so sx=0 maps to -160/320 and larger sy
    // values move the sprite down the screen.
    const double anchorX = -0.5;
    final double anchorY =
        (100.5 - animation.y - fixedToDouble(_currentPlayer.bob)) / 200;
    final current = _weaponSprite;
    if (current == null) {
      _weaponSprite = scene.addWeaponSprite(
        WeaponSpriteInstance(
          lumpName: exact,
          viewAnchorX: anchorX,
          viewAnchorY: anchorY,
        ),
      );
    } else if (force ||
        current.lumpName != exact ||
        current.viewAnchorY != anchorY) {
      current.setFrame(exact, viewAnchorY: anchorY);
    }
    _syncWeaponFlash(animation, anchorY);
  }

  void _syncWeaponFlash(WeaponAnimation animation, double anchorY) {
    const double anchorX = -0.5;
    final String? flash = animation.flashFrame < 0
        ? null
        : _weaponFlashFrameFor(animation.weapon, animation.flashFrame);
    final current = _weaponFlashSprite;
    if (flash == null) {
      current?.setVisible(false);
      return;
    }
    if (current == null) {
      _weaponFlashSprite = scene.addWeaponSprite(
        WeaponSpriteInstance(
          lumpName: flash,
          viewAnchorX: anchorX,
          viewAnchorY: anchorY,
          fullBright: true,
          depthLayer: -2,
        ),
      );
      return;
    }
    current.setVisible(true);
    current.setFrame(flash, viewAnchorY: anchorY);
  }

  String? _weaponFrameFor(Weapon weapon, int frame) {
    final String prefix = switch (weapon) {
      Weapon.fist => DoomWeaponSprites.fist,
      Weapon.pistol => DoomWeaponSprites.pistol,
      Weapon.shotgun => DoomWeaponSprites.shotgun,
      Weapon.chaingun => DoomWeaponSprites.chaingun,
      Weapon.rocketLauncher => DoomWeaponSprites.rocketLauncher,
      Weapon.chainsaw => DoomWeaponSprites.chainsaw,
    };
    final String candidate = '$prefix${String.fromCharCode(65 + frame)}0';
    return level.resources.spriteNames.contains(candidate) ? candidate : null;
  }

  String? _weaponFlashFrameFor(Weapon weapon, int frame) {
    final String? prefix = switch (weapon) {
      Weapon.fist || Weapon.chainsaw => null,
      Weapon.pistol => 'PISF',
      Weapon.shotgun => 'SHTF',
      Weapon.chaingun => 'CHGF',
      Weapon.rocketLauncher => 'MISF',
    };
    if (prefix == null) return null;
    final String candidate = '$prefix${String.fromCharCode(65 + frame)}0';
    return level.resources.spriteNames.contains(candidate) ? candidate : null;
  }

  void _syncCamera(double alpha) {
    final double t = alpha.clamp(0, 1).toDouble();
    final double x = _lerpFixed(_previousPlayer.x, _currentPlayer.x, t);
    final double mapY = _lerpFixed(_previousPlayer.y, _currentPlayer.y, t);
    final double viewZ = _lerpFixed(
      _previousPlayer.viewZ,
      _currentPlayer.viewZ,
      t,
    );
    final int delta = angleDelta(_currentPlayer.angle, _previousPlayer.angle);
    final double angle = _bamRadians(
      normalizeAngle(_previousPlayer.angle + (delta * t).round()),
    );
    camera.position.setValues(x, viewZ, -mapY);
    camera.target.setValues(
      x + math.cos(angle) * 64,
      viewZ,
      -mapY - math.sin(angle) * 64,
    );
    scene.syncToCamera(camera);
  }

  void _publishHud() {
    final player = gameState.player;
    _hud.value = DoomHudSnapshot(
      health: player.health,
      armor: player.armor,
      bullets: player.ammo.bullets,
      shells: player.ammo.shells,
      rockets: player.ammo.rockets,
      weapon: player.weapon,
      keys: player.keys,
      kills: gameState.killCount,
      totalKills: gameState.totalKills,
      items: gameState.itemCount,
      totalItems: gameState.totalItems,
      secrets: gameState.secretsFound,
      totalSecrets: gameState.totalSecrets,
      levelTime: gameState.levelTime,
      paused: _paused,
      levelComplete: gameState.levelComplete,
      diagnostics: DoomFrameDiagnosticsSnapshot(
        tics: tickDriver.executedTics,
        droppedTics: tickDriver.droppedTics,
        surfaces: scene.surfaceCount,
        dynamicUploads: scene.diagnostics.dynamicUploads,
      ),
    );
  }

  void _processPauseToggle() {
    if (hasReplayInput) {
      input.takePauseToggle();
      return;
    }
    if (input.takePauseToggle()) {
      _paused = !_paused;
      if (_paused) clearInput();
    }
  }

  @override
  void setPointerAttack(bool pressed, {bool cancelled = false}) {
    if (!pressed) {
      input.releaseOwned(
        _mouseAttackOwner,
        DoomControl.attack,
        cancelled: cancelled,
      );
      return;
    }
    if (!_acceptsGameplayInput) return;
    if (pressed && gameState.player.health <= 0) {
      restartLevel();
      return;
    }
    input.pressOwned(_mouseAttackOwner, DoomControl.attack);
  }

  @override
  void addPointerYaw(double deltaX) {
    if (!_acceptsGameplayInput) return;
    input.addPointerTurn((-deltaX * 24).round());
  }

  @override
  void setTouchMovement(
    int pointer, {
    required int forward,
    required int side,
  }) {
    _validatePointer(pointer);
    if (forward < -DoomInputState.axisScale ||
        forward > DoomInputState.axisScale) {
      throw RangeError.range(
        forward,
        -DoomInputState.axisScale,
        DoomInputState.axisScale,
        'forward',
      );
    }
    if (side < -DoomInputState.axisScale || side > DoomInputState.axisScale) {
      throw RangeError.range(
        side,
        -DoomInputState.axisScale,
        DoomInputState.axisScale,
        'side',
      );
    }
    if (!_acceptsGameplayInput) return;
    final int? owner = _touchMovementPointer;
    if (owner != null && owner != pointer) return;
    _touchMovementPointer = pointer;
    input.setAnalogAxes(forward: forward, side: side);
  }

  @override
  void pressTouchControl(int pointer, DoomControl control) {
    _validatePointer(pointer);
    if (!_acceptsGameplayInput) return;
    if (control == DoomControl.attack && gameState.player.health <= 0) {
      restartLevel();
      return;
    }
    final Set<DoomControl> controls = _touchControls.putIfAbsent(
      pointer,
      () => <DoomControl>{},
    );
    if (controls.add(control)) {
      input.pressOwned(_touchOwner(pointer), control);
    }
  }

  @override
  void releaseTouchPointer(int pointer, {bool cancelled = false}) {
    _validatePointer(pointer);
    final Set<DoomControl>? controls = _touchControls.remove(pointer);
    if (controls != null) {
      final Object owner = _touchOwner(pointer);
      for (final DoomControl control in controls) {
        input.releaseOwned(owner, control, cancelled: cancelled);
      }
    }
    if (_touchMovementPointer == pointer) {
      _touchMovementPointer = null;
      input.setAnalogAxes(forward: 0, side: 0);
    }
  }

  @override
  void clearTouchInput() {
    for (final int pointer in _touchControls.keys.toList(growable: false)) {
      releaseTouchPointer(pointer, cancelled: true);
    }
    final int? movementPointer = _touchMovementPointer;
    if (movementPointer != null) {
      releaseTouchPointer(movementPointer, cancelled: true);
    }
  }

  @override
  void triggerUse() {
    if (!_acceptsGameplayInput) return;
    if (gameState.player.health <= 0) {
      restartLevel();
      return;
    }
    input.triggerUse();
  }

  @override
  void selectWeapon(int slot) {
    if (!_acceptsGameplayInput) return;
    input.selectWeapon(slot);
  }

  @override
  void togglePause() {
    if (!hasReplayInput && !gameState.levelComplete) input.triggerPause();
  }

  @override
  void toggleAutomap() => _automap.toggle();

  @override
  void zoomAutomap({required bool inwards}) =>
      inwards ? _automap.zoomIn() : _automap.zoomOut();

  @override
  void clearInput() {
    _keyboardControls.clear();
    _touchControls.clear();
    _touchMovementPointer = null;
    input.clear();
    _enqueueSoundPlayback(() => _soundPlayback.stopAll());
  }

  @override
  void restartLevel() {
    _damageFlashTics = 0;
    _pickupFlashTics = 0;
    _paletteIndex = DoomPaletteVariant.normal;
    scene.setPaletteIndex(_paletteIndex);
    scene.materials.setFixedColorMap(-1);
    _keyboardControls.clear();
    _touchControls.clear();
    _touchMovementPointer = null;
    input.clear();
    _enqueueSoundPlayback(() => _soundPlayback.stopAll());
    gameState = level.createGame();
    tickDriver = FixedTickDriver(
      maxTicsPerFrame: gameState.config.maxCatchUpTics,
    );
    _soundJournal = DoomCoreSoundJournal(gameState);
    _paused = false;
    _completionReported = false;
    _replayCommandCount = 0;
    _replayResult = null;
    _pendingReplayTerminal = null;
    _fractionalMicros = 0;
    _previousPlayer = gameState.player;
    _currentPlayer = gameState.player;
    var sector = 0;
    for (final runtimeSector in gameState.sectors) {
      _sectorFloors[sector] = fixedToDouble(runtimeSector.floorHeight);
      _sectorCeilings[sector] = fixedToDouble(runtimeSector.ceilingHeight);
      sector++;
    }
    scene.resetDynamicState(level.map);
    _automap.reset(_currentPlayer);
    _weaponFlashSprite?.setVisible(false);
    _syncActors();
    _syncWeapon(force: true);
    _syncCamera(0);
    _publishHud();
  }

  @override
  void onRemove() {
    _keyboardControls.clear();
    _touchControls.clear();
    _touchMovementPointer = null;
    input.clear();
    _enqueueSoundPlayback(() => _soundPlayback.dispose());
    unawaited(_soundPlaybackTail);
    _hud.dispose();
    _automap.dispose();
    super.onRemove();
  }

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    if (hasReplayInput) return KeyEventResult.handled;
    final bool down = event is KeyDownEvent || event is KeyRepeatEvent;
    final bool up = event is KeyUpEvent;
    final key = event.logicalKey;
    final physicalKey = event.physicalKey;
    final Object owner = _keyboardOwner(physicalKey);
    if (up) {
      // The logical key may change with the active keyboard layout between
      // down and up. The physical-key mapping captured on key-down therefore
      // takes precedence over resolving the release event again.
      final DoomControl? mapped = _keyboardControls.remove(physicalKey);
      if (mapped != null) {
        input.releaseOwned(owner, mapped);
        return KeyEventResult.handled;
      }
    }
    if (down &&
        event is! KeyRepeatEvent &&
        key == LogicalKeyboardKey.escape &&
        !gameState.levelComplete) {
      input.triggerPause();
      return KeyEventResult.handled;
    }
    if (_paused || gameState.levelComplete) return KeyEventResult.handled;
    if (down &&
        event is! KeyRepeatEvent &&
        gameState.player.health <= 0 &&
        (_isAttackKey(key, physicalKey) ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.keyE ||
            physicalKey == PhysicalKeyboardKey.keyE)) {
      restartLevel();
      return KeyEventResult.handled;
    }
    final DoomControl? control = _resolveKeyboardControl(key, physicalKey);
    if (control != null) {
      if (down) {
        final DoomControl? previous = _keyboardControls[physicalKey];
        _keyboardControls[physicalKey] = control;
        if (previous != null && previous != control) {
          input.releaseOwned(owner, previous, cancelled: true);
        }
        input.pressOwned(owner, control);
      }
      return KeyEventResult.handled;
    }
    if (down && event is! KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.keyE ||
          physicalKey == PhysicalKeyboardKey.keyE) {
        input.triggerUse();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        toggleAutomap();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd) {
        zoomAutomap(inwards: true);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        zoomAutomap(inwards: false);
        return KeyEventResult.handled;
      }
      final int? slot = switch (key) {
        LogicalKeyboardKey.digit1 => 0,
        LogicalKeyboardKey.digit2 => 1,
        LogicalKeyboardKey.digit3 => 2,
        LogicalKeyboardKey.digit4 => 3,
        LogicalKeyboardKey.digit5 => 4,
        LogicalKeyboardKey.digit6 => 5,
        _ => null,
      };
      if (slot != null) {
        input.selectWeapon(slot);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  static DoomControl? _resolveKeyboardControl(
    LogicalKeyboardKey key,
    PhysicalKeyboardKey physicalKey,
  ) {
    // Physical WASD wins when both identities describe movement, keeping the
    // controls layout-stable. Logical keys remain aliases and cover arrows.
    if (physicalKey == PhysicalKeyboardKey.keyW) {
      return DoomControl.forward;
    }
    if (physicalKey == PhysicalKeyboardKey.keyS) {
      return DoomControl.backward;
    }
    if (physicalKey == PhysicalKeyboardKey.keyA) {
      return DoomControl.strafeLeft;
    }
    if (physicalKey == PhysicalKeyboardKey.keyD) {
      return DoomControl.strafeRight;
    }
    if (key == LogicalKeyboardKey.keyW || key == LogicalKeyboardKey.arrowUp) {
      return DoomControl.forward;
    }
    if (key == LogicalKeyboardKey.keyS || key == LogicalKeyboardKey.arrowDown) {
      return DoomControl.backward;
    }
    if (key == LogicalKeyboardKey.keyA) return DoomControl.strafeLeft;
    if (key == LogicalKeyboardKey.keyD) return DoomControl.strafeRight;
    if (key == LogicalKeyboardKey.arrowLeft) return DoomControl.turnLeft;
    if (key == LogicalKeyboardKey.arrowRight) return DoomControl.turnRight;
    if (key == LogicalKeyboardKey.shiftLeft) return DoomControl.runLeft;
    if (key == LogicalKeyboardKey.shiftRight) return DoomControl.runRight;
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        _isAttackKey(key, physicalKey)) {
      return DoomControl.attack;
    }
    return null;
  }

  bool get _acceptsGameplayInput =>
      !hasReplayInput && !_paused && !gameState.levelComplete;

  static bool _isAttackKey(
    LogicalKeyboardKey key,
    PhysicalKeyboardKey physicalKey,
  ) =>
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      physicalKey == PhysicalKeyboardKey.enter ||
      physicalKey == PhysicalKeyboardKey.numpadEnter;

  static void _validatePointer(int pointer) {
    if (pointer < 0) throw RangeError.value(pointer, 'pointer');
  }

  static Object _keyboardOwner(PhysicalKeyboardKey key) =>
      (_DeviceInputKind.keyboard, key);

  static Object _touchOwner(int pointer) => (_DeviceInputKind.touch, pointer);

  static const Object _mouseAttackOwner = (_DeviceInputKind.mouse, 0);

  static CameraComponent3D _cameraFor(PlayerView player) {
    final double x = fixedToDouble(player.x);
    final double y = fixedToDouble(player.viewZ);
    final double z = -fixedToDouble(player.y);
    return DoomCameraComponent(
      position: Vector3(x, y, z),
      target: Vector3(x + 64, y, z),
    );
  }

  static double _lerpFixed(int a, int b, double t) =>
      fixedToDouble(a) + (fixedToDouble(b) - fixedToDouble(a)) * t;

  static double _bamRadians(int angle) =>
      normalizeAngle(angle) * (math.pi * 2 / kAngMax);

  /// flame_3d/catalog yaw uses zero at world +Z; Doom BAM zero faces +X.
  static double worldActorYawForBam(int angle) =>
      _bamRadians(angle) + math.pi / 2;
}

enum _DeviceInputKind { keyboard, mouse, touch }

final class _CountingValueNotifier<T> extends ValueNotifier<T> {
  _CountingValueNotifier(super.value);

  int listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    listenerCount++;
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (listenerCount > 0) {
      listenerCount--;
    }
  }
}

final class _CountingValueListenable<T> implements ValueListenable<T> {
  _CountingValueListenable(this._source);

  final ValueListenable<T> _source;
  int listenerCount = 0;

  @override
  T get value => _source.value;

  @override
  void addListener(VoidCallback listener) {
    _source.addListener(listener);
    listenerCount++;
  }

  @override
  void removeListener(VoidCallback listener) {
    _source.removeListener(listener);
    if (listenerCount > 0) {
      listenerCount--;
    }
  }
}
