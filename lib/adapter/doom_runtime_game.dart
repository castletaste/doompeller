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
import '../game/doom_replay_input.dart';
import '../game/doom_replay_session.dart';
import '../game/doom_device_input.dart';
import '../game/level_preparer.dart';
import '../game/sound_playback.dart';
import '../game/doom_sound_output.dart';
import 'doom_scene.dart';
import 'doom_sprite_catalog.dart';
import 'doom_camera.dart';
import 'palette_textures.dart';

export '../game/doom_replay_input.dart';

typedef DoomLevelCompleteCallback = void Function(bool secretExit);

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
    implements DoomRuntimeView, DoomRuntimeLifecycle {
  @override
  LevelExit? get levelExit => gameState.levelExit;

  bool _disposed = false;
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
      level.geometry.copyForRuntime(),
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
  late final Set<String> _availableSpriteNames = level.resources.spriteNames
      .toSet();
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
  late final DoomDeviceInput _devices = DoomDeviceInput(input);
  final Set<String> _reportedMissingSprites = <String>{};
  final _CountingValueNotifier<DoomHudSnapshot> _hud =
      _CountingValueNotifier<DoomHudSnapshot>(const DoomHudSnapshot.initial());
  final DoomAutomapState _automap;
  late final _CountingValueListenable<DoomAutomapSnapshot> _automapListenable =
      _CountingValueListenable<DoomAutomapSnapshot>(_automap);
  final SoundPlaybackManager _soundPlayback;
  late DoomCoreSoundJournal _soundJournal = DoomCoreSoundJournal(gameState);
  late final DoomSoundOutput _soundOutput = DoomSoundOutput(
    _soundPlayback,
    onError: _recordSoundPlaybackError,
  );
  int _soundPlaybackErrorCount = 0;
  Object? _lastSoundPlaybackError;
  StackTrace? _lastSoundPlaybackStackTrace;

  PlayerView _previousPlayer;
  PlayerView _currentPlayer;
  ViewLockedWeaponSpriteComponent? _weaponSprite;
  ViewLockedWeaponSpriteComponent? _weaponFlashSprite;
  bool _paused = false;
  bool _completionReported = false;
  late final DoomReplaySession? _replay = replayInput == null
      ? null
      : DoomReplaySession(replayInput!);
  _ReplayTerminalDelivery? _pendingReplayTerminal;
  double _fractionalMicros = 0;
  bool _renderClockPrimed = false;

  @override
  ValueListenable<DoomHudSnapshot> get hud => _hud;

  @override
  ValueListenable<DoomAutomapSnapshot> get automap => _automapListenable;

  bool get isPaused => _paused;
  bool get hasReplayInput => replayInput != null;
  int get replayCommandCount => _replay?.commandCount ?? 0;
  DoomReplayResult? get replayResult => _replay?.result;
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
    if (!_disposed) world.add(scene.root);
  }

  @override
  void update(double dt) {
    if (_disposed) return;
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
    if (_disposed) return;
    _syncCamera(tickDriver.interpolationAlpha);
    _publishHud();
  }

  /// Deterministic clock entry point used by runtime tests.
  int advanceMicrosForTest(int elapsedMicros) {
    if (_disposed) return 0;
    _processPauseToggle();
    var executed = 0;
    if (_simulationActive) {
      executed = _advanceMicros(elapsedMicros);
    }
    if (!_disposed) {
      _syncCamera(tickDriver.interpolationAlpha);
      _publishHud();
    }
    return executed;
  }

  void renderCameraAtForTest(double alpha) => _syncCamera(alpha);

  Future<void> get soundPlaybackIdleForTest => _soundOutput.idle;

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
      !_disposed &&
      !_paused &&
      !gameState.levelComplete &&
      replayResult == null;

  int _advanceMicros(int elapsedMicros) {
    final replay = _replay;
    if (replay == null) {
      return tickDriver.advanceMicros(
        elapsedMicros,
        (_) => _runDueTic(),
        TicCmd.empty,
      );
    }
    if (!replay.hasNext) {
      _stageReplayTerminal(DoomReplayStatus.earlyEnd);
      _deliverReplayTerminal();
      return 0;
    }
    final FixedTickDriver activeDriver = tickDriver;
    final int executed = activeDriver.advanceMicrosWhile(elapsedMicros, (_) {
      _runDueTic();
      return replayResult == null;
    }, TicCmd.empty);
    _deliverReplayTerminal();
    return executed;
  }

  void _runDueTic() {
    if (!_simulationActive) return;
    final replay = _replay;
    if (replay == null) {
      _runTic(input.consume().command);
      return;
    }
    if (!replay.hasNext) {
      _stageReplayTerminal(DoomReplayStatus.earlyEnd);
      return;
    }
    _runTic(replay.takeCommand());
    final status = replay.outcomeAfterTic(gameState);
    if (status != null) _stageReplayTerminal(status);
  }

  void _stageReplayTerminal(DoomReplayStatus status) {
    final replay = _replay!;
    final result = replay.finish(status, gameState);
    if (result == null) return;
    if (status == DoomReplayStatus.complete) {
      _completionReported = true;
    }
    _pendingReplayTerminal = _ReplayTerminalDelivery(
      result: result,
      secretExit: gameState.usedSecretExit,
      onFinished: replay.input.onFinished,
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
      sectorHeights: _consumeSectorJournal(),
    );
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
    _soundOutput.add(events: events, listener: listener, gameTic: gameTic);
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

  void _recordSoundPlaybackError(Object error, StackTrace stackTrace) {
    _soundPlaybackErrorCount++;
    _lastSoundPlaybackError = error;
    _lastSoundPlaybackStackTrace = stackTrace;
    debugPrint(
      'doompeller: audio output failed (${error.runtimeType}); '
      'count=$_soundPlaybackErrorCount',
    );
  }

  Iterable<AutomapSectorHeights> _consumeSectorJournal() {
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
    return automapHeightChanges.map(
      (sector) => (
        sectorIndex: sector,
        floorHeight: _sectorFloors[sector],
        ceilingHeight: _sectorCeilings[sector],
      ),
    );
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
    return _availableSpriteNames.contains(candidate) ? candidate : null;
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
    return _availableSpriteNames.contains(candidate) ? candidate : null;
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

  bool get _acceptsGameplayInput =>
      !_disposed && !hasReplayInput && !_paused && !gameState.levelComplete;

  @override
  void setPointerAttack(bool pressed, {bool cancelled = false}) {
    if (_disposed) return;
    if (!pressed) {
      _devices.setPointerAttack(false, cancelled: cancelled);
      return;
    }
    if (!_acceptsGameplayInput) return;
    if (gameState.player.health <= 0) {
      restartLevel();
      return;
    }
    _devices.setPointerAttack(true);
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
    if (_disposed) return;
    _devices.setTouchMovement(
      pointer,
      forward: forward,
      side: side,
      enabled: _acceptsGameplayInput,
    );
  }

  @override
  void pressTouchControl(int pointer, DoomControl control) {
    if (_disposed) return;
    if (_devices.pressTouchControl(
          pointer,
          control,
          enabled: _acceptsGameplayInput,
          playerDead: gameState.player.health <= 0,
        ) ==
        DoomDeviceAction.restart) {
      restartLevel();
    }
  }

  @override
  void releaseTouchPointer(int pointer, {bool cancelled = false}) {
    if (_disposed) return;
    _devices.releaseTouchPointer(pointer, cancelled: cancelled);
  }

  @override
  void clearTouchInput() {
    if (!_disposed) _devices.clearTouchInput();
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
    if (_acceptsGameplayInput) input.selectWeapon(slot);
  }

  @override
  void togglePause() {
    if (!_disposed && !hasReplayInput && !gameState.levelComplete) {
      input.triggerPause();
    }
  }

  @override
  void toggleAutomap() {
    if (!_disposed) _automap.toggle();
  }

  @override
  void zoomAutomap({required bool inwards}) {
    if (_disposed) return;
    inwards ? _automap.zoomIn() : _automap.zoomOut();
  }

  @override
  void clearInput() {
    if (_disposed) return;
    _devices.clear();
    _soundOutput.stop();
  }

  @override
  void restartLevel() {
    if (_disposed) return;
    _damageFlashTics = 0;
    _pickupFlashTics = 0;
    _paletteIndex = DoomPaletteVariant.normal;
    scene.setPaletteIndex(_paletteIndex);
    scene.materials.setFixedColorMap(-1);
    _devices.clear();
    _soundOutput.stop();
    gameState = level.createGame();
    tickDriver = FixedTickDriver(
      maxTicsPerFrame: gameState.config.maxCatchUpTics,
    );
    _soundJournal = DoomCoreSoundJournal(gameState);
    _paused = false;
    _completionReported = false;
    _replay?.reset();
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
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _devices.clear();
    _soundOutput.dispose();
    _hud.dispose();
    _automap.dispose();
  }

  @override
  void onRemove() {
    dispose();
    super.onRemove();
  }

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    if (_disposed || hasReplayInput) return KeyEventResult.handled;
    switch (_devices.handle(
      event,
      playerDead: gameState.player.health <= 0,
      paused: _paused,
      levelComplete: gameState.levelComplete,
    )) {
      case DoomDeviceAction.ignored:
        return KeyEventResult.ignored;
      case DoomDeviceAction.handled:
        break;
      case DoomDeviceAction.restart:
        restartLevel();
      case DoomDeviceAction.toggleAutomap:
        toggleAutomap();
      case DoomDeviceAction.zoomIn:
        zoomAutomap(inwards: true);
      case DoomDeviceAction.zoomOut:
        zoomAutomap(inwards: false);
    }
    return KeyEventResult.handled;
  }

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
