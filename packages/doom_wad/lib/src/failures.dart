/// Typed failures for every stage of WAD ingestion.
///
/// Nothing in this package throws untyped errors on hostile input: malformed
/// bytes, truncated lumps and oversized structures all surface as one of these.
sealed class DoomFailure implements Exception {
  const DoomFailure(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The bytes are structurally invalid for the format being read.
class DoomFormatFailure extends DoomFailure {
  const DoomFormatFailure(super.message);
}

/// The input is well formed but exceeds a configured budget in [DoomLimits].
class DoomLimitFailure extends DoomFailure {
  const DoomLimitFailure(
    super.message, {
    required this.limitName,
    required this.limit,
  });

  final String limitName;
  final int limit;
}

/// A lump required to continue was not present in the loaded WAD set.
class DoomMissingLumpFailure extends DoomFailure {
  const DoomMissingLumpFailure(this.lumpName) : super('missing lump $lumpName');

  final String lumpName;
}

/// Raised when a map exists but is missing mandatory sub-lumps.
class DoomMapFailure extends DoomFailure {
  const DoomMapFailure(super.message);
}
