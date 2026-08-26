import 'package:flutter/services.dart';

import 'sound_playback.dart';

/// In-memory MethodChannel transport for the macOS AVAudioEngine backend.
final class MacOsAudioBackend implements AudioBackend {
  MacOsAudioBackend({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    final WeakReference<MacOsAudioBackend> backend = WeakReference(this);
    _channel.setMethodCallHandler((MethodCall call) async {
      await backend.target?._handleNativeCall(call);
    });
  }

  static const String channelName = 'dev.castletaste.doompeller/audio';

  final MethodChannel _channel;
  final Map<int, int> _playbackByChannel = <int, int>{};
  final Map<int, void Function()> _completionByPlayback =
      <int, void Function()>{};
  bool _disposed = false;

  @override
  Future<void> play(
    AudioPlayRequest request, {
    void Function()? onComplete,
  }) async {
    if (_disposed) {
      throw StateError('The macOS audio backend is disposed.');
    }
    final int? replaced = _playbackByChannel[request.channelId];
    if (replaced != null) {
      _completionByPlayback.remove(replaced);
    }
    _playbackByChannel[request.channelId] = request.playbackId;
    if (onComplete != null) {
      _completionByPlayback[request.playbackId] = onComplete;
    }
    try {
      await _channel.invokeMethod<void>('play', <String, Object>{
        'channelId': request.channelId,
        'playbackId': request.playbackId,
        'wavBytes': request.wavBytes,
        'volume': request.volume,
        'pan': request.pan,
      });
    } on Object {
      if (_playbackByChannel[request.channelId] == request.playbackId) {
        _playbackByChannel.remove(request.channelId);
      }
      _completionByPlayback.remove(request.playbackId);
      rethrow;
    }
  }

  @override
  Future<void> stop(int channelId) async {
    final int? playbackId = _playbackByChannel.remove(channelId);
    if (playbackId != null) {
      _completionByPlayback.remove(playbackId);
    }
    if (!_disposed) {
      await _channel.invokeMethod<void>('stop', <String, Object>{
        'channelId': channelId,
      });
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playbackByChannel.clear();
    _completionByPlayback.clear();
    await _channel.invokeMethod<void>('dispose');
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'playbackComplete') {
      throw MissingPluginException('Unknown audio callback ${call.method}');
    }
    final Object? arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) return;
    final Object? channelValue = arguments['channelId'];
    final Object? playbackValue = arguments['playbackId'];
    if (channelValue is! int || playbackValue is! int) return;
    if (_playbackByChannel[channelValue] != playbackValue) return;
    _playbackByChannel.remove(channelValue);
    _completionByPlayback.remove(playbackValue)?.call();
  }
}
