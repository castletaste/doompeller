import 'package:doom_core/doom_core.dart' show GameConfig;
import 'package:doompeller/game/audio_session.dart';
import 'package:doompeller/game/doom_app_controller.dart';
import 'package:doompeller/game/sound_playback.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:doompeller/ui/doom_game_overlays.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../widget_test.dart' show FakeRuntime, fixtureLevel, testSurface;
import '../adapter/fake_gpu_backend.dart';

final class _Session extends DoomAudioSession {
  @override
  double musicVolume = 0.5;
  @override
  double effectsVolume = 0.75;
  @override
  bool controlsAvailable = true;
  @override
  bool musicAvailable = true;
  @override
  String? errorMessage;
  int acquired = 0;
  bool disposed = false;

  @override
  AudioBackend acquireLevel() {
    acquired++;
    return FakeAudioBackend();
  }

  @override
  void setMusicVolume(double value) {
    musicVolume = clampAudioVolume(value);
    notifyListeners();
  }

  @override
  void setEffectsVolume(double value) {
    effectsVolume = clampAudioVolume(value);
    notifyListeners();
  }

  void failMusic() {
    musicAvailable = false;
    errorMessage = 'Music is unavailable.';
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  test('runtime creation failure releases its audio backend', () async {
    FakeGpuBackend();
    final base = await fixtureLevel();
    final invalid = PreparedDoomLevel(
      content: base.content,
      resources: base.resources,
      map: base.map,
      geometry: base.geometry,
      gameConfig: const GameConfig(maxCatchUpTics: 0),
      seed: base.seed,
    );
    final backend = FakeAudioBackend();
    expect(
      () => createProductionDoomRuntime(invalid, audioBackend: backend),
      throwsAssertionError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.disposed, isTrue);
  });

  testWidgets('pause sliders are independent and survive reopening the panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _Session();
    addTearDown(session.dispose);
    Widget panel() => MaterialApp(
      theme: ThemeData.dark(),
      home: DoomPauseOverlay(onResume: () {}, audioSession: session),
    );
    await tester.pumpWidget(panel());
    final music = find.byKey(const Key('pause-music-volume'));
    final effects = find.byKey(const Key('pause-effects-volume'));
    await tester.ensureVisible(music);
    await tester.drag(music, const Offset(-80, 0));
    await tester.pump();
    expect(session.musicVolume, lessThan(0.5));
    expect(session.effectsVolume, 0.75);
    final musicValue = session.musicVolume;
    await tester.ensureVisible(effects);
    await tester.drag(effects, const Offset(-60, 0));
    await tester.pump();
    expect(session.effectsVolume, lessThan(0.75));
    expect(session.musicVolume, musicValue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(panel());
    expect(tester.widget<Slider>(music).value, musicValue);
    expect(tester.widget<Slider>(effects).value, session.effectsVolume);
    session.failMusic();
    await tester.pump();
    expect(find.text('Music is unavailable.'), findsOneWidget);
    expect(tester.widget<Slider>(effects).onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'injected app sessions stay caller-owned and volume leaves runtime intact',
    (tester) async {
      final first = _Session();
      final second = _Session();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final controller = DoomAppController(
        initialState: DoomAppState.ready(
          await fixtureLevel(),
          phase: DoomAppPhase.fixtureReady,
        ),
      );
      addTearDown(controller.dispose);
      final runtime = FakeRuntime();
      var created = 0;
      var surfaces = 0;
      Widget app(_Session session) => DoomApp(
        controller: controller,
        autoStart: false,
        audioSession: session,
        runtimeFactory: (_) {
          created++;
          return runtime;
        },
        gameSurfaceBuilder: (context, value) {
          surfaces++;
          return testSurface(context, value);
        },
      );
      await tester.pumpWidget(app(first));
      await tester.pump();
      runtime.togglePause();
      await tester.pump();
      final surfaceCount = surfaces;
      first.setMusicVolume(0.2);
      first.setEffectsVolume(0.3);
      await tester.pump();
      expect(created, 1);
      expect(surfaces, surfaceCount);
      expect(
        first.acquired,
        0,
        reason: 'an injected runtime owns its own backend',
      );
      await tester.pumpWidget(app(second));
      expect(first.disposed, isFalse);
      expect(created, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(second.disposed, isFalse);
    },
  );
}
