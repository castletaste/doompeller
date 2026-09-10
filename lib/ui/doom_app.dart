import 'package:flutter/material.dart';
import '../game/browser_wad_picker.dart';
import '../game/doom_app_controller.dart';
import '../game/level_preparer.dart';
import '../game/audio_session.dart';
import '../game/audio_session_factory.dart';
import '../game/browser_input.dart';
import 'doom_game_overlays.dart';
import 'doom_game_view.dart';
export 'doom_status_bar.dart' show DoomStatusBar;
export 'doom_game_view.dart'
    show
        DoomRuntimeFactory,
        DoomGameSurfaceBuilder,
        createProductionDoomRuntime;

typedef DoomWadPicker = Future<BrowserWadSelection?> Function();

final class DoomApp extends StatefulWidget {
  const DoomApp({
    super.key,
    this.controller,
    this.autoStart = true,
    this.runtimeFactory,
    this.gameSurfaceBuilder,
    this.wadPicker,
    this.audioSession,
    this.browserInput,
  });

  final DoomAppController? controller;
  final bool autoStart;
  final DoomRuntimeFactory? runtimeFactory;
  final DoomGameSurfaceBuilder? gameSurfaceBuilder;
  final DoomWadPicker? wadPicker;
  final DoomAudioSession? audioSession;
  final DoomBrowserInput? browserInput;

  @override
  State<DoomApp> createState() => _DoomAppState();
}

final class _DoomAppState extends State<DoomApp> {
  // Reused when an injected controller is removed and the app resumes ownership.
  final DoomLevelPreparer _preparer = DoomLevelPreparer();
  late DoomAppController _controller;
  late bool _ownsController;
  late DoomAudioSession _audioSession;
  late bool _ownsAudioSession;
  late DoomBrowserInput _browserInput;
  late bool _ownsBrowserInput;
  double _mouseSensitivity = 1;
  bool _touchDetected = false;
  bool? _touchControlsOverride;

  void _detectTouch() {
    if (!_touchDetected) setState(() => _touchDetected = true);
  }

  @override
  void didUpdateWidget(covariant DoomApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.browserInput, widget.browserInput)) {
      if (_ownsBrowserInput) _browserInput.dispose();
      _browserInput = widget.browserInput ?? DoomBrowserInput();
      _ownsBrowserInput = widget.browserInput == null;
    }
    if (!identical(oldWidget.audioSession, widget.audioSession)) {
      if (_ownsAudioSession) _audioSession.dispose();
      _audioSession = widget.audioSession ?? createDoomAudioSession();
      _ownsAudioSession = widget.audioSession == null;
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      if (_ownsController) _controller.dispose();
      _controller = widget.controller ?? DoomAppController(preparer: _preparer);
      _ownsController = widget.controller == null;
      if (widget.autoStart) _controller.start();
    } else if (!oldWidget.autoStart && widget.autoStart) {
      _controller.start();
    }
  }

  Future<void> _pickIwad() async {
    final controller = _controller;
    final picker = widget.wadPicker ?? pickBrowserWad;
    await controller.pickIwad(
      picker,
      isOwnerActive: () => mounted && identical(_controller, controller),
    );
  }

  @override
  void initState() {
    super.initState();
    _browserInput = widget.browserInput ?? DoomBrowserInput();
    _ownsBrowserInput = widget.browserInput == null;
    _audioSession = widget.audioSession ?? createDoomAudioSession();
    _ownsAudioSession = widget.audioSession == null;
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? DoomAppController(preparer: _preparer);
    if (widget.autoStart) _controller.start();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    if (_ownsBrowserInput) _browserInput.dispose();
    if (_ownsAudioSession) _audioSession.dispose();
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
        audioSession: _audioSession,
        browserInput: _browserInput,
        mouseSensitivity: _mouseSensitivity,
        onSensitivityChanged: (value) =>
            setState(() => _mouseSensitivity = value),
        runtimeFactory: widget.runtimeFactory,
        gameSurfaceBuilder: widget.gameSurfaceBuilder,
        touchControlsEnabled:
            _touchControlsOverride ??
            (_touchDetected || _browserInput.touchPrimary),
        onTouchDetected: _detectTouch,
        onTouchControlsChanged: (enabled) =>
            setState(() => _touchControlsOverride = enabled),
        onLoadIwad: widget.wadPicker != null || browserWadPickerAvailable
            ? _pickIwad
            : null,
      ),
    ),
  );
}

final class _DoomAppBody extends StatelessWidget {
  const _DoomAppBody({
    required this.controller,
    required this.audioSession,
    required this.browserInput,
    required this.mouseSensitivity,
    required this.onSensitivityChanged,
    required this.touchControlsEnabled,
    required this.onTouchDetected,
    required this.onTouchControlsChanged,
    this.runtimeFactory,
    this.gameSurfaceBuilder,
    this.onLoadIwad,
  });

  final DoomAppController controller;
  final DoomAudioSession audioSession;
  final DoomBrowserInput browserInput;
  final double mouseSensitivity;
  final ValueChanged<double> onSensitivityChanged;
  final bool touchControlsEnabled;
  final VoidCallback onTouchDetected;
  final ValueChanged<bool> onTouchControlsChanged;
  final DoomRuntimeFactory? runtimeFactory;
  final DoomGameSurfaceBuilder? gameSurfaceBuilder;
  final VoidCallback? onLoadIwad;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Scaffold(
      backgroundColor: Colors.black,
      body: switch (state) {
        DoomAppLoading() => const DoomLoadingView(),
        DoomAppFailure(:final errorMessage) => DoomFailureView(
          message: errorMessage,
          onFallback: controller.useFixtureFallback,
          onRetry: controller.start,
        ),
        DoomAppReady()
            when runtimeFactory != null && gameSurfaceBuilder == null =>
          const DoomRuntimeConfigurationError(
            message:
                'A custom Doom runtime requires a custom game surface builder.',
          ),
        DoomAppReady(:final level) => DoomGameView(
          key: ValueKey(level),
          level: level,
          audioSession: audioSession,
          onRetry: controller.start,
          browserInput: browserInput,
          mouseSensitivity: mouseSensitivity,
          onSensitivityChanged: onSensitivityChanged,
          synthetic: state.isFixture,
          setupMessage: state.setupMessage,
          selectionErrorMessage: state.errorMessage,
          onLoadIwad: onLoadIwad,
          onContinue: (exit) => controller.advanceLevel(level, exit),
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
