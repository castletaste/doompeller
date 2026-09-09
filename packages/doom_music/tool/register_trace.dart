import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doom_music/doom_music.dart';
import 'package:doom_wad/doom_wad.dart';

void main(List<String> arguments) {
  final Map<String, String> options = _options(arguments);
  final String? wadPath = options['wad'];
  final String? songPath = options['song-file'];
  final String? lumpName = options['lump'];
  final String? outputPath = options['output'];
  final int? frames = int.tryParse(options['frames'] ?? '');
  if (wadPath == null ||
      (songPath == null) == (lumpName == null) ||
      outputPath == null ||
      frames == null) {
    stderr.writeln(
      'usage: dart run tool/register_trace.dart '
      '--wad FILE (--song-file FILE | --lump NAME) --frames N --output FILE',
    );
    exitCode = 64;
    return;
  }
  if (frames < 0 || frames > 20 * 1000 * 1000) {
    throw const MusicFormatFailure('frames must be in 0..20000000');
  }

  final WadSet wad = WadSet.of(
    WadFile.parse(Uint8List.fromList(File(wadPath).readAsBytesSync())),
  );
  final GenMidiBank bank = parseGenMidi(wad.require('GENMIDI'));
  final MusSong song = parseMus(
    songPath == null
        ? wad.require(lumpName!)
        : Uint8List.fromList(File(songPath).readAsBytesSync()),
  );
  final List<Map<String, int>> writes = <Map<String, int>>[];
  final DoomMusicPlayer player = DoomMusicPlayer(
    song,
    bank,
    loop: true,
    onRegisterWrite: (int sample, int address, int value) {
      writes.add(<String, int>{
        'sample': sample,
        'address': address,
        'value': value,
      });
    },
  );
  const int chunkFrames = 8192;
  final Float32List scratch = Float32List(chunkFrames);
  var remaining = frames;
  while (remaining > 0) {
    final int count = remaining < chunkFrames ? remaining : chunkFrames;
    player.renderInto(scratch, count: count);
    remaining -= count;
  }
  File(outputPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(<String, Object>{'sampleRate': DoomMusicPlayer.sampleRate, 'frameCount': frames, 'loopCount': player.loopCount, 'writes': writes})}\n',
  );
}

Map<String, String> _options(List<String> arguments) {
  final Map<String, String> result = <String, String>{};
  for (var i = 0; i < arguments.length; i += 2) {
    if (i + 1 >= arguments.length || !arguments[i].startsWith('--')) {
      return <String, String>{};
    }
    result[arguments[i].substring(2)] = arguments[i + 1];
  }
  return result;
}
