import 'dart:async';

import 'package:doom_core/doom_core.dart';
import 'package:doom_geometry/doom_geometry.dart';
import 'package:doompeller/adapter/adapter.dart';
import 'package:doompeller/game/audio_backend_factory.dart';
import 'package:doompeller/game/audio_backend_factory_stub.dart' as stub;
import 'package:doompeller/game/content_source.dart';
import 'package:doompeller/game/doom_input.dart';
import 'package:doompeller/game/level_preparer.dart';
import 'package:doompeller/game/macos_audio_backend.dart';
import 'package:doompeller/game/sound_playback.dart';
import 'package:doompeller/ui/doom_app.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../adapter/fake_gpu_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(MacOsAudioBackend.channelName);
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    FakeGpuBackend();
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'production factory selects the macOS MethodChannel backend on VM',
    () {
      expect(createDefaultAudioBackend(), isA<MacOsAudioBackend>());
    },
    testOn: 'mac-os',
  );

  test('non-IO factory remains silent', () {
    expect(stub.createDefaultAudioBackend(), isA<NoAudioBackend>());
  });

  test(
    'production UI runtime routes a synthetic fire event to MethodChannel',
    () async {
      final DoomRuntimeGame runtime =
          createProductionDoomRuntime(await _fixtureLevel()) as DoomRuntimeGame;
      runtime.input.press(DoomControl.attack);
      for (var tic = 0; tic < 20; tic++) {
        runtime.advanceMicrosForTest(28572);
      }
      runtime.input.release(DoomControl.attack);
      await runtime.soundPlaybackIdleForTest;

      final MethodCall play = calls.firstWhere((call) => call.method == 'play');
      final Map<Object?, Object?> arguments =
          play.arguments as Map<Object?, Object?>;
      expect(arguments['wavBytes'], isA<Uint8List>());
      expect((arguments['wavBytes']! as Uint8List).sublist(0, 4), <int>[
        82,
        73,
        70,
        70,
      ]);
      expect(arguments['channelId'], inInclusiveRange(0, 7));
    },
    testOn: 'mac-os',
  );

  test(
    'play, completion, stop, and dispose obey the channel contract',
    () async {
      final MacOsAudioBackend backend = MacOsAudioBackend(channel: channel);
      int completions = 0;
      final AudioPlayRequest first = _request(playbackId: 7);

      await backend.play(first, onComplete: () => completions++);
      expect(calls.single.method, 'play');
      expect(calls.single.arguments, <String, Object>{
        'channelId': 2,
        'playbackId': 7,
        'wavBytes': first.wavBytes,
        'volume': 0.75,
        'pan': -0.25,
      });

      await _nativeCallback(messenger, channel, channelId: 2, playbackId: 7);
      expect(completions, 1);

      await backend.play(
        _request(playbackId: 8),
        onComplete: () => completions++,
      );
      await backend.stop(2);
      await _nativeCallback(messenger, channel, channelId: 2, playbackId: 8);
      expect(completions, 1, reason: 'stopped playback must not complete');
      expect(calls[calls.length - 1], isA<MethodCall>());
      expect(calls[calls.length - 1].method, 'stop');
      expect(calls[calls.length - 1].arguments, <String, Object>{
        'channelId': 2,
      });

      await backend.dispose();
      expect(calls.last.method, 'dispose');
    },
  );

  test('stale completion cannot release a replacement playback', () async {
    final MacOsAudioBackend backend = MacOsAudioBackend(channel: channel);
    int oldCompletions = 0;
    int currentCompletions = 0;

    await backend.play(
      _request(playbackId: 20),
      onComplete: () => oldCompletions++,
    );
    await backend.play(
      _request(playbackId: 21),
      onComplete: () => currentCompletions++,
    );
    await _nativeCallback(messenger, channel, channelId: 2, playbackId: 20);
    await _nativeCallback(messenger, channel, channelId: 2, playbackId: 21);

    expect(oldCompletions, 0);
    expect(currentCompletions, 1);
    await backend.dispose();
  });

  test(
    'disposing an older Dart backend keeps the newer callback handler',
    () async {
      final MacOsAudioBackend older = MacOsAudioBackend(channel: channel);
      final MacOsAudioBackend newer = MacOsAudioBackend(channel: channel);
      var completions = 0;

      await older.dispose();
      await newer.play(
        _request(playbackId: 30),
        onComplete: () => completions++,
      );
      await _nativeCallback(messenger, channel, channelId: 2, playbackId: 30);

      expect(completions, 1);
      await newer.dispose();
    },
  );
}

Future<PreparedDoomLevel> _fixtureLevel() async {
  final DoomContent content = DoomContentSource(
    environment: const <String, String>{},
  ).loadFixture();
  final WadResources resources = WadResources.load(content.wads);
  final MapData map = MapData.load(content.wads, content.mapName);
  return PreparedDoomLevel(
    content: content,
    resources: resources,
    map: map,
    geometry: DoomGeometryCompiler.compile(map, resources),
    gameConfig: const GameConfig(),
    seed: 3,
  );
}

AudioPlayRequest _request({required int playbackId}) => AudioPlayRequest(
  channelId: 2,
  playbackId: playbackId,
  soundId: 'DSPISTOL',
  wavBytes: Uint8List.fromList(<int>[82, 73, 70, 70]),
  volume: 0.75,
  pan: -0.25,
  sourceId: 1,
  fromPlayer: true,
);

Future<void> _nativeCallback(
  TestDefaultBinaryMessenger messenger,
  MethodChannel channel, {
  required int channelId,
  required int playbackId,
}) async {
  final ByteData message = const StandardMethodCodec().encodeMethodCall(
    MethodCall('playbackComplete', <String, Object>{
      'channelId': channelId,
      'playbackId': playbackId,
    }),
  );
  final Completer<void> handled = Completer<void>();
  await messenger.handlePlatformMessage(
    channel.name,
    message,
    (_) => handled.complete(),
  );
  await handled.future;
}
