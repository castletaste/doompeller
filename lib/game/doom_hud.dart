import 'package:doom_core/doom_core.dart' as core;
import 'package:flutter/foundation.dart';

import 'doom_automap.dart';

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
}

@immutable
final class DoomHudSnapshot {
  const DoomHudSnapshot({
    required this.health,
    required this.armor,
    required this.bullets,
    required this.shells,
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
}

abstract interface class DoomRuntimeView {
  ValueListenable<DoomHudSnapshot> get hud;

  ValueListenable<DoomAutomapSnapshot> get automap;

  void setPointerAttack(bool pressed);

  void addPointerYaw(double deltaX);

  void togglePause();

  void toggleAutomap();

  void zoomAutomap({required bool inwards});

  void clearInput();
}
