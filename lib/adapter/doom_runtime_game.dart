import 'dart:async';
import 'dart:math' as math;

import 'package:doom_core/doom_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:vector_math/vector_math.dart';

import '../game/doom_hud.dart';
import '../game/doom_automap.dart';
import '../game/doom_input.dart';
import '../game/doom_replay_input.dart';
import '../game/doom_replay_session.dart';
import '../game/doom_device_input.dart';
import '../game/level_preparer.dart';
import '../game/sound_playback.dart';
import '../game/doom_sound_output.dart';
import '../game/audio_session.dart';
import 'doom_scene.dart';
import 'doom_sprite_catalog.dart';
import 'doom_camera.dart';
import 'doom_scene_host.dart';
import 'palette_textures.dart';

export '../game/doom_replay_input.dart';

part 'doom_runtime_replay.dart';
part 'doom_runtime_audio.dart';
part 'doom_runtime_presentation.dart';
part 'doom_runtime_lifecycle.dart';

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

/// Production 35 Hz simulation and the retained scene it presents.
///
/// The runtime owns simulation, input, audio and HUD publication. It draws
/// nothing itself: a scene surface calls [update] once per displayed frame and
/// presents [scene] from [camera].
final class DoomRuntimeGame implements DoomRuntimeView, DoomSceneHost {
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
      audioBackend,
      SoundPlaybackManager(
        backend: audioBackend,
        catalog: WadSoundCatalog(level.resources),
        bossArena: level.map.name == 'E1M8',
      ),
      camera: _cameraFor(player),
      packedSpritePrefixes: packed,
    );
  }

  DoomRuntimeGame._(
    PreparedDoomLevel level,
    DoomScene scene,
    this.gameState,
    this.input,
    this.replayInput,
    this._onLevelComplete,
    this._audioBackend,
    this._soundPlayback, {
    required this.camera,
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
       ] {
    _level = level;
    _scene = scene;
    _automap.updatePlayer(
      gameState.player,
      sectorIndex: gameState.playerSectorIndex,
    );
    _syncActors();
    _syncWeapon(force: true);
    _syncCamera(0);
    _publishHud();
    _playLevelMusic();
  }

  late final PreparedDoomLevel _level;
  late final DoomScene _scene;

  @override
  final DoomCamera camera;
  bool _disposed = false;
  PreparedDoomLevel get level => _level;
  late final Set<String> _availableSpriteNames = level.resources.spriteNames
      .toSet();
  @override
  DoomScene get scene => _scene;
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
  final AudioBackend _audioBackend;
  bool _completionMusicStarted = false;
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
  final _movementRevision = ValueNotifier<int>(0);
  @override
  ValueListenable<int> get movementRevision => _movementRevision;
  @override
  VoidCallback? onPauseRequested;
  int? _wheelWeaponSlot;

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
  void update(double dt) {
    if (_disposed) return;
    // A surface can issue zero-delta updates before its ticker reports the
    // first positive interval. Those zeroes do not establish a render-clock
    // origin. The first positive interval can include mounting and
    // first-render work, so it is consumed without fast-forwarding the Doom
    // simulation.
    final bool establishingRenderClock = !_renderClockPrimed && dt > 0;
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

  @override
  void setAudioFocused(bool focused) {
    if (_disposed) return;
    if (!focused) _soundOutput.stop();
    _withMusic((backend) => backend.setFocused(focused));
  }

  @override
  void clearInputPreservingAudio() {
    if (!_disposed) _devices.clear();
  }

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

  void _runTic(TicCmd command) {
    _previousPlayer = _currentPlayer;
    gameState.runTic(command);
    _currentPlayer = gameState.player;
    if (_currentPlayer.weapon != _previousPlayer.weapon) {
      _wheelWeaponSlot = null;
    }
    if (_currentPlayer.x != _previousPlayer.x ||
        _currentPlayer.y != _previousPlayer.y ||
        _currentPlayer.angle != _previousPlayer.angle) {
      _movementRevision.value++;
    }
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
      if (!_completionMusicStarted) {
        _completionMusicStarted = true;
        _playMusic(level.map.name == 'E1M8' ? 'D_VICTOR' : 'D_INTER');
      }
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

  void _processPauseToggle() {
    if (hasReplayInput) {
      input.takePauseToggle();
      return;
    }
    if (input.takePauseToggle()) {
      _paused = !_paused;
      if (_paused) clearInput();
      _setMusicPaused(_paused);
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
    if (_acceptsGameplayInput) {
      _wheelWeaponSlot = slot;
      input.selectWeapon(slot);
    }
  }

  @override
  void setPaused(bool paused) {
    if (_disposed ||
        hasReplayInput ||
        gameState.levelComplete ||
        _paused == paused) {
      return;
    }
    _paused = paused;
    clearInput();
    _setMusicPaused(paused);
    _publishHud();
  }

  @override
  void cycleWeapon(int direction) {
    if (!_acceptsGameplayInput ||
        gameState.player.health <= 0 ||
        direction == 0) {
      return;
    }
    const slots = [
      Weapon.fist,
      Weapon.pistol,
      Weapon.shotgun,
      Weapon.chaingun,
      Weapon.rocketLauncher,
      Weapon.chainsaw,
    ];
    final current = _wheelWeaponSlot ?? slots.indexOf(gameState.player.weapon);
    for (var offset = 1; offset <= slots.length; offset++) {
      final slot = (current + offset * direction.sign) % slots.length;
      if (gameState.ownsWeapon(slots[slot])) {
        selectWeapon(slot);
        return;
      }
    }
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
    _wheelWeaponSlot = null;
    _soundOutput.stop();
  }

  @override
  void restartLevel() {
    _restartLifecycle();
  }

  @override
  void dispose() {
    _disposeLifecycle();
  }

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    if (_disposed || hasReplayInput) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        onPauseRequested != null) {
      if (event is KeyDownEvent) onPauseRequested!();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) _wheelWeaponSlot = null;
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

  static DoomCamera _cameraFor(PlayerView player) {
    final double x = fixedToDouble(player.x);
    final double y = fixedToDouble(player.viewZ);
    final double z = -fixedToDouble(player.y);
    return DoomCamera(
      position: Vector3(x, y, z),
      target: Vector3(x + 64, y, z),
    );
  }

  static double _lerpFixed(int a, int b, double t) =>
      fixedToDouble(a) + (fixedToDouble(b) - fixedToDouble(a)) * t;

  static double _bamRadians(int angle) =>
      normalizeAngle(angle) * (math.pi * 2 / kAngMax);

  /// The sprite catalog measures yaw from world +Z; Doom BAM zero faces +X.
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
