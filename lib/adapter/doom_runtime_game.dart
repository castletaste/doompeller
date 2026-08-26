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

typedef DoomLevelCompleteCallback = void Function(bool secretExit);

/// Production 35 Hz simulation and retained Flame 3D scene boundary.
final class DoomRuntimeGame extends FlameGame3D
    with KeyboardEvents
    implements DoomRuntimeView {
  factory DoomRuntimeGame(
    PreparedDoomLevel level, {
    DoomInputState? input,
    DoomLevelCompleteCallback? onLevelComplete,
    AudioBackend audioBackend = const NoAudioBackend(),
  }) {
    final Set<String> availablePrefixes = <String>{
      for (final name in level.resources.spriteNames)
        if (name.length >= 4) name.substring(0, 4).toUpperCase(),
    };
    final Set<String> requested = <String>{
      ...level.initialSpritePrefixes,
      'BAL1',
      'BEXP',
      'PUFF',
      'BLUD',
      'PISF',
      'SHTF',
      'CHGF',
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
  final DoomLevelCompleteCallback? _onLevelComplete;
  final Set<String> _packedSpritePrefixes;
  final List<double> _sectorFloors;
  final List<double> _sectorCeilings;
  final Map<int, ActorSpriteComponent> _actors = <int, ActorSpriteComponent>{};
  final Set<String> _reportedMissingSprites = <String>{};
  final _CountingValueNotifier<DoomHudSnapshot> _hud =
      _CountingValueNotifier<DoomHudSnapshot>(const DoomHudSnapshot.initial());
  final DoomAutomapState _automap;
  late final _CountingValueListenable<DoomAutomapSnapshot> _automapListenable =
      _CountingValueListenable<DoomAutomapSnapshot>(_automap);
  final SoundPlaybackManager _soundPlayback;
  late DoomCoreSoundJournal _soundJournal = DoomCoreSoundJournal(gameState);
  Future<void> _soundPlaybackTail = Future<void>.value();

  PlayerView _previousPlayer;
  PlayerView _currentPlayer;
  ViewLockedWeaponSpriteComponent? _weaponSprite;
  ViewLockedWeaponSpriteComponent? _weaponFlashSprite;
  bool _paused = false;
  bool _completionReported = false;
  double _fractionalMicros = 0;

  @override
  ValueListenable<DoomHudSnapshot> get hud => _hud;

  @override
  ValueListenable<DoomAutomapSnapshot> get automap => _automapListenable;

  bool get isPaused => _paused;
  int get actorComponentCount => _actors.length;
  Set<int> get actorIds => Set<int>.unmodifiable(_actors.keys);
  String? get weaponFrame => _weaponSprite?.lumpName;
  String? get weaponFlashFrame => _weaponFlashSprite?.lumpName;
  bool get weaponFlashVisible => _weaponFlashSprite?.visible ?? false;

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
    super.update(dt);
    _processPauseToggle();
    if (!_paused && !gameState.levelComplete) {
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
    final int before = tickDriver.executedTics;
    if (!_paused && !gameState.levelComplete) {
      _advanceMicros(elapsedMicros);
    }
    _syncCamera(tickDriver.interpolationAlpha);
    _publishHud();
    return tickDriver.executedTics - before;
  }

  void renderCameraAtForTest(double alpha) => _syncCamera(alpha);

  Future<void> get soundPlaybackIdleForTest => _soundPlaybackTail;

  ({double x, double y, double z, double targetX, double targetZ})
  get cameraSnapshot => (
    x: camera.position.x,
    y: camera.position.y,
    z: camera.position.z,
    targetX: camera.target.x,
    targetZ: camera.target.z,
  );

  int _advanceMicros(int elapsedMicros) =>
      tickDriver.advanceMicros(elapsedMicros, (_) {
        if (!gameState.levelComplete) {
          _runTic(input.consume().command);
        }
      }, TicCmd.empty);

  void _runTic(TicCmd command) {
    _previousPlayer = _currentPlayer;
    gameState.runTic(command);
    _currentPlayer = gameState.player;
    _automap.updatePlayer(
      _currentPlayer,
      sectorIndex: gameState.playerSectorIndex,
    );
    _consumeSectorJournal();
    _consumeSoundJournal();
    _syncActors();
    _syncWeapon();
    if (gameState.levelComplete && !_completionReported) {
      _completionReported = true;
      _onLevelComplete?.call(gameState.usedSecretExit);
    }
  }

  void _consumeSoundJournal() {
    final List<SoundEvent> events = _soundJournal.consumeSoundJournal().toList(
      growable: false,
    );
    final AudioListener listener = audioListenerFromPlayer(_currentPlayer);
    final int gameTic = gameState.tic;
    _soundPlaybackTail = _soundPlaybackTail.then(
      (_) => _soundPlayback.consumeEvents(
        events: events,
        listener: listener,
        gameTic: gameTic,
      ),
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
    final double anchorY =
        -0.48 + (animation.y - 32 + fixedToDouble(_currentPlayer.bob)) / 200;
    final current = _weaponSprite;
    if (current == null) {
      _weaponSprite = scene.addWeaponSprite(
        WeaponSpriteInstance(
          lumpName: exact,
          viewAnchorX: 0,
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
          viewAnchorX: 0,
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
    };
    final String candidate = '$prefix${String.fromCharCode(65 + frame)}0';
    return level.resources.spriteNames.contains(candidate) ? candidate : null;
  }

  String? _weaponFlashFrameFor(Weapon weapon, int frame) {
    final String? prefix = switch (weapon) {
      Weapon.fist => null,
      Weapon.pistol => 'PISF',
      Weapon.shotgun => 'SHTF',
      Weapon.chaingun => 'CHGF',
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
  }

  void _publishHud() {
    final player = gameState.player;
    _hud.value = DoomHudSnapshot(
      health: player.health,
      armor: player.armor,
      bullets: player.ammo.bullets,
      shells: player.ammo.shells,
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
    if (input.takePauseToggle()) {
      _paused = !_paused;
    }
  }

  @override
  void setPointerAttack(bool pressed) {
    if (pressed && gameState.player.health <= 0) {
      restartLevel();
      return;
    }
    pressed
        ? input.press(DoomControl.attack)
        : input.release(DoomControl.attack);
  }

  @override
  void addPointerYaw(double deltaX) {
    input.addPointerTurn((-deltaX * 24).round());
  }

  @override
  void togglePause() => input.triggerPause();

  @override
  void toggleAutomap() => _automap.toggle();

  @override
  void zoomAutomap({required bool inwards}) =>
      inwards ? _automap.zoomIn() : _automap.zoomOut();

  @override
  void clearInput() => input.clear();

  @override
  void restartLevel() {
    input.clear();
    _soundPlaybackTail = _soundPlaybackTail.then(
      (_) => _soundPlayback.stopAll(),
    );
    gameState = level.createGame();
    tickDriver = FixedTickDriver(
      maxTicsPerFrame: gameState.config.maxCatchUpTics,
    );
    _soundJournal = DoomCoreSoundJournal(gameState);
    _paused = false;
    _completionReported = false;
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
    input.clear();
    _soundPlaybackTail = _soundPlaybackTail.then(
      (_) => _soundPlayback.dispose(),
    );
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
    final bool down = event is KeyDownEvent || event is KeyRepeatEvent;
    final bool up = event is KeyUpEvent;
    final key = event.logicalKey;
    if (down &&
        event is! KeyRepeatEvent &&
        gameState.player.health <= 0 &&
        (key == LogicalKeyboardKey.controlLeft ||
            key == LogicalKeyboardKey.controlRight ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.keyE)) {
      restartLevel();
      return KeyEventResult.handled;
    }
    DoomControl? control;
    if (key == LogicalKeyboardKey.keyW || key == LogicalKeyboardKey.arrowUp) {
      control = DoomControl.forward;
    } else if (key == LogicalKeyboardKey.keyS ||
        key == LogicalKeyboardKey.arrowDown) {
      control = DoomControl.backward;
    } else if (key == LogicalKeyboardKey.keyA) {
      control = DoomControl.strafeLeft;
    } else if (key == LogicalKeyboardKey.keyD) {
      control = DoomControl.strafeRight;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      control = DoomControl.turnLeft;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      control = DoomControl.turnRight;
    } else if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      control = DoomControl.attack;
    }
    if (control != null) {
      if (down) input.press(control);
      if (up) input.release(control);
      return KeyEventResult.handled;
    }
    if (down && event is! KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyE) {
        input.triggerUse();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        input.triggerPause();
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
        _ => null,
      };
      if (slot != null) {
        input.selectWeapon(slot);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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
