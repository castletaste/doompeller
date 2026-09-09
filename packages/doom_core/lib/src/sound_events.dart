/// Where a sound originates. Consumers derive volume and stereo placement;
/// the simulation only records the deterministic cause and world position.
enum SoundOrigin { world, player, nonPositional }

/// One output-only request to play a WAD sound lump.
class SoundEvent {
  const SoundEvent({
    required this.soundId,
    required this.origin,
    required this.sourceId,
    required this.tic,
    required this.x,
    required this.y,
    required this.z,
  });

  /// Uppercase DS-prefixed WAD lump name.
  final String soundId;
  final SoundOrigin origin;

  /// Stable simulation identity of the emitter. Actor ids are positive, the
  /// player is zero, sectors are negative, and non-positional UI/world events
  /// use [nonPositionalSourceId].
  final int sourceId;

  /// Simulation tic on which the event was emitted.
  final int tic;

  /// Fixed-point world position. Non-positional events use zeroes.
  final int x;
  final int y;
  final int z;

  bool get fromPlayer => origin == SoundOrigin.player;
  bool get isPositional => origin != SoundOrigin.nonPositional;

  /// Cues retained ahead of ordinary sounds when an output queue is full.
  bool get isCritical => switch (soundId) {
    'DSDOROPN' ||
    'DSDORCLS' ||
    'DSPSTART' ||
    'DSPSTOP' ||
    'DSPODTH1' ||
    'DSSWTCHX' => true,
    _ => false,
  };

  static const int playerSourceId = 0;
  static const int nonPositionalSourceId = -0x80000000;

  static int sectorSourceId(int sectorIndex) => -sectorIndex - 1;
}
