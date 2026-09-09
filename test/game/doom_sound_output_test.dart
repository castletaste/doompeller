import 'dart:async';

import 'package:doompeller/game/doom_sound_output.dart';
import 'package:doompeller/game/sound_playback.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sound_playback_test.dart' as fixture;

const listener = AudioListener(position: AudioPosition(0, 0), angle: 0);

void main() {
  test('ordinary overflow preserves pending critical door cues', () async {
    final backend = _DelayedBackend();
    final output = _output(backend);
    output.add(events: [fixture.event()], listener: listener, gameTic: 0);
    output.add(
      events: [fixture.event(soundId: 'DSDOROPN')],
      listener: listener,
      gameTic: 1,
    );
    for (var tic = 2; tic < 300; tic++) {
      output.add(
        events: [fixture.event(tic: tic)],
        listener: listener,
        gameTic: tic,
      );
    }
    backend.reply.complete();
    await output.idle;
    expect(backend.playCalls[1].soundId, 'DSDOROPN');
    expect(backend.playCalls, hasLength(1 + DoomSoundOutput.maxPendingEvents));
    output.dispose();
    await output.idle;
  });

  test('stalled output retains a bounded tail and resumes in order', () async {
    final backend = _DelayedBackend();
    final output = _output(backend);
    for (var tic = 0; tic < 1000; tic++) {
      output.add(
        events: [fixture.event(sourceId: tic, tic: tic)],
        listener: listener,
        gameTic: tic,
      );
      expect(
        output.pendingEventCount,
        lessThanOrEqualTo(DoomSoundOutput.maxPendingEvents),
      );
    }
    expect(backend.playCalls, hasLength(1));
    backend.reply.complete();
    await output.idle;
    expect(backend.playCalls, hasLength(1 + DoomSoundOutput.maxPendingEvents));
    expect(backend.playCalls.last.sourceId, 999);
    expect(
      backend.playCalls.skip(1).map((call) => call.sourceId),
      orderedEquals([
        for (
          var tic = 1000 - DoomSoundOutput.maxPendingEvents;
          tic < 1000;
          tic++
        )
          tic,
      ]),
    );
    output.dispose();
    await output.idle;
  });

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'dispose' : 'stop'} cancels active remainder and pending sounds',
      () async {
        final backend = _DelayedBackend();
        final output = _output(backend);
        output.add(
          events: [fixture.event(), fixture.event(sourceId: 2)],
          listener: listener,
          gameTic: 1,
        );
        output.add(
          events: [fixture.event(tic: 2)],
          listener: listener,
          gameTic: 2,
        );
        dispose ? output.dispose() : output.stop();
        backend.reply.complete();
        await output.idle;
        expect(output.pendingEventCount, 0);
        expect(backend.playCalls, hasLength(1));
        expect(backend.stopCalls, [0]);
        expect(backend.disposed, dispose);
        output.dispose();
        await output.idle;
      },
    );
  }

  test('dispose reaches backend even when stopping a channel fails', () async {
    final backend = _DelayedBackend()..reply.complete();
    final errors = <Object>[];
    final output = _output(backend, onError: (error, _) => errors.add(error));
    output.add(events: [fixture.event()], listener: listener, gameTic: 1);
    await output.idle;
    backend.failStop = true;
    output.dispose();
    await output.idle;
    expect(errors, hasLength(1));
    expect(backend.disposed, isTrue);
  });
}

DoomSoundOutput _output(
  _DelayedBackend backend, {
  void Function(Object, StackTrace)? onError,
}) => DoomSoundOutput(
  SoundPlaybackManager(
    backend: backend,
    catalog: MapSoundCatalog({
      'DSPISTOL': fixture.definition(1),
      'DSDOROPN': fixture.definition(1),
    }),
  ),
  onError: onError ?? (error, stack) => fail('$error\n$stack'),
);

final class _DelayedBackend extends FakeAudioBackend {
  final reply = Completer<void>();
  bool failStop = false;

  @override
  Future<void> play(
    AudioPlayRequest request, {
    void Function()? onComplete,
  }) async {
    await super.play(request, onComplete: onComplete);
    if (playCalls.length == 1) await reply.future;
  }

  @override
  Future<void> stop(int channelId) async {
    if (failStop) throw StateError('stop failed');
    await super.stop(channelId);
  }
}
