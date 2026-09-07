import 'package:doom_core/doom_core.dart' as core;
import 'package:flutter/foundation.dart';

import 'doom_automap.dart';
import 'doom_input.dart';

@immutable
final class DoomFrameDiagnosticsSnapshot {
  const DoomFrameDiagnosticsSnapshot({
    this.tics = 0,
    this.droppedTics = 0,
    this.surfaces = 0,
    this.dynamicUploads = 0,
  });

  final int tics;
  final int droppedTics;
  final int surfaces;
  final int dynamicUploads;
  @override
  bool operator ==(Object other) =>
      other is DoomFrameDiagnosticsSnapshot &&
      tics == other.tics &&
      droppedTics == other.droppedTics &&
      surfaces == other.surfaces &&
      dynamicUploads == other.dynamicUploads;
  @override
  int get hashCode => Object.hash(tics, droppedTics, surfaces, dynamicUploads);
}

@immutable
final class DoomHudSnapshot {
  const DoomHudSnapshot({
    required this.health,
    required this.armor,
    required this.bullets,
    required this.shells,
    this.rockets = 0,
    required this.weapon,
    required this.keys,
    required this.kills,
    required this.totalKills,
    required this.items,
    required this.totalItems,
    required this.secrets,
    required this.totalSecrets,
    required this.levelTime,
    required this.paused,
    required this.levelComplete,
    required this.diagnostics,
  });

  const DoomHudSnapshot.initial()
    : health = 100,
      armor = 0,
      bullets = 50,
      shells = 0,
      rockets = 0,
      weapon = core.Weapon.pistol,
      keys = const <core.Key>{},
      kills = 0,
      totalKills = 0,
      items = 0,
      totalItems = 0,
      secrets = 0,
      totalSecrets = 0,
      levelTime = 0,
      paused = false,
      levelComplete = false,
      diagnostics = const DoomFrameDiagnosticsSnapshot();

  final int health;
  final int armor;
  final int bullets;
  final int shells;
  final int rockets;
  final core.Weapon weapon;
  final Set<core.Key> keys;
  final int kills;
  final int totalKills;
  final int items;
  final int totalItems;
  final int secrets;
  final int totalSecrets;
  final int levelTime;
  final bool paused;
  final bool levelComplete;
  final DoomFrameDiagnosticsSnapshot diagnostics;
  @override
  bool operator ==(Object other) =>
      other is DoomHudSnapshot &&
      health == other.health &&
      armor == other.armor &&
      bullets == other.bullets &&
      shells == other.shells &&
      rockets == other.rockets &&
      weapon == other.weapon &&
      kills == other.kills &&
      totalKills == other.totalKills &&
      items == other.items &&
      totalItems == other.totalItems &&
      secrets == other.secrets &&
      totalSecrets == other.totalSecrets &&
      levelTime == other.levelTime &&
      paused == other.paused &&
      levelComplete == other.levelComplete &&
      diagnostics == other.diagnostics &&
      setEquals(keys, other.keys);
  @override
  int get hashCode => Object.hashAll([
    health,
    armor,
    bullets,
    shells,
    rockets,
    weapon,
    kills,
    totalKills,
    items,
    totalItems,
    secrets,
    totalSecrets,
    levelTime,
    paused,
    levelComplete,
    diagnostics,
    Object.hashAllUnordered(keys),
  ]);
}

abstract interface class DoomRuntimeView {
  core.LevelExit? get levelExit;

  ValueListenable<DoomHudSnapshot> get hud;

  ValueListenable<DoomAutomapSnapshot> get automap;

  void setPointerAttack(bool pressed, {bool cancelled = false});

  void addPointerYaw(double deltaX);

  void setTouchMovement(int pointer, {required int forward, required int side});

  void pressTouchControl(int pointer, DoomControl control);

  void releaseTouchPointer(int pointer, {bool cancelled = false});

  void clearTouchInput();

  void triggerUse();

  void selectWeapon(int slot);

  void togglePause();

  void toggleAutomap();

  void zoomAutomap({required bool inwards});

  void clearInput();

  void restartLevel();
}

/// Optional lifecycle contract for runtimes created by a UI runtime factory.
/// The host calls this once; implementations also tolerate adapter teardown.
abstract interface class DoomRuntimeLifecycle {
  void dispose();
}
