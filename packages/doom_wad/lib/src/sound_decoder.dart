import 'dart:typed_data';

import 'failures.dart';
import 'limits.dart';
import 'resources_model.dart';
import 'wad.dart';

/// Type word used by DMX digital-sound lumps.
const int kDmxDigitalSoundType = 3;

/// Guard bytes commonly duplicated around playable DMX PCM.
const int kDmxGuardSamples = 16;

/// Decodes one unsigned 8-bit mono DMX sound lump.
///
/// The declared sample count includes the common 16-byte guards. They are
/// removed only when both guards actually repeat their adjacent edge sample;
/// arbitrary short sounds therefore cannot lose legitimate data.
DoomSound decodeDoomSound(
  Uint8List lump, {
  String? name,
  DoomLimits limits = DoomLimits.defaults,
}) {
  final String key = normaliseLumpName(name ?? 'sound');
  final int length = lump.lengthInBytes;
  if (length < kDmxSoundHeaderBytes) {
    throw DoomFormatFailure(
      '$key: only $length bytes, too short for a DMX sound header',
    );
  }
  final ByteData data = ByteData.sublistView(lump);
  final int type = data.getUint16(0, Endian.little);
  if (type != kDmxDigitalSoundType) {
    throw DoomFormatFailure(
      '$key: DMX sound type is $type, expected $kDmxDigitalSoundType',
    );
  }
  final int sampleRate = data.getUint16(2, Endian.little);
  if (sampleRate == 0) {
    throw DoomFormatFailure('$key: DMX sound sample rate is zero');
  }
  DoomLimits.check(sampleRate, limits.maxSoundSampleRate, 'maxSoundSampleRate');

  final int declared = data.getUint32(4, Endian.little);
  final int available = length - kDmxSoundHeaderBytes;
  if (declared > available) {
    throw DoomFormatFailure(
      '$key: declares $declared samples but only $available bytes remain',
    );
  }
  DoomLimits.check(declared, limits.maxSoundSamples, 'maxSoundSamples');

  var start = kDmxSoundHeaderBytes;
  var count = declared;
  if (_hasDmxGuards(lump, start, count)) {
    start += kDmxGuardSamples;
    count -= kDmxGuardSamples * 2;
  }
  final Uint8List pcm = Uint8List(count);
  pcm.setRange(0, count, lump, start);
  return DoomSound(name: key, sampleRate: sampleRate, pcm: pcm);
}

bool _hasDmxGuards(Uint8List lump, int start, int count) {
  if (count <= kDmxGuardSamples * 2) return false;
  final int firstSample = lump[start + kDmxGuardSamples];
  for (var i = 0; i < kDmxGuardSamples; i++) {
    if (lump[start + i] != firstSample) return false;
  }
  final int lastSample = lump[start + count - kDmxGuardSamples - 1];
  for (var i = count - kDmxGuardSamples; i < count; i++) {
    if (lump[start + i] != lastSample) return false;
  }
  return true;
}
