import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:doom_music/doom_music.dart';
import 'package:doom_wad/doom_wad.dart';
import 'package:web/web.dart' as web;

import 'audio_transport_state.dart';

@JS('self')
external web.DedicatedWorkerGlobalScope get _self;

web.MessagePort? _outputPort;
DoomMusicPlayer? _player;
final PendingMusicConfigurations<_PendingSong> _pendingSongs =
    PendingMusicConfigurations<_PendingSong>();
bool _configurationScheduled = false;
bool _failed = false;
int _epoch = 0;
int _blockFrames = 4096;
int _queueBlocks = 8;
int _renderedBlocks = 0;
String _track = '';

void main() {
  _self.onmessage = ((web.MessageEvent event) {
    if (_failed) return;
    final JSAny? data = event.data;
    if (data == null) return;
    final message = _WorkerMessage._(data as JSObject);
    switch (message.type) {
      case 'attach':
        _attach(message);
      case 'configure':
        _queueConfiguration(message);
      case 'debugCrash':
        if (const bool.fromEnvironment('DOOMPELLER_AUDIO_HARNESS')) {
          Timer.run(() => throw StateError('Requested audio worker QA crash.'));
        }
    }
  }).toJS;
  _self.onmessageerror = ((web.Event _) {
    _fatal('The music worker received an invalid control message.');
  }).toJS;
}

void _attach(_WorkerMessage message) {
  if (_outputPort != null) return;
  final int blockFrames = message.blockFrames;
  final int queueBlocks = message.queueBlocks;
  if (blockFrames != 4096 || queueBlocks != 8) {
    _fatal('The music worker received an unsupported queue configuration.');
    return;
  }
  final port = message.port;
  _blockFrames = blockFrames;
  _queueBlocks = queueBlocks;
  _outputPort = port;
  port.onmessage = ((web.MessageEvent event) {
    if (_failed) return;
    final JSAny? data = event.data;
    if (data == null) return;
    final message = _WorkerMessage._(data as JSObject);
    switch (message.type) {
      case 'credit':
        _renderCredit(message);
      case 'retire':
        _retire(message.epoch);
    }
  }).toJS;
  port.onmessageerror = ((web.Event _) {
    _fatal('The music PCM channel received an invalid message.');
  }).toJS;
  port.start();
}

void _queueConfiguration(_WorkerMessage message) {
  final int epoch = message.epoch;
  if (epoch < _epoch) {
    _acknowledgeConfiguration(epoch);
    return;
  }
  try {
    final Uint8List mus = message.mus.toDart;
    final Uint8List genMidi = message.genMidi.toDart;
    const DoomLimits limits = DoomLimits.defaults;
    if (mus.lengthInBytes > limits.maxMusicBytes ||
        genMidi.lengthInBytes > limits.maxGenMidiBytes) {
      _configurationFault(epoch, 'Music input exceeds its safe size limit.');
      return;
    }
    final pending = _PendingSong(
      epoch: epoch,
      track: message.track,
      mus: Uint8List.fromList(mus),
      genMidi: Uint8List.fromList(genMidi),
    );
    _pendingSongs.replace(epoch, pending);
    if (_configurationScheduled) return;
    _configurationScheduled = true;
    Timer.run(_applyPendingConfiguration);
  } on Object catch (error) {
    _configurationFault(epoch, _safeError(error));
  }
}

void _applyPendingConfiguration() {
  _configurationScheduled = false;
  final _PendingSong? pending = _pendingSongs.take();
  if (pending == null) return;
  if (pending.epoch < _epoch) {
    _acknowledgeConfiguration(pending.epoch);
    return;
  }
  try {
    final MusSong song = parseMus(pending.mus);
    final GenMidiBank bank = parseGenMidi(pending.genMidi);
    _epoch = pending.epoch;
    _track = pending.track;
    _renderedBlocks = 0;
    _player = DoomMusicPlayer(song, bank);
    _acknowledgeConfiguration(_epoch);
  } on Object catch (error) {
    _player = null;
    _epoch = pending.epoch;
    _configurationFault(pending.epoch, _safeError(error));
  }
}

void _acknowledgeConfiguration(int epoch) {
  _outputPort?.postMessage(
    <String, Object?>{'type': 'configured', 'epoch': epoch}.jsify(),
  );
}

void _renderCredit(_WorkerMessage message) {
  if (message.epoch != _epoch || message.frames != _blockFrames) return;
  final DoomMusicPlayer? player = _player;
  final web.MessagePort? port = _outputPort;
  if (player == null || port == null) return;
  try {
    final samples = Float32List(_blockFrames);
    player.renderInto(samples);
    final JSFloat32Array transferred = samples.toJS;
    port.postMessage(
      <String, Object?>{
        'type': 'pcm',
        'epoch': _epoch,
        'samples': transferred,
      }.jsify(),
      <JSObject>[_ArrayBufferView._(transferred).buffer].toJS,
    );
    _renderedBlocks++;
    if (_renderedBlocks % (16 * _queueBlocks) == 0) {
      port.postMessage(
        <String, Object?>{
          'type': 'workerStats',
          'epoch': _epoch,
          'track': _track,
          'renderedFrames': player.renderedFrames,
          'loopCount': player.loopCount,
        }.jsify(),
      );
    }
  } on Object catch (error) {
    _fatal('OPL2 rendering failed: ${_safeError(error)}');
  }
}

void _retire(int epoch) {
  if (epoch < _epoch) {
    _acknowledgeRetire(epoch);
    return;
  }
  _epoch = epoch;
  _player = null;
  final int? abandonedConfiguration = _pendingSongs.abandonThrough(epoch);
  if (abandonedConfiguration != null) {
    _acknowledgeConfiguration(abandonedConfiguration);
  }
  _track = '';
  _renderedBlocks = 0;
  _acknowledgeRetire(epoch);
}

void _acknowledgeRetire(int epoch) {
  _outputPort?.postMessage(
    <String, Object?>{'type': 'retired', 'epoch': epoch}.jsify(),
  );
}

void _configurationFault(int epoch, String message) {
  _outputPort?.postMessage(
    <String, Object?>{
      'type': 'fault',
      'epoch': epoch,
      'fatal': false,
      'message': message,
    }.jsify(),
  );
}

void _fatal(String message) {
  if (_failed) return;
  _failed = true;
  final String safe = _safeError(message);
  _outputPort?.postMessage(
    <String, Object?>{
      'type': 'fault',
      'epoch': _epoch,
      'fatal': true,
      'message': safe,
    }.jsify(),
  );
  _self.postMessage(
    <String, Object?>{'type': 'fault', 'fatal': true, 'message': safe}.jsify(),
  );
  _player = null;
  _pendingSongs.clear();
}

String _safeError(Object error) {
  final String message = error.toString();
  return message.length <= 512 ? message : message.substring(0, 512);
}

final class _PendingSong {
  const _PendingSong({
    required this.epoch,
    required this.track,
    required this.mus,
    required this.genMidi,
  });

  final int epoch;
  final String track;
  final Uint8List mus;
  final Uint8List genMidi;
}

extension type _WorkerMessage._(JSObject _) implements JSObject {
  external String get type;
  external int get epoch;
  external int get frames;
  external int get blockFrames;
  external int get queueBlocks;
  external String get track;
  external JSUint8Array get mus;
  external JSUint8Array get genMidi;
  external web.MessagePort get port;
}

extension type _ArrayBufferView._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}
