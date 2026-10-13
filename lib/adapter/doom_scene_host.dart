import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import 'doom_camera.dart';
import 'doom_scene.dart';

/// What the scene surface needs from whatever drives a level.
///
/// The production runtime and the renderer smoke harness both implement it.
/// The surface owns the frame clock and focus; the host owns simulation,
/// camera pose and the renderable scene.
abstract interface class DoomSceneHost {
  /// The renderable objects for the current level.
  DoomScene get scene;

  /// The view the frame is drawn from.
  DoomCamera get camera;

  /// The clear colour behind the scene.
  Color backgroundColor();

  /// Advances the host by [dt] seconds of wall time.
  ///
  /// Called once per displayed frame, before the frame is presented, so the
  /// camera and scene it leaves behind are exactly what gets drawn.
  void update(double dt);

  /// Handles a key while the surface has focus.
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  );
}
