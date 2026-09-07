import 'package:doom_core/doom_core.dart' as core;
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../game/frame_probe.dart';
import '../adapter/adapter.dart';
import '../game/audio_backend_factory.dart';
import '../game/doom_automap.dart';
import '../game/doom_hud.dart';
import '../game/level_preparer.dart';
import 'doom_automap.dart';
import 'doom_game_overlays.dart';
import 'doom_status_bar.dart';
import 'doom_intermission.dart';

/// Creates a runtime owned by the level host. Custom runtimes can implement
/// [DoomRuntimeLifecycle] to release their resources when the host unmounts.
typedef DoomRuntimeFactory = DoomRuntimeView Function(PreparedDoomLevel level);
typedef DoomGameSurfaceBuilder =
    Widget Function(BuildContext context, DoomRuntimeView runtime);

/// Production runtime boundary. Direct [DoomRuntimeGame] construction remains
/// silent by default for tests and non-UI tools.
DoomRuntimeView createProductionDoomRuntime(PreparedDoomLevel level) =>
    DoomRuntimeGame(level, audioBackend: createDefaultAudioBackend());

final class DoomGameView extends StatefulWidget {
  const DoomGameView({
    super.key,
    required this.level,
    required this.synthetic,
    required this.setupMessage,
    required this.selectionErrorMessage,
    required this.onLoadIwad,
    required this.onContinue,
    this.runtimeFactory,
    this.gameSurfaceBuilder,
  });

  final PreparedDoomLevel level;
  final bool synthetic;
  final String? setupMessage;
  final String? selectionErrorMessage;
  final VoidCallback? onLoadIwad;
  final Future<void> Function(core.LevelExit) onContinue;
  final DoomRuntimeFactory? runtimeFactory;
  final DoomGameSurfaceBuilder? gameSurfaceBuilder;

  @override
  State<DoomGameView> createState() => _DoomGameViewState();
}

final class _DoomGameViewState extends State<DoomGameView>
    with WidgetsBindingObserver {
  late final DoomRuntimeView _runtime;
  late final FocusNode _gameFocusNode;
  late final Widget _surface;
  bool _showControls = true;
  bool _advancing = false;
  DoomFrameProbe? _frameProbe;

  @override
  void initState() {
    super.initState();
    _runtime = (widget.runtimeFactory ?? createProductionDoomRuntime)(
      widget.level,
    );
    _gameFocusNode = FocusNode(debugLabel: 'Doom game input')
      ..addListener(_handleFocusChange);
    WidgetsBinding.instance.addObserver(this);
    _frameProbe = DoomFrameProbe.startIfEnabled();
    _surface = _DoomInputSurface(
      runtime: _runtime,
      focusNode: _gameFocusNode,
      surfaceBuilder: widget.gameSurfaceBuilder,
    );
  }

  @override
  void dispose() {
    _frameProbe?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _gameFocusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    if (_runtime case final DoomRuntimeLifecycle owned) owned.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _runtime.clearInput();
    }
  }

  void _handleFocusChange() {
    if (!_gameFocusNode.hasFocus) {
      _runtime.clearInput();
    }
  }

  void _restartLevel() {
    _runtime.restartLevel();
    _gameFocusNode.requestFocus();
  }

  Future<void> _continueEpisode() async {
    final core.LevelExit? exit = _runtime.levelExit;
    if (_advancing || exit == null) return;
    setState(() => _advancing = true);
    _runtime.clearInput();
    try {
      await widget.onContinue(exit);
    } finally {
      if (mounted) setState(() => _advancing = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _surface,
          ValueListenableBuilder<DoomAutomapSnapshot>(
            valueListenable: _runtime.automap,
            builder: (context, map, _) => map.isOpen
                ? DoomAutomapOverlay(map: widget.level.map, snapshot: map)
                : const SizedBox.shrink(),
          ),
          Positioned(
            top: 10,
            left: 10,
            child: DoomContentBadge(
              synthetic: widget.synthetic,
              mapName: widget.level.map.name,
              setupMessage: widget.setupMessage,
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showControls)
                  DoomControlsHint(
                    narrow: constraints.maxWidth < 620,
                    onHide: () => setState(() => _showControls = false),
                  )
                else
                  IconButton(
                    key: const Key('show-controls'),
                    tooltip: 'Show controls',
                    onPressed: () => setState(() => _showControls = true),
                    icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                  ),
                DoomPauseButton(onPressed: _runtime.togglePause),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<DoomHudSnapshot>(
              valueListenable: _runtime.hud,
              builder: (context, hud, _) =>
                  DoomStatusBar(hud: hud, synthetic: widget.synthetic),
            ),
          ),
          ValueListenableBuilder<DoomHudSnapshot>(
            valueListenable: _runtime.hud,
            builder: (context, hud, _) => _buildOverlay(hud),
          ),
        ],
      ),
    ),
  );

  Widget _buildOverlay(DoomHudSnapshot hud) {
    if (hud.levelComplete) {
      final exit = _runtime.levelExit;
      return DoomIntermissionOverlay(
        key: const Key('completion-overlay'),
        hud: hud,
        onRestart: _restartLevel,
        nextMap: exit == null
            ? null
            : core.DoomEpisode.nextMap(
                widget.level.map.name,
                secret: exit.secret,
              ),
        episodeComplete: widget.level.map.name == 'E1M8',
        onContinue: _continueEpisode,
        advancing: _advancing,
        errorMessage: widget.selectionErrorMessage,
      );
    }
    if (hud.health <= 0) {
      return DoomModalOverlay(
        key: const Key('death-overlay'),
        title: 'YOU DIED',
        subtitle: 'Press fire or use to restart the level',
        onPressed: _restartLevel,
        buttonLabel: 'RESTART LEVEL',
      );
    }
    if (hud.paused) {
      return DoomPauseOverlay(
        key: const Key('pause-overlay'),
        onResume: _runtime.togglePause,
        onLoadIwad: widget.onLoadIwad,
        errorMessage: widget.selectionErrorMessage,
      );
    }
    return const SizedBox.shrink();
  }
}

/// This widget has stable identity for the entire level lifetime. Inherited
/// dependencies of custom surfaces still rebuild normally within this subtree.
final class _DoomInputSurface extends StatelessWidget {
  const _DoomInputSurface({
    required this.runtime,
    required this.focusNode,
    this.surfaceBuilder,
  });
  final DoomRuntimeView runtime;
  final FocusNode focusNode;
  final DoomGameSurfaceBuilder? surfaceBuilder;

  @override
  Widget build(BuildContext context) => Listener(
    key: const Key('game-input-surface'),
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) {
      focusNode.requestFocus();
      if ((event.buttons & kPrimaryMouseButton) != 0) {
        runtime.setPointerAttack(true);
      }
    },
    onPointerMove: (event) {
      if ((event.buttons & kPrimaryMouseButton) != 0) {
        runtime.addPointerYaw(event.delta.dx);
      }
    },
    onPointerUp: (_) => runtime.setPointerAttack(false),
    onPointerCancel: (_) => runtime.setPointerAttack(false),
    child: surfaceBuilder != null
        ? Focus(
            key: const Key('doom-game-focus'),
            focusNode: focusNode,
            autofocus: true,
            child: surfaceBuilder!(context, runtime),
          )
        : _gameWidget(),
  );

  Widget _gameWidget() {
    final game = runtime;
    if (game is! DoomRuntimeGame) return const DoomRuntimeConfigurationError();
    return GameWidget<DoomRuntimeGame>(
      key: const Key('doom-game-widget'),
      game: game,
      focusNode: focusNode,
      autofocus: true,
      backgroundBuilder: (_) => const ColoredBox(color: Colors.black),
      loadingBuilder: (_) => const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      ),
      errorBuilder: (_, error) => DoomRuntimeConfigurationError(
        message: 'Could not start the renderer: $error',
      ),
    );
  }
}
