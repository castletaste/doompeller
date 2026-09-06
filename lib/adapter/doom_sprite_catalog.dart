import 'dart:math' as math;

/// One exact WAD sprite lump selected for a frame and view rotation.
final class DoomSpriteSelection {
  const DoomSpriteSelection({required this.lumpName, required this.mirrored});

  final String lumpName;
  final bool mirrored;
}

/// Pure resolver for Doom sprite lump naming.
///
/// A lump begins with a four-character actor/weapon prefix followed by one or
/// two frame/rotation pairs: `TROOA1` or `TROOA2A8`. The second pair shares the
/// pixels of the first and is drawn mirrored. Rotation 0 is camera-invariant.
final class DoomSpriteCatalog {
  DoomSpriteCatalog(Iterable<String> lumpNames) {
    for (final rawName in lumpNames) {
      final name = rawName.toUpperCase();
      if (name.length != 6 && name.length != 8) {
        continue;
      }
      _addPair(name, name.substring(4, 6), mirrored: false);
      if (name.length == 8) {
        _addPair(name, name.substring(6, 8), mirrored: true);
      }
    }
  }

  final Map<(String, String, int), DoomSpriteSelection> _selections = {};
  final Set<String> _lumpNames = {};

  Iterable<String> get lumpNames => _lumpNames;

  DoomSpriteSelection? resolve({
    required String prefix,
    required int frame,
    required int rotation,
  }) {
    if (frame < 0 || frame >= 26) {
      throw RangeError.range(frame, 0, 25, 'frame');
    }
    if (rotation < 0 || rotation > 8) {
      throw RangeError.range(rotation, 0, 8, 'rotation');
    }
    final keyPrefix = prefix.toUpperCase();
    if (keyPrefix.length != 4) {
      throw ArgumentError.value(prefix, 'prefix', 'must be four characters');
    }
    final frameName = String.fromCharCode(65 + frame);
    return _selections[(keyPrefix, frameName, rotation)] ??
        _selections[(keyPrefix, frameName, 0)];
  }

  DoomSpriteSelection? exact(String lumpName) {
    final name = lumpName.toUpperCase();
    return _lumpNames.contains(name)
        ? DoomSpriteSelection(lumpName: name, mirrored: false)
        : null;
  }

  /// Quantizes the actor-to-camera bearing relative to [actorAngle] into
  /// classic rotations 1..8. Angles are radians around world Y.
  static int cameraRotation({
    required double actorAngle,
    required double actorX,
    required double actorZ,
    required double cameraX,
    required double cameraZ,
  }) {
    final bearing = math.atan2(cameraX - actorX, cameraZ - actorZ);
    final relative = _wrap(bearing - actorAngle);
    return ((relative + math.pi / 8) / (math.pi / 4)).floor() % 8 + 1;
  }

  void _addPair(String lumpName, String pair, {required bool mirrored}) {
    final frame = pair.codeUnitAt(0);
    final rotation = pair.codeUnitAt(1) - 48;
    if (frame < 65 || frame > 90 || rotation < 0 || rotation > 8) {
      return;
    }
    final prefix = lumpName.substring(0, 4);
    _lumpNames.add(lumpName);
    _selections.putIfAbsent((
      prefix,
      String.fromCharCode(frame),
      rotation,
    ), () => DoomSpriteSelection(lumpName: lumpName, mirrored: mirrored));
  }

  static double _wrap(double angle) {
    final turn = math.pi * 2;
    var result = angle % turn;
    if (result < 0) {
      result += turn;
    }
    return result;
  }
}

/// Classic first-person weapon sprite prefixes.
abstract final class DoomWeaponSprites {
  static const String fist = 'PUNG';
  static const String pistol = 'PISG';
  static const String shotgun = 'SHTG';
  static const String chaingun = 'CHGG';
  static const String rocketLauncher = 'MISG';
  static const String chainsaw = 'SAWG';

  static const Set<String> supportedPrefixes = <String>{
    fist,
    pistol,
    shotgun,
    chaingun,
    rocketLauncher,
    chainsaw,
  };
}
