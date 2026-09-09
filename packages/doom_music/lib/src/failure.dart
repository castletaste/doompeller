/// Invalid or unsupported music synthesis input.
sealed class MusicFailure implements Exception {
  const MusicFailure(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class MusicFormatFailure extends MusicFailure {
  const MusicFormatFailure(super.message);
}

final class MusicUnsupportedFailure extends MusicFailure {
  const MusicUnsupportedFailure(super.message);
}
