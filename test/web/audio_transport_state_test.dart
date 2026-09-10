import 'package:doompeller/web/audio_transport_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native-rate constructor rejection preserves default-rate effects', () {
    final attempts = <int?>[];
    final context = createAudioContextWithFallback((rate) {
      attempts.add(rate);
      if (rate != null) throw UnsupportedError('unsupported sample rate');
      return (sampleRate: 48000, effectsAvailable: true);
    }, nativeRate: 49716);
    expect(attempts, [49716, null]);
    expect(context.effectsAvailable, isTrue);
    expect(context.sampleRate, isNot(49716));
    expect(
      () => createAudioContextWithFallback<Object>((_) {
        throw UnsupportedError('Web Audio unavailable');
      }, nativeRate: 49716),
      throwsUnsupportedError,
    );
  });

  test('disabled transport rejects late readiness and queued messages', () {
    final state = AudioTransportLifecycleState();
    final int initialization = state.beginInitialization();

    state.disable();

    expect(state.completeInitialization(initialization), isFalse);
    expect(state.available, isFalse);
    expect(state.acceptsMessages, isFalse);

    final int successor = state.beginInitialization();
    expect(state.completeInitialization(successor), isTrue);
    expect(state.acceptsMessages, isTrue);
    state.dispose();
    expect(state.acceptsMessages, isFalse);
    expect(() => state.beginInitialization(), throwsStateError);
  });

  test(
    'music admission coalesces replacements behind retire acknowledgements',
    () {
      final state = MusicAdmissionState<String>();
      state.replaceConfiguration(1, 'song-1');
      state.queueRetire(1);

      expect(state.takeRetire(transportReady: true), 1);
      expect(state.takeConfiguration(transportReady: true), isNull);

      for (var epoch = 2; epoch <= 101; epoch++) {
        state.replaceConfiguration(epoch, 'song-$epoch');
        state.queueRetire(epoch);
      }

      expect(state.retireInFlight, 1);
      expect(state.pendingRetireEpoch, 101);
      expect(state.pendingConfiguration, 'song-101');
      expect(state.takeRetire(transportReady: true), isNull);
      expect(state.takeConfiguration(transportReady: true), isNull);

      state.acknowledgeRetire(1);
      expect(state.takeRetire(transportReady: true), 101);
      expect(state.takeConfiguration(transportReady: true), isNull);
      state.acknowledgeRetire(101);
      expect(state.takeConfiguration(transportReady: true), 'song-101');
      expect(state.configurationInFlight, 101);
    },
  );

  test(
    'retire can abandon in-flight worker configuration without deadlock',
    () {
      final admission = MusicAdmissionState<String>();
      final workerPending = PendingMusicConfigurations<String>();

      admission.replaceConfiguration(7, 'song-7');
      expect(admission.takeConfiguration(transportReady: true), 'song-7');
      workerPending.replace(7, 'song-7');

      admission.replaceConfiguration(8, 'song-8');
      admission.queueRetire(8);
      expect(admission.takeRetire(transportReady: true), 8);
      expect(workerPending.abandonThrough(8), 7);

      // The worker publishes the abandoned configuration acknowledgement before
      // the retire acknowledgement on its single worklet port.
      admission.acknowledgeConfiguration(7);
      admission.acknowledgeRetire(8);
      expect(admission.takeConfiguration(transportReady: true), 'song-8');
      expect(admission.configurationInFlight, 8);
    },
  );

  test('retire leaves a newer pending worker configuration intact', () {
    final pending = PendingMusicConfigurations<String>();
    pending.replace(12, 'song-12');

    expect(pending.abandonThrough(11), isNull);
    expect(pending.take(), 'song-12');
  });

  test('pause queues one suspend behind resume in either completion order', () {
    for (final suspendFirst in [false, true]) {
      final state = AudioContextCommandState();
      final resume = state.takeNext(
        unlocked: true,
        shouldRun: true,
        contextState: 'suspended',
      )!;
      expect(resume.command, AudioContextCommand.resume);
      final suspend = state.takeNext(
        unlocked: true,
        shouldRun: false,
        contextState: 'suspended',
      )!;
      expect(suspend.command, AudioContextCommand.suspend);
      expect(
        state.takeNext(
          unlocked: true,
          shouldRun: false,
          contextState: 'suspended',
        ),
        isNull,
      );
      if (suspendFirst) {
        state.settle(suspend);
        // Already-suspended calls must not starve the pending resume's task.
        for (var i = 0; i < 100; i++) {
          expect(
            state.takeNext(
              unlocked: true,
              shouldRun: false,
              contextState: 'suspended',
            ),
            isNull,
          );
        }
        expect(state.settle(resume), isFalse);
      } else {
        state.settle(resume);
        expect(
          state.takeNext(
            unlocked: true,
            shouldRun: false,
            contextState: 'running',
          ),
          isNull,
        );
        state.settle(suspend);
      }
      expect(state.resumePending, isFalse);
      expect(state.suspendPending, isFalse);
    }
  });

  test('superseded resume does not block or settle the next gesture', () {
    final state = AudioContextCommandState();
    final old = state.takeNext(
      unlocked: true,
      shouldRun: true,
      contextState: 'suspended',
    )!;
    final pause = state.takeNext(
      unlocked: true,
      shouldRun: false,
      contextState: 'suspended',
    )!;
    state.settle(pause);
    final next = state.takeNext(
      unlocked: true,
      shouldRun: true,
      contextState: 'suspended',
    )!;
    expect(state.settle(old), isFalse);
    expect(state.settle(old, succeeded: false), isFalse);
    expect(state.resumePending, isTrue);
    expect(state.settle(next), isTrue);
    expect(state.resumePending, isFalse);
  });

  test('late running notification reconciles to the current paused intent', () {
    final state = AudioContextCommandState();
    state.takeNext(unlocked: true, shouldRun: true, contextState: 'suspended');
    state.settle(
      state.takeNext(
        unlocked: true,
        shouldRun: false,
        contextState: 'suspended',
      )!,
    );
    expect(
      state
          .takeNext(unlocked: true, shouldRun: false, contextState: 'running')
          ?.command,
      AudioContextCommand.suspend,
    );
  });

  test('failed suspend and disposal cannot retire an unrelated request', () {
    final state = AudioContextCommandState();
    final resume = state.takeNext(
      unlocked: true,
      shouldRun: true,
      contextState: 'suspended',
    )!;
    final suspend = state.takeNext(
      unlocked: true,
      shouldRun: false,
      contextState: 'suspended',
    )!;
    state.settle(suspend, succeeded: false);
    expect(state.resumePending, isTrue);
    state.clear();
    final next = state.takeNext(
      unlocked: true,
      shouldRun: true,
      contextState: 'suspended',
    )!;
    expect(state.settle(resume), isFalse);
    expect(state.resumePending, isTrue);
    state.settle(next);
    expect(
      state.takeNext(unlocked: true, shouldRun: true, contextState: 'closed'),
      isNull,
    );
  });
}
