import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doom_music/src/failure.dart';
import 'package:doom_music/src/opl2.dart';

const _maxFrames = Opl2Chip.sampleRate * 300;
const _maxWrites = 1000000;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: dart run tool/opl2_oracle_runner.dart TRACE OUTPUT');
    exitCode = 64;
    return;
  }

  final decoded = jsonDecode(await File(arguments[0]).readAsString());
  if (decoded is! Map<String, Object?>) {
    throw const MusicFormatFailure('trace root must be an object');
  }
  final sampleRate = _unsigned(decoded['sampleRate'], 'sampleRate');
  final frameCount = _unsigned(decoded['frameCount'], 'frameCount');
  if (sampleRate != Opl2Chip.sampleRate) {
    throw MusicUnsupportedFailure(
      'trace sample rate $sampleRate is not native',
    );
  }
  if (frameCount > _maxFrames) {
    throw const MusicFormatFailure('trace frame budget exceeded');
  }
  final rawWrites = decoded['writes'];
  if (rawWrites is! List<Object?> || rawWrites.length > _maxWrites) {
    throw const MusicFormatFailure('invalid or oversized trace writes');
  }

  final writes = <_Write>[];
  var previousSample = 0;
  for (var index = 0; index < rawWrites.length; index++) {
    final value = rawWrites[index];
    if (value is! Map<String, Object?>) {
      throw MusicFormatFailure('write $index is not an object');
    }
    final sample = _unsigned(value['sample'], 'write sample');
    final address = _unsigned(value['address'], 'write address');
    final registerValue = _unsigned(value['value'], 'write value');
    if (sample >= frameCount ||
        sample < previousSample ||
        address > 255 ||
        registerValue > 255) {
      throw MusicFormatFailure('write $index is outside trace bounds');
    }
    writes.add(_Write(sample, address, registerValue));
    previousSample = sample;
  }

  final chip = Opl2Chip();
  final pcm = Float32List(frameCount);
  var cursor = 0;
  var writeIndex = 0;
  while (cursor < frameCount) {
    while (writeIndex < writes.length && writes[writeIndex].sample == cursor) {
      final write = writes[writeIndex++];
      chip.writeRegister(write.address, write.value);
    }
    final nextWrite = writeIndex < writes.length
        ? writes[writeIndex].sample
        : frameCount;
    chip.renderInto(pcm, offset: cursor, count: nextWrite - cursor);
    cursor = nextWrite;
  }

  final bytes = ByteData(frameCount * 2);
  for (var frame = 0; frame < frameCount; frame++) {
    final sample = (pcm[frame] * 32768.0).round().clamp(-32768, 32767);
    bytes.setInt16(frame * 2, sample, Endian.little);
  }
  await File(
    arguments[1],
  ).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
}

int _unsigned(Object? value, String label) {
  if (value is! int || value < 0) {
    throw MusicFormatFailure('$label must be an unsigned integer');
  }
  return value;
}

final class _Write {
  const _Write(this.sample, this.address, this.value);

  final int sample;
  final int address;
  final int value;
}
