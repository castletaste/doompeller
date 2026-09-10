import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doompeller/game/audio_session.dart';
import 'package:doompeller/game/sound_playback.dart';
import 'package:doompeller/game/web_audio_session.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

void main() => runApp(const _HarnessApp());

final class _HarnessApp extends StatelessWidget {
  const _HarnessApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Doompeller production audio QA',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const _HarnessPage(),
  );
}

final class _HarnessPage extends StatefulWidget {
  const _HarnessPage();

  @override
  State<_HarnessPage> createState() => _HarnessPageState();
}

final class _HarnessPageState extends State<_HarnessPage> {
  late final WebAudioSession _session;
  late MusicAudioBackend _backend;
  late final Uint8List _mus;
  late final Uint8List _genMidi;
  late final PcmSound _effect;
  Timer? _refresh;
  int _nextPlayback = 1;
  int _effectStarts = 0;
  int _effectCompletions = 0;
  bool _paused = false;
  final List<String> _actions = <String>[];

  @override
  void initState() {
    super.initState();
    _mus = _buildMus();
    _genMidi = _buildGenMidi();
    _effect = _buildEffect();
    _session = WebAudioSession();
    _backend = _session.acquireLevel() as MusicAudioBackend;
    _backend.playMusic(track: 'QA_AUTO', mus: _mus, genMidi: _genMidi);
    unawaited(_playEffect('pre-unlock'));
    _log(
      'Auto music queued; pre-unlock SFX submitted and must complete silently.',
    );
    _refresh = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (timer.tick % 8 == 0) {
        debugPrint('doompeller-audio-harness: ${jsonEncode(_diagnostics)}');
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    unawaited(_backend.dispose());
    _session.dispose();
    super.dispose();
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 23);
    _actions.insert(0, '$timestamp  $message');
    if (_actions.length > 12) _actions.removeLast();
    if (mounted) setState(() {});
  }

  Future<void> _playEffect(String label) async {
    final int playback = _nextPlayback++;
    _effectStarts++;
    await _backend.play(
      AudioPlayRequest(
        channelId: playback % 8,
        playbackId: playback,
        soundId: 'QA_EFFECT',
        wavBytes: Uint8List(0),
        pcmSound: _effect,
        volume: 0.65,
        pan: playback.isEven ? -0.65 : 0.65,
        sourceId: playback,
        fromPlayer: false,
      ),
      onComplete: () {
        _effectCompletions++;
        if (mounted) setState(() {});
      },
    );
    _log('SFX submitted: $label (#$playback).');
  }

  void _start() {
    _backend.playMusic(track: 'QA_START', mus: _mus, genMidi: _genMidi);
    unawaited(_playEffect('start'));
    _log('Start: trusted gesture, music and SFX requested.');
  }

  void _stressReplacements() {
    for (var index = 0; index < 100; index++) {
      _backend.playMusic(
        track: 'QA_REPLACE_$index',
        mus: _mus,
        genMidi: _genMidi,
      );
    }
    _log('100 synchronous replacements requested; admission must coalesce.');
  }

  void _togglePause() {
    _paused = !_paused;
    _backend.setPaused(_paused);
    _log(_paused ? 'Paused; SFX dropped, music queue frozen.' : 'Resumed.');
    setState(() {});
  }

  void _stall(Duration duration) {
    final Stopwatch stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < duration) {
      // Deliberately block only this harness's main thread.
    }
    _log('Main thread stalled for ${duration.inMilliseconds} ms.');
  }

  void _invalidMusicThenEffect() {
    _backend.playMusic(
      track: 'QA_INVALID',
      mus: Uint8List.fromList(<int>[0, 1, 2, 3]),
      genMidi: _genMidi,
    );
    Timer(const Duration(milliseconds: 300), () {
      if (mounted) unawaited(_playEffect('after invalid MUS'));
    });
    _log('Invalid MUS requested; music should fail and SFX should survive.');
  }

  void _focusCycle() {
    _backend.setFocused(false);
    unawaited(_playEffect('while lifecycle-unfocused'));
    Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      _backend.setFocused(true);
      unawaited(_playEffect('after lifecycle focus restore'));
      _log('Lifecycle focus restored after one second.');
    });
    _log('Lifecycle focus false; audio context should suspend.');
  }

  Future<void> _staleLease() async {
    final AudioBackend stale = _backend;
    final current = _session.acquireLevel() as MusicAudioBackend;
    _backend = current;
    current.playMusic(track: 'QA_SUCCESSOR', mus: _mus, genMidi: _genMidi);
    await stale.dispose();
    await _playEffect('after stale lease dispose');
    _log('Disposed stale lease after successor acquisition.');
  }

  void _crashWorker() {
    _session.debugCrashMusicWorker();
    Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_playEffect('after worker crash'));
    });
    _log('Requested a real uncaught worker error; SFX should survive.');
  }

  Future<void> _disposeAudio() async {
    await _backend.dispose();
    _session.dispose();
    _log('Session disposed; pending autoplay promises must not block.');
  }

  Map<String, Object?> get _diagnostics => <String, Object?>{
    ..._session.diagnostics.toJson(),
    'effectStarts': _effectStarts,
    'effectCompletions': _effectCompletions,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Production web audio QA')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            'Before the first click, contextState must be suspended and the '
            'pre-unlock effect must already be completed without playback.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                key: const Key('start'),
                onPressed: _start,
                child: const Text('START'),
              ),
              FilledButton(
                key: const Key('stress'),
                onPressed: _stressReplacements,
                child: const Text('100 REPLACEMENTS'),
              ),
              FilledButton(
                key: const Key('pause'),
                onPressed: _togglePause,
                child: Text(_paused ? 'RESUME' : 'PAUSE'),
              ),
              FilledButton(
                key: const Key('stall-500'),
                onPressed: () => _stall(const Duration(milliseconds: 500)),
                child: const Text('STALL 500 MS'),
              ),
              FilledButton(
                key: const Key('stall-2000'),
                onPressed: () => _stall(const Duration(seconds: 2)),
                child: const Text('STALL 2 S'),
              ),
              FilledButton(
                key: const Key('bad-mus'),
                onPressed: _invalidMusicThenEffect,
                child: const Text('BAD MUS + SFX'),
              ),
              FilledButton(
                key: const Key('focus'),
                onPressed: _focusCycle,
                child: const Text('FOCUS CYCLE'),
              ),
              FilledButton(
                key: const Key('stale'),
                onPressed: _staleLease,
                child: const Text('STALE LEASE'),
              ),
              FilledButton(
                key: const Key('crash'),
                onPressed: _crashWorker,
                child: const Text('CRASH WORKER'),
              ),
              FilledButton(
                key: const Key('dispose'),
                onPressed: _disposeAudio,
                child: const Text('DISPOSE'),
              ),
              OutlinedButton(
                key: const Key('reload'),
                onPressed: () => web.window.location.reload(),
                child: const Text('RELOAD'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            const JsonEncoder.withIndent('  ').convert(_diagnostics),
            key: const Key('diagnostics'),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 16),
          for (final action in _actions) Text(action),
        ],
      ),
    );
  }
}

PcmSound _buildEffect() {
  const int sampleRate = 11025;
  final pcm = Uint8List(sampleRate);
  for (var index = 0; index < pcm.length; index++) {
    final double fade = 1 - index / pcm.length;
    final double wave = math.sin(index * math.pi * 2 * 330 / sampleRate);
    pcm[index] = (128 + wave * fade * 70).round().clamp(0, 255);
  }
  return PcmSound(sampleRate: sampleRate, pcm: pcm);
}

Uint8List _buildMus() {
  final score = <int>[
    0x40,
    0x00,
    0x00,
    0x90,
    0xbc,
    100,
    70,
    0x80,
    60,
    70,
    0x60,
  ];
  final bytes = Uint8List(16 + score.length);
  bytes.setRange(0, 4, <int>[0x4d, 0x55, 0x53, 0x1a]);
  final data = ByteData.sublistView(bytes);
  data.setUint16(4, score.length, Endian.little);
  data.setUint16(6, 16, Endian.little);
  data.setUint16(8, 1, Endian.little);
  bytes.setRange(16, bytes.length, score);
  return bytes;
}

Uint8List _buildGenMidi() {
  const int instrumentCount = 175;
  const int instrumentBytes = 36;
  const int headerBytes = 8;
  const int nameBytes = 32;
  final bytes = Uint8List(
    headerBytes + instrumentCount * (instrumentBytes + nameBytes),
  );
  bytes.setRange(0, headerBytes, '#OPL_II#'.codeUnits);
  for (var instrument = 0; instrument < instrumentCount; instrument++) {
    final int base = headerBytes + instrument * instrumentBytes;
    bytes[base + 2] = 128;
    for (var voice = 0; voice < 2; voice++) {
      final int offset = base + 4 + voice * 16;
      bytes.setRange(offset, offset + 6, <int>[0x21, 0xf2, 0x74, 0, 0, 0x20]);
      bytes[offset + 6] = 0x06;
      bytes.setRange(offset + 7, offset + 13, <int>[0x21, 0xf2, 0x74, 0, 0, 0]);
    }
  }
  return bytes;
}
