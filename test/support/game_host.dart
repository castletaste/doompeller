import 'package:doom_core/doom_core.dart' as core;
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_automap.dart';
import 'package:doompeller/game/doom_hud.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'runtime_noops.dart';

/// Synthetic level and runtime doubles shared by widget and lifecycle tests.
Future<PreparedDoomLevel> fixtureLevel() async {
  final content = DoomContentSource(
    environment: const <String, String>{},
  ).loadFixture();
  final resources = WadResources.load(content.wads);
  final map = MapData.load(content.wads, content.mapName);
  return PreparedDoomLevel(
    content: content,
    resources: resources,
    map: map,
    geometry: DoomGeometryCompiler.compile(map, resources),
    gameConfig: const core.GameConfig(),
    seed: 0,
  );
}

final class FakeRuntime with DoomRuntimeNoopInput implements DoomRuntimeView {
  @override
  void dispose() {}

  @override
  void setAudioFocused(bool focused) {}

  @override
  void clearInputPreservingAudio() => clearInput();

  @override
  final ValueNotifier<int> movementRevision = ValueNotifier<int>(0);

  @override
  VoidCallback? onPauseRequested;

  @override
  void setPaused(bool paused) => togglePause();

  @override
  void cycleWeapon(int direction) {}

  @override
  core.LevelExit? levelExit;

  final ValueNotifier<DoomHudSnapshot> notifier =
      ValueNotifier<DoomHudSnapshot>(const DoomHudSnapshot.initial());

  @override
  ValueListenable<DoomHudSnapshot> get hud => notifier;

  final ValueNotifier<DoomAutomapSnapshot> automapNotifier = ValueNotifier(
    const DoomAutomapSnapshot(
      isOpen: false,
      zoom: DoomAutomapState.initialZoom,
      playerX: 0,
      playerY: 0,
      playerAngle: 0,
      visitedLines: <int>{},
    ),
  );

  @override
  ValueListenable<DoomAutomapSnapshot> get automap => automapNotifier;

  int clearInputCalls = 0;
  int restartCalls = 0;
  final DoomInputState input = DoomInputState();

  @override
  void addPointerYaw(double deltaX) {}

  @override
  void clearInput() {
    clearInputCalls++;
    input.clear();
  }

  @override
  void restartLevel() {
    restartCalls++;
    notifier.value = const DoomHudSnapshot.initial();
  }

  @override
  void setPointerAttack(bool pressed, {bool cancelled = false}) {}

  @override
  void setTouchMovement(
    int pointer, {
    required int forward,
    required int side,
  }) {}

  @override
  void pressTouchControl(int pointer, DoomControl control) {}

  @override
  void releaseTouchPointer(int pointer, {bool cancelled = false}) {}

  @override
  void clearTouchInput() {}

  @override
  void triggerUse() => input.triggerUse();

  @override
  void selectWeapon(int slot) => input.selectWeapon(slot);

  @override
  void togglePause() {
    final old = notifier.value;
    notifier.value = DoomHudSnapshot(
      health: old.health,
      armor: old.armor,
      bullets: old.bullets,
      shells: old.shells,
      weapon: old.weapon,
      keys: old.keys,
      kills: old.kills,
      totalKills: old.totalKills,
      items: old.items,
      totalItems: old.totalItems,
      secrets: old.secrets,
      totalSecrets: old.totalSecrets,
      levelTime: old.levelTime,
      paused: !old.paused,
      levelComplete: old.levelComplete,
      diagnostics: old.diagnostics,
    );
  }

  @override
  void toggleAutomap() {}

  @override
  void zoomAutomap({required bool inwards}) {}
}

Widget testSurface(BuildContext context, DoomRuntimeView runtime) =>
    const ColoredBox(key: Key('fake-game-surface'), color: Colors.black);
