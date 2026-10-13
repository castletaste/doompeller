part of 'doom_runtime_game.dart';

extension _DoomRuntimePresentation on DoomRuntimeGame {
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
      final double angle = DoomRuntimeGame.worldActorYawForBam(actor.angle);
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
    final double x = DoomRuntimeGame._lerpFixed(
      _previousPlayer.x,
      _currentPlayer.x,
      t,
    );
    final double mapY = DoomRuntimeGame._lerpFixed(
      _previousPlayer.y,
      _currentPlayer.y,
      t,
    );
    final double viewZ = DoomRuntimeGame._lerpFixed(
      _previousPlayer.viewZ,
      _currentPlayer.viewZ,
      t,
    );
    final int delta = angleDelta(_currentPlayer.angle, _previousPlayer.angle);
    final double angle = DoomRuntimeGame._bamRadians(
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
}
