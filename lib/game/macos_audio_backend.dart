import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sound_playback.dart';

/// In-memory MethodChannel transport for the macOS AVAudioEngine backend.
final class MacOsAudioBackend implements AudioBackend {
  MacOsAudioBackend({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    final owners = _owners[_channel.binaryMessenger] ??= {};
    final previous = owners[_channel.name]?.target;
    if (previous != null) {
      // Retire all native voices before publishing the next owner. Dispose
      // dispatches synchronously, so MethodChannel FIFO keeps that cleanup
      // ahead of this owner's first play even when its reply is delayed.
      unawaited(
        previous.dispose().catchError((Object error, StackTrace stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'Doom audio',
              context: ErrorDescription('while retiring the previous owner'),
            ),
          );
        }),
      );
    }
    final WeakReference<MacOsAudioBackend> backend = WeakReference(this);
    owners[_channel.name] = backend;
    _channel.setMethodCallHandler((MethodCall call) async {
      await backend.target?._handleNativeCall(call);
    });
  }

  static const String channelName = 'dev.castletaste.doompeller/audio';

  // A native engine belongs to a messenger/channel pair, not a Dart wrapper.
  // Weak keys and values avoid retaining retired engines or runtime callbacks.
  static final _owners =
      Expando<Map<String, WeakReference<MacOsAudioBackend>>>();
  static int _nextTransportPlaybackId = 0;

  final MethodChannel _channel;
  final Map<int, int> _playbackByChannel = <int, int>{};
  final Map<int, void Function()> _completionByPlayback =
      <int, void Function()>{};
  bool _disposed = false;

  bool get _ownsTransport =>
      !_disposed &&
      identical(
        _owners[_channel.binaryMessenger]?[_channel.name]?.target,
        this,
      );

  @override
  Future<void> play(
    AudioPlayRequest request, {
    void Function()? onComplete,
  }) async {
    if (!_ownsTransport) return;
    final int transportId = _nextTransportPlaybackId++;
    final int? replaced = _playbackByChannel[request.channelId];
    if (replaced != null) {
      _completionByPlayback.remove(replaced);
    }
    _playbackByChannel[request.channelId] = transportId;
    if (onComplete != null) {
      _completionByPlayback[transportId] = onComplete;
    }
    try {
      await _channel.invokeMethod<void>('play', <String, Object>{
        'channelId': request.channelId,
        'playbackId': transportId,
        'wavBytes': request.wavBytes,
        'volume': request.volume,
        'pan': request.pan,
      });
    } on Object {
      if (_playbackByChannel[request.channelId] == transportId) {
        _playbackByChannel.remove(request.channelId);
      }
      _completionByPlayback.remove(transportId);
      rethrow;
    }
  }

  @override
  Future<void> stop(int channelId) async {
    final int? playbackId = _playbackByChannel.remove(channelId);
    if (playbackId != null) {
      _completionByPlayback.remove(playbackId);
    }
    if (_ownsTransport) {
      await _channel.invokeMethod<void>('stop', <String, Object>{
        'channelId': channelId,
      });
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    final ownsTransport = _ownsTransport;
    _disposed = true;
    _playbackByChannel.clear();
    _completionByPlayback.clear();
    if (ownsTransport) {
      _owners[_channel.binaryMessenger]?.remove(_channel.name);
      _channel.setMethodCallHandler(null);
      // No await precedes dispatch. Flutter's MethodChannel FIFO ordering keeps
      // this teardown ahead of commands issued by a subsequently created owner.
      await _channel.invokeMethod<void>('dispose');
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (!_ownsTransport) return;
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
