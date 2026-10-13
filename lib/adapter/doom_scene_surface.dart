import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';

import 'doom_scene_host.dart';
import 'doom_scene_presenter.dart';

/// Presents a [DoomSceneHost] with flutter_scene.
///
/// Each displayed frame advances the host by the frame's wall time, mirrors
/// its scene into the GPU scene and draws it from the host's camera. Key
/// events reach the host while this surface holds focus. The surface owns the
/// GPU scene; the host stays owned by its creator.
final class DoomSceneSurface extends StatefulWidget {
  const DoomSceneSurface({
    super.key,
    required this.host,
    this.focusNode,
    this.autofocus = true,
  });

  final DoomSceneHost host;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<DoomSceneSurface> createState() => _DoomSceneSurfaceState();
}

final class _DoomSceneSurfaceState extends State<DoomSceneSurface> {
  late DoomScenePresenter _presenter = _presenterFor(widget.host);

  /// Populates the GPU scene before SceneView's warm-up, so the palette
  /// pipelines compile while the loading frame is up rather than on the
  /// first visible frame.
  static DoomScenePresenter _presenterFor(DoomSceneHost host) =>
      DoomScenePresenter()..sync(host.scene, host.camera);

  @override
  void didUpdateWidget(DoomSceneSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.host, widget.host)) {
      _presenter.dispose();
      _presenter = _presenterFor(widget.host);
    }
  }

  @override
  void dispose() {
    _presenter.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed, double deltaSeconds) {
    final host = widget.host;
    host.update(deltaSeconds);
    _presenter.sync(host.scene, host.camera);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) => widget.host
      .onKeyEvent(event, HardwareKeyboard.instance.logicalKeysPressed);

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: ColoredBox(
        color: host.backgroundColor(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            host.camera.setViewportSize(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            return SceneView(
              _presenter.scene,
              cameraBuilder: (_) => _presenter.cullingCamera(host.camera),
              onTick: _onTick,
            );
          },
        ),
      ),
    );
  }
}
