import 'package:doompeller/game/doom_hud.dart';
import 'package:doompeller/game/doom_input.dart';

/// Fills the host-only input/lifecycle hooks that a widget fake does not use.
///
/// The production runtime contract stays complete; widget tests only provide
/// the observables and commands relevant to the scenario under test.
mixin DoomRuntimeNoopInput {
  void dispose() {}

  void setAudioFocused(bool focused) {}

  void clearInputPreservingAudio() => (this as DoomRuntimeView).clearInput();

  void setPaused(bool paused) => (this as DoomRuntimeView).togglePause();

  void cycleWeapon(int direction) {}

  void addPointerYaw(double deltaX) {}

  void setPointerAttack(bool pressed, {bool cancelled = false}) {}

  void setTouchMovement(
    int pointer, {
    required int forward,
    required int side,
  }) {}

  void pressTouchControl(int pointer, DoomControl control) {}

  void releaseTouchPointer(int pointer, {bool cancelled = false}) {}

  void clearTouchInput() {}

  void toggleAutomap() {}

  void zoomAutomap({required bool inwards}) {}
}
