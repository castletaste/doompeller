/// Stable 32-bit FNV-1a identity for a replay-visible semantic name.
///
/// Unlike an enum index or table cursor, this value does not change when an
/// unrelated entry is inserted into the declaring collection.
int stableReplayIdentity(String name) {
  var hash = 0x811c9dc5;
  for (final int unit in name.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash;
}
