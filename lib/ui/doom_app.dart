import 'dart:async';

import 'package:doom_core/doom_core.dart' as core;
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../adapter/adapter.dart';
import '../game/doom_app_controller.dart';
import '../game/audio_backend_factory.dart';
import '../game/browser_wad_picker.dart';
import '../game/doom_automap.dart';
import '../game/doom_hud.dart';
import '../game/level_preparer.dart';
import 'doom_automap.dart';
import 'doom_touch_controls.dart';

typedef DoomRuntimeFactory = DoomRuntimeView Function(PreparedDoomLevel level);
typedef DoomGameSurfaceBuilder =
    Widget Function(BuildContext context, DoomRuntimeView runtime);
typedef DoomWadPicker = Future<BrowserWadSelection?> Function();

const bool _frameProbeEnabled = bool.fromEnvironment('DOOMPELLER_FRAME_PROBE');

/// Production runtime boundary. Direct [DoomRuntimeGame] construction remains
/// silent by default for tests and non-UI tools.
DoomRuntimeView createProductionDoomRuntime(PreparedDoomLevel level) =>
    DoomRuntimeGame(level, audioBackend: createDefaultAudioBackend());

final class DoomApp extends StatefulWidget {
  const DoomApp({
    super.key,
    this.controller,
    this.autoStart = true,
    this.runtimeFactory,
    this.gameSurfaceBuilder,
    this.wadPicker,
  });

  final DoomAppController? controller;
  final bool autoStart;
  final DoomRuntimeFactory? runtimeFactory;
  final DoomGameSurfaceBuilder? gameSurfaceBuilder;
  final DoomWadPicker? wadPicker;

  @override
  State<DoomApp> createState() => _DoomAppState();
}

final class _DoomAppState extends State<DoomApp> {
  late final DoomAppController _controller =
      widget.controller ?? DoomAppController();
  late final bool _ownsController = widget.controller == null;
  bool _touchDetected = false;
  bool? _touchControlsOverride;

  void _detectTouch() {
    if (!_touchDetected) setState(() => _touchDetected = true);
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) _controller.start();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Doompeller',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.black,
      fontFamily: 'monospace',
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFC8B45A),
        surface: Color(0xFF181818),
      ),
    ),
    home: ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _DoomAppBody(
        controller: _controller,
        runtimeFactory: widget.runtimeFactory,
        gameSurfaceBuilder: widget.gameSurfaceBuilder,
        touchControlsEnabled: _touchControlsOverride ?? _touchDetected,
        onTouchDetected: _detectTouch,
        onTouchControlsChanged: (enabled) =>
            setState(() => _touchControlsOverride = enabled),
        wadPicker:
            widget.wadPicker ??
            (browserWadPickerAvailable ? pickBrowserWad : null),
      ),
    ),
  );
}

final class _DoomAppBody extends StatelessWidget {
  const _DoomAppBody({
    required this.controller,
    required this.touchControlsEnabled,
    required this.onTouchDetected,
    required this.onTouchControlsChanged,
    this.runtimeFactory,
    this.gameSurfaceBuilder,
    this.wadPicker,
  });

  final DoomAppController controller;
  final bool touchControlsEnabled;
  final VoidCallback onTouchDetected;
  final ValueChanged<bool> onTouchControlsChanged;
  final DoomRuntimeFactory? runtimeFactory;
  final DoomGameSurfaceBuilder? gameSurfaceBuilder;
  final DoomWadPicker? wadPicker;

  Future<void> _pickBrowserIwad() async {
    try {
      final selection = await wadPicker?.call();
      if (selection == null) return;
      await controller.useSelectedIwad(
        selection.bytes,
        sourceLabel: selection.name,
      );
    } on BrowserWadPickerFailure catch (error) {
      controller.reportSelectedIwadFailure(error.message);
    } on Object {
      controller.reportSelectedIwadFailure(
        'The browser could not open the selected IWAD.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Scaffold(
      backgroundColor: Colors.black,
      body: switch (state.phase) {
        DoomAppPhase.loading => const _LoadingView(),
        DoomAppPhase.failure => _FailureView(
          message: state.errorMessage ?? 'Unknown level load failure.',
          onFallback: controller.useFixtureFallback,
        ),
        DoomAppPhase.fixtureReady ||
        DoomAppPhase.developerIwadReady => _DoomReadyView(
          key: ValueKey<PreparedDoomLevel>(state.level!),
          level: state.level!,
          synthetic: state.isFixture,
          setupMessage: state.setupMessage,
          selectionErrorMessage: state.errorMessage,
          onLoadIwad: wadPicker == null ? null : _pickBrowserIwad,
          onContinue: (exit) => controller.advanceLevel(state.level!, exit),
          runtimeFactory: runtimeFactory,
          gameSurfaceBuilder: gameSurfaceBuilder,
          touchControlsEnabled: touchControlsEnabled,
          onTouchDetected: onTouchDetected,
          onTouchControlsChanged: onTouchControlsChanged,
        ),
      },
    );
  }
}

final class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      key: Key('loading-view'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox.square(dimension: 28, child: CircularProgressIndicator()),
        SizedBox(height: 16),
        Text('LOADING LEVEL'),
      ],
    ),
  );
}

final class _FailureView extends StatelessWidget {
  const _FailureView({required this.message, required this.onFallback});

  final String message;
  final VoidCallback onFallback;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            key: const Key('failure-view'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'IWAD LOAD FAILED',
                style: TextStyle(
                  color: Color(0xFFFF6B5F),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 18),
              FilledButton.tonal(
                key: const Key('fixture-fallback'),
                onPressed: onFallback,
                child: const Text('RUN SYNTHETIC TEST MAP'),
              ),
              const SizedBox(height: 10),
              const Text(
                'No content is substituted until you choose this fallback.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class _DoomReadyView extends StatefulWidget {
  const _DoomReadyView({
    super.key,
    required this.level,
    required this.synthetic,
    required this.setupMessage,
    required this.selectionErrorMessage,
    required this.onLoadIwad,
    required this.onContinue,
    required this.touchControlsEnabled,
    required this.onTouchDetected,
    required this.onTouchControlsChanged,
    this.runtimeFactory,
    this.gameSurfaceBuilder,
  });

  final PreparedDoomLevel level;
  final bool synthetic;
  final String? setupMessage;
  final String? selectionErrorMessage;
  final VoidCallback? onLoadIwad;
  final Future<void> Function(core.LevelExit) onContinue;
  final bool touchControlsEnabled;
  final VoidCallback onTouchDetected;
  final ValueChanged<bool> onTouchControlsChanged;
  final DoomRuntimeFactory? runtimeFactory;
  final DoomGameSurfaceBuilder? gameSurfaceBuilder;

  @override
  State<_DoomReadyView> createState() => _DoomReadyViewState();
}

final class _DoomReadyViewState extends State<_DoomReadyView>
    with WidgetsBindingObserver {
  late final DoomRuntimeView _runtime;
  late final FocusNode _gameFocusNode;
  String? _configurationError;
  bool _showControls = true;
  bool _advancing = false;
  int _touchResetGeneration = 0;
  int? _mousePointer;
  late bool _hudInputBlocked;
  FrameHistogram? _frameProbe;
  Timer? _frameProbeWarmup;
  Timer? _frameProbeReporter;

  @override
  void initState() {
    super.initState();
    _runtime = (widget.runtimeFactory ?? createProductionDoomRuntime)(
      widget.level,
    );
    _gameFocusNode = FocusNode(debugLabel: 'Doom game input')
      ..addListener(_handleFocusChange);
    _hudInputBlocked = _blocksInput(_runtime.hud.value);
    _runtime.hud.addListener(_handleHudInputState);
    WidgetsBinding.instance.addObserver(this);
    if (_frameProbeEnabled) {
      _frameProbe = FrameHistogram();
      SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
      _frameProbeWarmup = Timer(const Duration(seconds: 5), () {
        _frameProbe?.clear();
        debugPrint('doompeller-web-frame: warmup complete');
      });
      _frameProbeReporter = Timer.periodic(const Duration(seconds: 2), (_) {
        final summary = _frameProbe?.summarize();
        if (summary == null || summary.count == 0) return;
        debugPrint(
          'doompeller-web-frame: n=${summary.count} '
          'p50=${summary.p50Millis.toStringAsFixed(3)}ms '
          'p95=${summary.p95Millis.toStringAsFixed(3)}ms '
          'p99=${summary.p99Millis.toStringAsFixed(3)}ms '
          'build95=${(summary.p95BuildMicros / 1000).toStringAsFixed(3)}ms '
          'raster95=${(summary.p95RasterMicros / 1000).toStringAsFixed(3)}ms '
          'misses=${summary.deadlineMisses}',
        );
      });
    }
    if (widget.runtimeFactory != null && widget.gameSurfaceBuilder == null) {
      _configurationError =
          'A custom Doom runtime requires a custom game surface builder.';
    }
  }

  @override
  void dispose() {
    if (_frameProbeEnabled) {
      SchedulerBinding.instance.removeTimingsCallback(_recordFrameTimings);
      _frameProbeWarmup?.cancel();
      _frameProbeReporter?.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    _runtime.hud.removeListener(_handleHudInputState);
    _clearDeviceInput(rebuild: false);
    _gameFocusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    super.dispose();
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    _frameProbe?.addTimings(timings);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
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

  void _handleHudInputState() {
    final bool blocked = _blocksInput(_runtime.hud.value);
    if (blocked && !_hudInputBlocked) _clearDeviceInput();
    _hudInputBlocked = blocked;
  }

  void _clearDeviceInput({bool rebuild = true}) {
    _mousePointer = null;
    _runtime.clearInput();
    _touchResetGeneration++;
    if (rebuild && mounted) setState(() {});
  }

  void _setTouchControls(bool enabled) {
    _clearDeviceInput();
    widget.onTouchControlsChanged(enabled);
  }

  void _restartLevel() {
    _clearDeviceInput();
    _runtime.restartLevel();
    _gameFocusNode.requestFocus();
  }

  Future<void> _continueEpisode() async {
    final core.LevelExit? exit = _runtime.levelExit;
    if (_advancing || exit == null) return;
    setState(() => _advancing = true);
    _clearDeviceInput();
    try {
      await widget.onContinue(exit);
    } finally {
      if (mounted) setState(() => _advancing = false);
    }
  }

  Widget _buildGameSurface(BuildContext context) {
    final custom = widget.gameSurfaceBuilder;
    if (custom != null) {
      return Focus(
        key: const Key('doom-game-focus'),
        focusNode: _gameFocusNode,
        autofocus: true,
        child: custom(context, _runtime),
      );
    }
    final runtime = _runtime;
    if (runtime is! DoomRuntimeGame) {
      return const _RuntimeConfigurationError();
    }
    return GameWidget<DoomRuntimeGame>(
      key: const Key('doom-game-widget'),
      game: runtime,
      focusNode: _gameFocusNode,
      autofocus: true,
      backgroundBuilder: (_) => const ColoredBox(color: Colors.black),
      loadingBuilder: (_) => const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_configurationError != null) {
      return _RuntimeConfigurationError(message: _configurationError!);
    }
    return ValueListenableBuilder<DoomHudSnapshot>(
      valueListenable: _runtime.hud,
      builder: (context, hud, _) => ValueListenableBuilder<DoomAutomapSnapshot>(
        valueListenable: _runtime.automap,
        builder: (context, automap, _) => LayoutBuilder(
          builder: (context, constraints) {
            final bool narrow = constraints.maxWidth < 1100;
            return ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Listener(
                    key: const Key('game-input-surface'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) {
                      _gameFocusNode.requestFocus();
                      if (event.kind == PointerDeviceKind.touch) {
                        widget.onTouchDetected();
                      } else if (event.kind == PointerDeviceKind.mouse &&
                          (event.buttons & kPrimaryMouseButton) != 0 &&
                          _mousePointer == null) {
                        _mousePointer = event.pointer;
                        _runtime.setPointerAttack(true);
                      }
                    },
                    onPointerMove: (event) {
                      if (event.kind == PointerDeviceKind.mouse &&
                          event.pointer == _mousePointer &&
                          (event.buttons & kPrimaryMouseButton) != 0) {
                        _runtime.addPointerYaw(event.delta.dx);
                      }
                    },
                    onPointerUp: (event) {
                      if (event.pointer != _mousePointer) return;
                      _mousePointer = null;
                      _runtime.setPointerAttack(false);
                    },
                    onPointerCancel: (event) {
                      if (event.pointer != _mousePointer) return;
                      _mousePointer = null;
                      _runtime.setPointerAttack(false, cancelled: true);
                    },
                    child: _buildGameSurface(context),
                  ),
                  if (automap.isOpen)
                    DoomAutomapOverlay(
                      map: widget.level.map,
                      snapshot: automap,
                    ),
                  SafeArea(
                    child: Column(
                      children: <Widget>[
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              if (widget.touchControlsEnabled)
                                Positioned.fill(
                                  top: 44,
                                  child: DoomTouchControls(
                                    enabled: !_blocksInput(hud) && !_advancing,
                                    resetGeneration: _touchResetGeneration,
                                    mapOpen: automap.isOpen,
                                    onMove: (pointer, forward, side) {
                                      // Zero axes also arrive while cancelling
                                      // captures after blur/dispose. Do not
                                      // steal focus back during that cleanup.
                                      if (forward != 0 || side != 0) {
                                        _gameFocusNode.requestFocus();
                                      }
                                      _runtime.setTouchMovement(
                                        pointer,
                                        forward: forward,
                                        side: side,
                                      );
                                    },
                                    onLook: _runtime.addPointerYaw,
                                    onControlDown: (pointer, control) {
                                      _gameFocusNode.requestFocus();
                                      _runtime.pressTouchControl(
                                        pointer,
                                        control,
                                      );
                                    },
                                    onPointerUp: (pointer, cancelled) =>
                                        _runtime.releaseTouchPointer(
                                          pointer,
                                          cancelled: cancelled,
                                        ),
                                    onUse: _runtime.triggerUse,
                                    onSelectWeapon: _runtime.selectWeapon,
                                    onToggleMap: _runtime.toggleAutomap,
                                    onZoomMap: (inwards) =>
                                        _runtime.zoomAutomap(inwards: inwards),
                                    onPause: _runtime.togglePause,
                                  ),
                                ),
                              Positioned(
                                top: 10,
                                left: 10,
                                child: _ContentBadge(
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
                                    children: <Widget>[
                                      if (_showControls)
                                        _ControlsHint(
                                          narrow: narrow,
                                          onHide: () => setState(
                                            () => _showControls = false,
                                          ),
                                        )
                                      else
                                        IconButton(
                                          key: const Key('show-controls'),
                                          tooltip: 'Show controls',
                                          onPressed: () => setState(
                                            () => _showControls = true,
                                          ),
                                          icon: const Icon(
                                            Icons.keyboard_alt_outlined,
                                            size: 18,
                                          ),
                                        ),
                                      _PauseButton(
                                        onPressed: _runtime.togglePause,
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        DoomStatusBar(hud: hud, synthetic: widget.synthetic),
                      ],
                    ),
                  ),
                  if (hud.paused && hud.health > 0)
                    _PauseOverlay(
                      key: const Key('pause-overlay'),
                      onResume: _runtime.togglePause,
                      onLoadIwad: widget.onLoadIwad,
                      errorMessage: widget.selectionErrorMessage,
                      touchControlsEnabled: widget.touchControlsEnabled,
                      onTouchControlsChanged: _setTouchControls,
                    ),
                  if (hud.levelComplete)
                    _IntermissionOverlay(
                      key: const Key('completion-overlay'),
                      hud: hud,
                      onRestart: _restartLevel,
                      nextMap: _runtime.levelExit == null
                          ? null
                          : core.DoomEpisode.nextMap(
                              widget.level.map.name,
                              secret: _runtime.levelExit!.secret,
                            ),
                      episodeComplete: widget.level.map.name == 'E1M8',
                      onContinue: _continueEpisode,
                      advancing: _advancing,
                      errorMessage: widget.selectionErrorMessage,
                    ),
                  if (hud.health <= 0 && !hud.levelComplete)
                    _ModalOverlay(
                      key: const Key('death-overlay'),
                      title: 'YOU DIED',
                      subtitle: 'Press fire or use to restart the level',
                      onPressed: _restartLevel,
                      buttonLabel: 'RESTART LEVEL',
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _RuntimeConfigurationError extends StatelessWidget {
  const _RuntimeConfigurationError({
    this.message = 'The configured game runtime cannot be rendered.',
  });

  final String message;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const Key('runtime-configuration-error'),
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    ),
  );
}

final class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('game-pause-button'),
    tooltip: 'Pause game',
    constraints: const BoxConstraints.tightFor(width: 36, height: 34),
    padding: EdgeInsets.zero,
    color: Colors.white70,
    onPressed: onPressed,
    icon: const Icon(Icons.pause, size: 18, semanticLabel: 'Pause game'),
  );
}

final class _ContentBadge extends StatelessWidget {
  const _ContentBadge({
    required this.synthetic,
    required this.mapName,
    this.setupMessage,
  });

  final bool synthetic;
  final String mapName;
  final String? setupMessage;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('content-badge'),
    constraints: const BoxConstraints(maxWidth: 430),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.78),
      border: Border.all(
        color: synthetic ? const Color(0xFFE0B64D) : const Color(0xFF61B879),
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          synthetic ? 'SYNTHETIC TEST MAP' : 'DEVELOPER IWAD · $mapName',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
        ),
        if (synthetic && setupMessage != null)
          Text(
            setupMessage!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
      ],
    ),
  );
}

final class _PauseOverlay extends StatelessWidget {
  const _PauseOverlay({
    super.key,
    required this.onResume,
    required this.touchControlsEnabled,
    required this.onTouchControlsChanged,
    this.onLoadIwad,
    this.errorMessage,
  });

  final VoidCallback onResume;
  final bool touchControlsEnabled;
  final ValueChanged<bool> onTouchControlsChanged;
  final VoidCallback? onLoadIwad;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.78),
    child: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  'PAUSED',
                  style: TextStyle(
                    color: Color(0xFFC8B45A),
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Press Esc to resume',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  key: const Key('overlay-action'),
                  onPressed: onResume,
                  child: const Text('RESUME'),
                ),
                const SizedBox(height: 8),
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile.adaptive(
                    key: const Key('pause-touch-controls'),
                    title: const Text('TOUCH CONTROLS'),
                    value: touchControlsEnabled,
                    onChanged: onTouchControlsChanged,
                  ),
                ),
                if (onLoadIwad != null) ...<Widget>[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    key: const Key('pause-load-iwad'),
                    onPressed: onLoadIwad,
                    child: const Text('SELECT LOCAL IWAD'),
                  ),
                ],
                if (errorMessage != null) ...<Widget>[
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(
                      errorMessage!,
                      key: const Key('pause-iwad-error'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFF6B5F)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final class _ControlsHint extends StatelessWidget {
  const _ControlsHint({required this.narrow, required this.onHide});

  final bool narrow;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('controls-hint'),
    padding: const EdgeInsets.only(left: 9),
    color: Colors.black.withValues(alpha: 0.72),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          narrow
              ? 'WASD · Shift run · ←→ · Enter fire · E use'
              : 'W/S move · A/D strafe · Shift run · ←/→ turn · Enter/Ctrl/click fire · Space/E use · 1–6 weapon · Esc pause',
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
        IconButton(
          key: const Key('hide-controls'),
          tooltip: 'Hide controls',
          constraints: const BoxConstraints.tightFor(width: 32, height: 30),
          padding: EdgeInsets.zero,
          onPressed: onHide,
          icon: const Icon(Icons.close, size: 14),
        ),
      ],
    ),
  );
}

final class DoomStatusBar extends StatelessWidget {
  const DoomStatusBar({super.key, required this.hud, required this.synthetic});

  final DoomHudSnapshot hud;
  final bool synthetic;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final bool narrow = constraints.maxWidth < 520;
      final items = <Widget>[
        _StatusValue(label: 'AMMO', value: _ammo(hud)),
        _StatusValue(label: 'HEALTH', value: '${hud.health}%'),
        _StatusValue(label: 'ARMOR', value: '${hud.armor}%'),
        _StatusValue(label: 'WEAPON', value: hud.weapon.name.toUpperCase()),
        _StatusValue(label: 'KEYS', value: _keys(hud.keys)),
        _StatusValue(label: 'SECRET', value: '${hud.secrets}'),
      ];
      return Container(
        key: const Key('status-bar'),
        color: const Color(0xEE171512),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: narrow
            ? Wrap(
                alignment: WrapAlignment.spaceBetween,
                runSpacing: 5,
                children: <Widget>[
                  for (final item in items)
                    SizedBox(width: constraints.maxWidth / 3 - 9, child: item),
                ],
              )
            : Row(
                children: <Widget>[
                  for (final item in items) Expanded(child: item),
                  Text(
                    synthetic ? 'TEST' : 'IWAD',
                    style: TextStyle(
                      color: synthetic
                          ? const Color(0xFFE0B64D)
                          : const Color(0xFF61B879),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
      );
    },
  );

  static String _ammo(DoomHudSnapshot hud) => switch (hud.weapon) {
    core.Weapon.shotgun => '${hud.shells}',
    core.Weapon.fist || core.Weapon.chainsaw => '—',
    core.Weapon.rocketLauncher => '${hud.rockets}',
    core.Weapon.pistol || core.Weapon.chaingun => '${hud.bullets}',
  };

  static String _keys(Set<core.Key> keys) => <String>[
    if (keys.contains(core.Key.blue)) 'B',
    if (keys.contains(core.Key.yellow)) 'Y',
    if (keys.contains(core.Key.red)) 'R',
  ].join().padRight(3, '·');
}

final class _StatusValue extends StatelessWidget {
  const _StatusValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54, fontSize: 9),
      ),
      Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      ),
    ],
  );
}

final class _IntermissionOverlay extends StatefulWidget {
  const _IntermissionOverlay({
    super.key,
    required this.hud,
    required this.onRestart,
    required this.onContinue,
    required this.nextMap,
    required this.episodeComplete,
    required this.advancing,
    this.errorMessage,
  });

  final DoomHudSnapshot hud;
  final VoidCallback onRestart;
  final VoidCallback onContinue;
  final String? nextMap;
  final bool episodeComplete;
  final bool advancing;
  final String? errorMessage;

  @override
  State<_IntermissionOverlay> createState() => _IntermissionOverlayState();
}

final class _IntermissionOverlayState extends State<_IntermissionOverlay>
    with SingleTickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Intermission tally');
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _finishTally() {
    if (_controller.value < 1) _controller.value = 1;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    autofocus: true,
    onKeyEvent: (_, KeyEvent event) {
      if (event is KeyDownEvent) {
        if (_controller.isCompleted &&
            widget.nextMap != null &&
            !widget.advancing &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onContinue();
        } else {
          _finishTally();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: GestureDetector(
      key: const Key('intermission-skip'),
      behavior: HitTestBehavior.opaque,
      onTap: _finishTally,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.9),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final double progress = _controller.value;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    widget.episodeComplete
                        ? 'EPISODE COMPLETE'
                        : 'LEVEL COMPLETE',
                    style: const TextStyle(
                      color: Color(0xFFC8B45A),
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _TallyRow(
                    label: 'KILLS',
                    value: _animatedPercent(
                      widget.hud.kills,
                      widget.hud.totalKills,
                      progress,
                      const Interval(0, 0.35),
                    ),
                  ),
                  _TallyRow(
                    label: 'ITEMS',
                    value: _animatedPercent(
                      widget.hud.items,
                      widget.hud.totalItems,
                      progress,
                      const Interval(0.25, 0.6),
                    ),
                  ),
                  _TallyRow(
                    label: 'SECRETS',
                    value: _animatedPercent(
                      widget.hud.secrets,
                      widget.hud.totalSecrets,
                      progress,
                      const Interval(0.5, 0.85),
                    ),
                  ),
                  _TallyRow(
                    label: 'TIME',
                    value: _animatedTime(
                      widget.hud.levelTime,
                      progress,
                      const Interval(0.75, 1),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'CLICK OR PRESS ANY KEY TO FINISH TALLY',
                    style: TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                  const SizedBox(height: 16),
                  if (widget.errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      child: Text(
                        widget.errorMessage!,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (widget.nextMap != null)
                    FilledButton(
                      key: const Key('intermission-continue'),
                      onPressed: widget.advancing ? null : widget.onContinue,
                      child: Text(
                        widget.advancing
                            ? 'LOADING…'
                            : 'CONTINUE TO ${widget.nextMap}',
                      ),
                    ),
                  FilledButton.tonal(
                    key: const Key('intermission-restart'),
                    onPressed: widget.advancing ? null : widget.onRestart,
                    child: const Text('RESTART LEVEL'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  static String _animatedPercent(
    int count,
    int total,
    double progress,
    Interval interval,
  ) {
    final int target = total == 0
        ? 100
        : ((count * 100) ~/ total).clamp(0, 100);
    final double rowProgress = interval.transform(progress);
    return '${(target * rowProgress).round()}%';
  }

  static String _animatedTime(
    int levelTime,
    double progress,
    Interval interval,
  ) {
    final int seconds = levelTime ~/ core.kTicRate;
    final int shown = (seconds * interval.transform(progress)).round();
    final int minutes = shown ~/ 60;
    final int remainder = shown % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }
}

final class _TallyRow extends StatelessWidget {
  const _TallyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 260,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 18),
          ),
          Text(
            value,
            key: Key('tally-${label.toLowerCase()}'),
            style: const TextStyle(
              color: Color(0xFFC8B45A),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    ),
  );
}

final class _ModalOverlay extends StatelessWidget {
  const _ModalOverlay({
    super.key,
    required this.title,
    required this.subtitle,
    this.onPressed,
    this.buttonLabel,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onPressed;
  final String? buttonLabel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.78),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFC8B45A),
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: const TextStyle(color: Colors.white70)),
          if (onPressed != null) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const Key('overlay-action'),
              onPressed: onPressed,
              child: Text(buttonLabel ?? 'CONTINUE'),
            ),
          ],
        ],
      ),
    ),
  );
}
