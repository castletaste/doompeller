import 'dart:async';
import 'dart:collection';

import 'package:doom_core/doom_core.dart';

import 'sound_playback.dart';

/// Serial audio output with bounded backpressure. Empty tics advance the mixer
/// clock without allocating queued futures. During a stalled backend, retain
/// at most 128 pending sounds. Overflow evicts the oldest expendable sound,
/// using the core journal's critical-cue policy. Batches preserve their listener,
/// tic and ordering; a slow backend cannot accumulate an unbounded history.
final class DoomSoundOutput {
  DoomSoundOutput(this._playback, {required this.onError});

  static const maxPendingEvents = 128;
  final SoundPlaybackManager _playback;
  final void Function(Object, StackTrace) onError;
  final Queue<_SoundBatch> _pending = Queue();
  int _pendingEvents = 0;
  int _latestTic = 0;
  bool _stopRequested = false;
  bool _disposed = false;
  Completer<void>? _draining;

  Future<void> get idle => _draining?.future ?? Future<void>.value();
  int get pendingEventCount => _pendingEvents;

  void add({
    required List<SoundEvent> events,
    required AudioListener listener,
    required int gameTic,
    Map<int, AudioPosition> sources = const {},
  }) {
    if (_disposed) return;
    _latestTic = gameTic;
    try {
      _playback.updateSpatial(listener: listener, sources: sources);
    } catch (error, stackTrace) {
      onError(error, stackTrace);
    }
    if (events.isEmpty) {
      if (_draining == null) _playback.advanceToTic(gameTic);
      return;
    }
    final batch = _SoundBatch([], listener, gameTic);
    for (final event in events) {
      if (_pendingEvents == maxPendingEvents && !_makeRoom(event)) continue;
      if (batch.events.isEmpty) _pending.add(batch);
      batch.events.add(event);
      _pendingEvents++;
    }
    _startDrain();
  }

  bool _makeRoom(SoundEvent incoming) {
    for (final batch in _pending) {
      final expendable = batch.events.indexWhere((event) => !event.isCritical);
      if (expendable < 0) continue;
      batch.events.removeAt(expendable);
      if (batch.events.isEmpty) _pending.remove(batch);
      _pendingEvents--;
      return true;
    }
    if (!incoming.isCritical) return false;
    final oldest = _pending.first;
    oldest.events.removeAt(0);
    if (oldest.events.isEmpty) _pending.removeFirst();
    _pendingEvents--;
    return true;
  }

  void stop() {
    if (_disposed) return;
    _discardPending();
    _stopRequested = true;
    _startDrain();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _discardPending();
    _startDrain();
  }

  void _discardPending() {
    _pending.clear();
    _pendingEvents = 0;
    _playback.cancelPendingEvents();
  }

  void _startDrain() {
    if (_draining != null) return;
    final done = _draining = Completer<void>();
    unawaited(_drain(done));
  }

  Future<void> _drain(Completer<void> done) async {
    try {
      while (true) {
        if (_disposed) {
          await _attempt(_playback.dispose);
          return;
        }
        if (_stopRequested) {
          _stopRequested = false;
          await _attempt(_playback.stopAll);
          continue;
        }
        if (_pending.isEmpty) {
          _playback.advanceToTic(_latestTic);
          return;
        }
        final batch = _pending.removeFirst();
        _pendingEvents -= batch.events.length;
        await _attempt(
          () => _playback.consumeEvents(
            events: batch.events,
            listener: batch.listener,
            gameTic: batch.gameTic,
          ),
        );
      }
    } finally {
      _draining = null;
      done.complete();
    }
  }

  Future<void> _attempt(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      onError(error, stackTrace);
    }
  }
}

final class _SoundBatch {
  const _SoundBatch(this.events, this.listener, this.gameTic);

  final List<SoundEvent> events;
  final AudioListener listener;
  final int gameTic;
}
