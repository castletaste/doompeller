import 'failures.dart';

/// Hard budgets applied to untrusted WAD input.
///
/// Every parser stage checks against these before allocating. The defaults are
/// generous for commercial IWADs and large community maps but still bound the
/// worst case, so a hostile file cannot exhaust memory or wedge the app.
class DoomLimits {
  const DoomLimits({
    this.maxWadBytes = 256 * 1024 * 1024,
    this.maxLumpCount = 65536,
    this.maxLumpBytes = 64 * 1024 * 1024,
    this.maxVertices = 65535,
    this.maxLinedefs = 65535,
    this.maxSidedefs = 65535,
    this.maxSectors = 65535,
    this.maxSegs = 65535,
    this.maxSubsectors = 65535,
    this.maxNodes = 65535,
    this.maxThings = 32767,
    this.maxTextures = 8192,
    this.maxPatchesPerTexture = 256,
    this.maxPatchNames = 8192,
    this.maxCompositePixels = 4096 * 4096,
    this.maxBlockmapCells = 1024 * 1024,
    this.maxBlockmapEntries = 2 * 1024 * 1024,
    this.maxIntersectionChecks = 1000000,
    this.maxTriangles = 2000000,
    this.maxAtlasPixels = 4096 * 4096,
    this.maxSoundSamples = 16 * 1024 * 1024,
    this.maxSoundSampleRate = 48000,
  });

  static const DoomLimits defaults = DoomLimits();

  final int maxWadBytes;
  final int maxLumpCount;
  final int maxLumpBytes;
  final int maxVertices;
  final int maxLinedefs;
  final int maxSidedefs;
  final int maxSectors;
  final int maxSegs;
  final int maxSubsectors;
  final int maxNodes;
  final int maxThings;
  final int maxTextures;
  final int maxPatchesPerTexture;
  final int maxPatchNames;
  final int maxCompositePixels;

  /// Maximum number of cells allocated for a map BLOCKMAP. The vanilla
  /// dimensions are unsigned 16-bit words, so checking this before multiplying
  /// or allocating prevents a hostile offset table from exhausting memory.
  final int maxBlockmapCells;

  /// Maximum number of words in all BLOCKMAP cell lists (including each
  /// cell's optional pad and terminator). This bounds the proportional scan
  /// and the temporary list used while decoding a cell.
  final int maxBlockmapEntries;

  /// Budget for quadratic geometric validation work. Without this a crafted
  /// sector can make loop validation run effectively forever.
  final int maxIntersectionChecks;
  final int maxTriangles;
  final int maxAtlasPixels;

  /// Maximum decoded PCM bytes in one DMX sound lump. This is checked against
  /// the declared count before a destination buffer is allocated.
  final int maxSoundSamples;

  /// Highest accepted sample rate for an unsigned 8-bit DMX sound.
  final int maxSoundSampleRate;

  /// Throws [DoomLimitFailure] when [value] exceeds [limit].
  static void check(int value, int limit, String limitName) {
    if (value > limit) {
      throw DoomLimitFailure(
        '$limitName: $value exceeds limit $limit',
        limitName: limitName,
        limit: limit,
      );
    }
  }
}
