import 'dart:async';

import 'package:doom_core/doom_core.dart' as core;
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../game/frame_probe.dart';
import '../adapter/adapter.dart';
import '../game/audio_backend_factory.dart';
import '../game/audio_session.dart';
import '../game/browser_input.dart';
import '../game/weapon_scroll.dart';
import '../game/sound_playback.dart';
import '../game/doom_automap.dart';
import '../game/doom_hud.dart';
import '../game/level_preparer.dart';
import 'doom_automap.dart';
import 'doom_game_overlays.dart';
import 'doom_status_bar.dart';
import 'doom_intermission.dart';
import 'doom_touch_controls.dart';

/// Creates a runtime owned by the level host. Custom runtimes can implement
/// [DoomRuntimeLifecycle] to release their resources when the host unmounts.
/// Used when a level is mounted or replaced. Changing the factory alone does
/// not reset gameplay; use a new host key to explicitly replace a live runtime.
typedef DoomRuntimeFactory = DoomRuntimeView Function(PreparedDoomLevel level);
typedef DoomGameSurfaceBuilder =
    Widget Function(BuildContext context, DoomRuntimeView runtime);

/// Production runtime boundary. Direct [DoomRuntimeGame] construction remains
/// silent by default for tests and non-UI tools.
DoomRuntimeView createProductionDoomRuntime(
  PreparedDoomLevel level, {
  AudioBackend? audioBackend,
}) {
  final backend = audioBackend ?? createDefaultAudioBackend();
  try {
    return DoomRuntimeGame(level, audioBackend: backend);
  } catch (_) {
    unawaited(
      Future<void>.sync(backend.dispose).catchError((
        Object error,
        StackTrace stack,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            context: ErrorDescription(
              'releasing audio after runtime creation failed',
            ),
          ),
        );
      }),
    );
    rethrow;
  }
}

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
    this.touchControlsEnabled = false,
    this.onTouchDetected,
    this.onTouchControlsChanged,
    this.audioSession,
    this.onRetry,
    this.browserInput,
    this.mouseSensitivity = 1,
    this.onSensitivityChanged,
  });

  final PreparedDoomLevel level;
  final bool synthetic;
  final String? setupMessage;
  final String? selectionErrorMessage;
  final VoidCallback? onLoadIwad;
  final Future<void> Function(core.LevelExit) onContinue;
  final DoomRuntimeFactory? runtimeFactory;
  final DoomGameSurfaceBuilder? gameSurfaceBuilder;
  final bool touchControlsEnabled;
  final VoidCallback? onTouchDetected;
  final ValueChanged<bool>? onTouchControlsChanged;
  final DoomAudioSession? audioSession;
  final VoidCallback? onRetry;
  final DoomBrowserInput? browserInput;
  final double mouseSensitivity;
  final ValueChanged<double>? onSensitivityChanged;

  @override
  State<DoomGameView> createState() => _DoomGameViewState();
}

final class _DoomGameViewState extends State<DoomGameView>
    with WidgetsBindingObserver {
  late DoomRuntimeView _runtime;
  late final FocusNode _gameFocusNode;
  late Widget _surface;
  bool _showControls = true;
  bool _hintsManuallyHidden = false;
  Timer? _hintTimer;
  DoomBrowserInputLease? _browserLease;
  final _weaponScroll = DoomWeaponScroll();
  bool get _webInput => widget.browserInput?.available == true;
  bool get _captured => widget.browserInput?.captured == true;
  bool _advancing = false;
  DoomFrameProbe? _frameProbe;
  int _touchResetGeneration = 0;
  int? _mousePointer;
  late bool _hudInputBlocked;
  late bool _mapOpen;

  @override
  void initState() {
    super.initState();
    _gameFocusNode = FocusNode(debugLabel: 'Doom game input')
      ..addListener(_handleFocusChange);
    WidgetsBinding.instance.addObserver(this);
    _frameProbe = DoomFrameProbe.startIfEnabled();
    _createRuntime();
    widget.browserInput?.addListener(_handleBrowserState);
  }

  @override
  void didUpdateWidget(covariant DoomGameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.browserInput, widget.browserInput)) {
      oldWidget.browserInput?.removeListener(_handleBrowserState);
      widget.browserInput?.addListener(_handleBrowserState);
      _connectBrowser();
    }
    if (!oldWidget.touchControlsEnabled && widget.touchControlsEnabled) {
      _browserLease?.release();
      _clearDeviceInput(rebuild: false);
    }
    if (!identical(oldWidget.level, widget.level) ||
        !identical(oldWidget.audioSession, widget.audioSession)) {
      _detachInputListeners();
      _clearDeviceInput(rebuild: false);
      if (_runtime case final DoomRuntimeLifecycle owned) owned.dispose();
      _createRuntime();
      _showControls = true;
      _advancing = false;
    } else if (!identical(
          oldWidget.gameSurfaceBuilder,
          widget.gameSurfaceBuilder,
        ) ||
        !identical(oldWidget.onTouchDetected, widget.onTouchDetected)) {
      _createSurface();
    }
  }

  void _createRuntime() {
    _runtime = widget.runtimeFactory != null
        ? widget.runtimeFactory!(widget.level)
        : createProductionDoomRuntime(
            widget.level,
            audioBackend: widget.audioSession?.acquireLevel(),
          );
    _hudInputBlocked = _blocksInput(_runtime.hud.value);
    _mapOpen = _runtime.automap.value.isOpen;
    _runtime.hud.addListener(_handleHudInputState);
    _runtime.automap.addListener(_handleMapInputState);
    _connectBrowser();
    _createSurface();
  }

  void _createSurface() {
    _surface = _DoomInputSurface(
      runtime: _runtime,
      focusNode: _gameFocusNode,
      surfaceBuilder: widget.gameSurfaceBuilder,
      onRetry: widget.onRetry,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
    );
  }

  @override
  void dispose() {
    _frameProbe?.dispose();
    _hintTimer?.cancel();
    widget.browserInput?.removeListener(_handleBrowserState);
    WidgetsBinding.instance.removeObserver(this);
    _detachInputListeners();
    _clearDeviceInput(rebuild: false);
    _gameFocusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    if (_runtime case final DoomRuntimeLifecycle owned) owned.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_runtime case final DoomRuntimeAudio audio) {
      audio.setAudioFocused(state == AppLifecycleState.resumed);
    }
    if (state != AppLifecycleState.resumed) {
      if (_webInput) _pause();
      _clearDeviceInput();
    }
  }

  void _handleFocusChange() {
    if (!_gameFocusNode.hasFocus) {
      _clearDeviceInput();
    }
  }

  static bool _blocksInput(DoomHudSnapshot hud) =>
      hud.paused || hud.levelComplete || hud.health <= 0;

  void _detachInputListeners() {
    _browserLease?.dispose();
    _browserLease = null;
    _hintTimer?.cancel();
    if (_runtime case final DoomRuntimeWebControls controls) {
      controls.onPauseRequested = null;
      controls.movementRevision.removeListener(_handleMovement);
    }
    _runtime.hud.removeListener(_handleHudInputState);
    _runtime.automap.removeListener(_handleMapInputState);
  }

  void _handleHudInputState() {
    final blocked = _blocksInput(_runtime.hud.value);
    if (blocked == _hudInputBlocked) return;
    _hudInputBlocked = blocked;
    if (blocked) {
      _hintTimer?.cancel();
      _browserLease?.release();
      _clearDeviceInput(
        rebuild: false,
        preserveAudio: !_runtime.hud.value.paused,
      );
    } else {
      _gameFocusNode.requestFocus();
      _armHints();
    }
    if (mounted) setState(() {});
  }

  void _handleMapInputState() {
    final open = _runtime.automap.value.isOpen;
    if (open == _mapOpen) return;
    if (mounted) setState(() => _mapOpen = open);
  }

  void _clearDeviceInput({bool rebuild = true, bool preserveAudio = false}) {
    _mousePointer = null;
    _weaponScroll.clear();
    if (preserveAudio && _runtime is DoomRuntimeAudio) {
      (_runtime as DoomRuntimeAudio).clearInputPreservingAudio();
    } else {
      _runtime.clearInput();
    }
    _touchResetGeneration++;
    if (rebuild && mounted) setState(() {});
  }

  void _setTouchControls(bool enabled) {
    _clearDeviceInput();
    widget.onTouchControlsChanged?.call(enabled);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _gameFocusNode.requestFocus();
    if (event.kind == PointerDeviceKind.touch) {
      if (_captured) _pause();
      widget.onTouchDetected?.call();
    } else if (event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryMouseButton) != 0 &&
        _mousePointer == null) {
      if (_webInput) {
        if (!_hudInputBlocked) _browserLease?.capture();
        return;
      }
      _mousePointer = event.pointer;
      _runtime.setPointerAttack(true);
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_webInput) return;
    if (event.kind == PointerDeviceKind.mouse &&
        event.pointer == _mousePointer &&
        (event.buttons & kPrimaryMouseButton) != 0) {
      _runtime.addPointerYaw(event.delta.dx);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _mousePointer) return;
    _mousePointer = null;
    _runtime.setPointerAttack(false);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _mousePointer) return;
    _mousePointer = null;
    _runtime.setPointerAttack(false, cancelled: true);
  }

  void _connectBrowser() {
    _browserLease?.dispose();
    _browserLease = null;
    if (_runtime case final DoomRuntimeWebControls controls) {
      controls.movementRevision.removeListener(_handleMovement);
      controls.onPauseRequested = _webInput ? _pause : null;
      if (_webInput) controls.movementRevision.addListener(_handleMovement);
    }
    if (!_webInput) return;
    _browserLease = widget.browserInput!.acquire(
      onTurn: (dx) {
        if (!_hudInputBlocked) {
          _runtime.addPointerYaw(dx * widget.mouseSensitivity);
        }
      },
      onAttack: (down) {
        if (!down || !_hudInputBlocked) _runtime.setPointerAttack(down);
      },
      onPause: _pause,
    );
  }

  void _handleBrowserState() {
    if (mounted) setState(() {});
  }

  void _pause() {
    _browserLease?.release();
    final hud = _runtime.hud.value;
    if (hud.health <= 0 || hud.levelComplete) return;
    if (_webInput && _runtime is DoomRuntimeWebControls) {
      (_runtime as DoomRuntimeWebControls).setPaused(true);
    } else if (!hud.paused) {
      _runtime.togglePause();
    }
  }

  void _resume() {
    if (_webInput && _runtime is DoomRuntimeWebControls) {
      (_runtime as DoomRuntimeWebControls).setPaused(false);
      if (!widget.touchControlsEnabled) _browserLease?.capture();
    } else {
      _runtime.togglePause();
    }
    _gameFocusNode.requestFocus();
  }

  void _handleMovement() {
    if (_hintsManuallyHidden || _hudInputBlocked) return;
    if (_showControls && mounted) setState(() => _showControls = false);
    _armHints();
  }

  void _armHints() {
    _hintTimer?.cancel();
    if (!_webInput || _hintsManuallyHidden || _showControls) return;
    _hintTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && !_hudInputBlocked) setState(() => _showControls = true);
    });
  }

  void _handleScroll(PointerSignalEvent event) {
    if (!_webInput || _hudInputBlocked || event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      _cycleScroll((event as PointerScrollEvent).scrollDelta.dy);
    });
  }

  void _cycleScroll(double dy) {
    if (!_webInput || _hudInputBlocked || _advancing) return;
    if (_runtime case final DoomRuntimeWebControls controls) {
      final steps = _weaponScroll.add(dy);
      for (var i = 0; i < steps.abs(); i++) {
        controls.cycleWeapon(steps.sign);
      }
    }
  }

  void _restartLevel() {
    _clearDeviceInput();
    _runtime.restartLevel();
    _gameFocusNode.requestFocus();
  }

  Future<void> _continueEpisode() async {
    final runtime = _runtime;
    final core.LevelExit? exit = runtime.levelExit;
    if (_advancing || exit == null) return;
    setState(() => _advancing = true);
    _clearDeviceInput();
    try {
      await widget.onContinue(exit);
    } finally {
      if (mounted && identical(_runtime, runtime)) {
        setState(() => _advancing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < 1100;
      return ColoredBox(
        color: Colors.black,
        child: Listener(
          key: const Key('web-input-root'),
          onPointerSignal: _handleScroll,
          onPointerPanZoomStart: (_) => _weaponScroll.clear(),
          onPointerPanZoomUpdate: (event) {
            if (event.panDelta.dy.abs() > event.panDelta.dx.abs()) {
              _cycleScroll(-event.panDelta.dy);
            }
          },
          onPointerPanZoomEnd: (_) => _weaponScroll.clear(),
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
              IgnorePointer(
                ignoring: _captured,
                child: SafeArea(
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (widget.touchControlsEnabled)
                              Positioned.fill(
                                top: 44,
                                child: _buildTouchControls(),
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
                            if (!widget.touchControlsEnabled)
                              Positioned(
                                top: narrow && _showControls ? 44 : 10,
                                right: 10,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_showControls)
                                      DoomControlsHint(
                                        narrow: narrow,
                                        browserControls: _webInput,
                                        onHide: () => setState(() {
                                          _hintsManuallyHidden = true;
                                          _showControls = false;
                                          _hintTimer?.cancel();
                                        }),
                                      )
                                    else
                                      IconButton(
                                        key: const Key('show-controls'),
                                        tooltip: 'Show controls',
                                        onPressed: () => setState(() {
                                          _hintsManuallyHidden = false;
                                          _showControls = true;
                                        }),
                                        icon: const Icon(
                                          Icons.keyboard_alt_outlined,
                                          size: 18,
                                        ),
                                      ),
                                    DoomPauseButton(onPressed: _pause),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      ValueListenableBuilder<DoomHudSnapshot>(
                        valueListenable: _runtime.hud,
                        builder: (context, hud, _) => DoomStatusBar(
                          hud: hud,
                          synthetic: widget.synthetic,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_webInput &&
                  !_captured &&
                  !_hudInputBlocked &&
                  !widget.touchControlsEnabled)
                Positioned(
                  left: 10,
                  bottom: 84,
                  right: 10,
                  child: IgnorePointer(
                    child: Text(
                      widget.browserInput?.errorMessage ??
                          'Click the game to capture the mouse · Esc pauses',
                      key: const Key('mouse-capture-hint'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        backgroundColor: Colors.black87,
                        fontSize: 12,
                      ),
                    ),
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
    },
  );

  Widget _buildTouchControls() {
    final runtime = _runtime;
    return DoomTouchControls(
      enabled: !_hudInputBlocked && !_advancing,
      resetGeneration: _touchResetGeneration,
      mapOpen: _mapOpen,
      onMove: (pointer, forward, side) {
        // Cancellation sends zero axes; it must not steal focus back.
        if (forward != 0 || side != 0) _gameFocusNode.requestFocus();
        runtime.setTouchMovement(pointer, forward: forward, side: side);
      },
      onLook: runtime.addPointerYaw,
      onControlDown: (pointer, control) {
        _gameFocusNode.requestFocus();
        runtime.pressTouchControl(pointer, control);
      },
      onPointerUp: (pointer, cancelled) =>
          runtime.releaseTouchPointer(pointer, cancelled: cancelled),
      onUse: runtime.triggerUse,
      onSelectWeapon: runtime.selectWeapon,
      onToggleMap: runtime.toggleAutomap,
      onZoomMap: (inwards) => runtime.zoomAutomap(inwards: inwards),
      onPause: _pause,
    );
  }

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
        touchControlsEnabled: widget.touchControlsEnabled,
        onTouchControlsChanged: _setTouchControls,
        onResume: _resume,
        browserControls: _webInput,
        mouseSensitivity: widget.mouseSensitivity,
        onSensitivityChanged: widget.onSensitivityChanged,
        onLoadIwad: widget.onLoadIwad,
        errorMessage: widget.selectionErrorMessage,
        audioSession: widget.audioSession,
      );
    }
    return const SizedBox.shrink();
  }
}

/// Stable across gameplay publications. A host rebuild may update an injected
/// surface builder without replacing the runtime. Inherited dependencies of
/// custom surfaces still rebuild normally within this subtree.
final class _DoomInputSurface extends StatelessWidget {
  const _DoomInputSurface({
    required this.runtime,
    required this.focusNode,
    this.surfaceBuilder,
    this.onRetry,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
  });
  final DoomRuntimeView runtime;
  final FocusNode focusNode;
  final DoomGameSurfaceBuilder? surfaceBuilder;
  final VoidCallback? onRetry;
  final void Function(PointerDownEvent) onPointerDown;
  final void Function(PointerMoveEvent) onPointerMove;
  final void Function(PointerUpEvent) onPointerUp;
  final void Function(PointerCancelEvent) onPointerCancel;

  @override
  Widget build(BuildContext context) => Listener(
    key: const Key('game-input-surface'),
    behavior: HitTestBehavior.opaque,
    onPointerDown: onPointerDown,
    onPointerMove: onPointerMove,
    onPointerUp: onPointerUp,
    onPointerCancel: onPointerCancel,
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
        message:
            'Could not load the game graphics. Check your connection and try again.',
        onRetry: onRetry,
      ),
    );
  }
}
