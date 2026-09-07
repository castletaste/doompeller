import 'dart:async';

import 'package:doompeller/game/macos_audio_backend.dart';
import 'package:doompeller/game/sound_playback.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('doompeller.refactor.audio_ownership');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativePlayback = <int, int>{};
  final calls = <MethodCall>[];

  void apply(MethodCall call) {
    calls.add(call);
    switch (call.method) {
      case 'play':
        final args = call.arguments as Map<Object?, Object?>;
        nativePlayback[args['channelId'] as int] = args['playbackId'] as int;
      case 'stop':
        final args = call.arguments as Map<Object?, Object?>;
        nativePlayback.remove(args['channelId']);
      case 'dispose':
        nativePlayback.clear();
    }
  }

  setUp(() {
    calls.clear();
    nativePlayback.clear();
    messenger.setMockMethodCallHandler(channel, (call) async => apply(call));
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'ownership is independent across messengers and channel names',
    () async {
      final secondMessenger = TestDefaultBinaryMessenger(messenger);
      final secondChannel = MethodChannel(
        channel.name,
        const StandardMethodCodec(),
        secondMessenger,
      );
      const otherName = MethodChannel('doompeller.refactor.other_audio');
      final secondCalls = <MethodCall>[];
      final otherCalls = <MethodCall>[];
      secondMessenger.setMockMethodCallHandler(
        secondChannel,
        (call) async => secondCalls.add(call),
      );
      messenger.setMockMethodCallHandler(
        otherName,
        (call) async => otherCalls.add(call),
      );
      final first = MacOsAudioBackend(channel: channel);
      final second = MacOsAudioBackend(channel: secondChannel);
      final other = MacOsAudioBackend(channel: otherName);
      await first.play(_request(1));
      await second.play(_request(1));
      await other.play(_request(1));
      expect(calls.single.method, 'play');
      expect(secondCalls.single.method, 'play');
      expect(otherCalls.single.method, 'play');
      await first.dispose();
      await second.dispose();
      await other.dispose();
      secondMessenger.setMockMethodCallHandler(secondChannel, null);
      messenger.setMockMethodCallHandler(otherName, null);
    },
  );

  test(
    'late dispose cannot stop the newer owner of the native engine',
    () async {
      final old = MacOsAudioBackend(channel: channel);
      final current = MacOsAudioBackend(channel: channel);
      addTearDown(current.dispose);
      await current.play(_request(1));
      final activePlayback = nativePlayback[2];
      await old.dispose();
      expect(
        nativePlayback[2],
        activePlayback,
        reason: 'native dispose clears the shared AVAudioEngine',
      );
      expect(calls.where((call) => call.method == 'dispose'), isEmpty);
    },
  );

  test(
    'old completion cannot complete a new session reusing logical IDs',
    () async {
      final old = MacOsAudioBackend(channel: channel);
      await old.play(_request(1));
      final oldTransportId = nativePlayback[2]!;
      final current = MacOsAudioBackend(channel: channel);
      addTearDown(() async {
        await old.dispose();
        await current.dispose();
      });
      var completions = 0;
      await current.play(_request(1), onComplete: () => completions++);
      final currentTransportId = nativePlayback[2]!;
      await _complete(messenger, channel, oldTransportId);
      expect(
        completions,
        0,
        reason: 'native callback identity must be unique across backend owners',
      );
      await _complete(messenger, channel, currentTransportId);
      expect(completions, 1);
    },
  );

  for (final stop in [true, false]) {
    test(
      'queued ${stop ? 'stop' : 'play'} is discarded after ownership changes',
      () async {
        final entered = Completer<void>();
        final reply = Completer<void>();
        var firstPlay = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          apply(call);
          if (call.method == 'play' && firstPlay) {
            firstPlay = false;
            entered.complete();
            await reply.future;
          }
          return null;
        });
        final old = MacOsAudioBackend(channel: channel);
        final pendingOperation = old
            .play(_request(1))
            .then((_) => stop ? old.stop(2) : old.play(_request(2)));
        await entered.future;
        final current = MacOsAudioBackend(channel: channel);
        addTearDown(() async {
          await old.dispose();
          await current.dispose();
        });
        await current.play(_request(1));
        final activePlayback = nativePlayback[2];
        final acceptedCalls = calls.length;
        reply.complete();
        await pendingOperation;
        expect(nativePlayback[2], activePlayback);
        expect(
          calls.length,
          acceptedCalls,
          reason: 'retired owners cannot send new native commands',
        );
      },
    );
  }
}

AudioPlayRequest _request(int playbackId) => AudioPlayRequest(
  channelId: 2,
  playbackId: playbackId,
  soundId: 'DSPISTOL',
  wavBytes: Uint8List.fromList([82, 73, 70, 70]),
  volume: 0.75,
  pan: 0,
  sourceId: 1,
  fromPlayer: true,
);

Future<void> _complete(
  TestDefaultBinaryMessenger messenger,
  MethodChannel channel,
  int playbackId,
) async {
  final message = const StandardMethodCodec().encodeMethodCall(
    MethodCall('playbackComplete', {'channelId': 2, 'playbackId': playbackId}),
  );
  final handled = Completer<void>();
  await messenger.handlePlatformMessage(
    channel.name,
    message,
    (_) => handled.complete(),
  );
  await handled.future;
}
