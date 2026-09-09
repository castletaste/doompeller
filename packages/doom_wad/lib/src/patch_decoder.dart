import 'dart:typed_data';

import 'failures.dart';
import 'limits.dart';
import 'resources_model.dart';

/// Post terminator in the column-post patch encoding.
const int kPatchPostEnd = 0xFF;

/// Decodes a Doom patch lump into a row-major [PatchImage].
///
/// The on-disk layout is a header, then one 32-bit file offset per column,
/// then each column as a chain of posts: a topdelta byte, a length byte, a
/// pad byte, the pixels, and a trailing pad byte. A topdelta of 0xFF ends the
/// column.
///
/// Two vanilla quirks are handled:
///
///  * Tall patches. The topdelta byte cannot address rows past 254, so patches
///    taller than that encode later posts as deltas relative to the previous
///    post: whenever a topdelta is not greater than the previous absolute top,
///    it is added to it instead of replacing it. Patches under 255 rows have
///    strictly increasing topdeltas and are unaffected.
///  * Posts that run past the declared height. Vanilla clips them; rows
///    outside the image are dropped rather than treated as corruption.
///
/// Throws [DoomFormatFailure] on a structurally invalid lump.
PatchImage decodeDoomPatch(
  Uint8List lump, {
  String? name,
  DoomLimits limits = DoomLimits.defaults,
}) {
  final String label = name ?? 'patch';
  final int length = lump.lengthInBytes;
  if (length < 8) {
    throw DoomFormatFailure(
      '$label: only $length bytes, too short for a patch header',
    );
  }
  final ByteData data = ByteData.sublistView(lump);
  final int width = data.getInt16(0, Endian.little);
  final int height = data.getInt16(2, Endian.little);
  final int leftOffset = data.getInt16(4, Endian.little);
  final int topOffset = data.getInt16(6, Endian.little);

  if (width <= 0 || height <= 0) {
    throw DoomFormatFailure('$label: bad dimensions ${width}x$height');
  }
  DoomLimits.check(
    width * height,
    limits.maxCompositePixels,
    'maxCompositePixels',
  );

  final int tableEnd = 8 + width * 4;
  if (tableEnd > length) {
    throw DoomFormatFailure(
      '$label: column table needs $tableEnd bytes but the lump is $length',
    );
  }

  final Uint8List indices = Uint8List(width * height);
  final Uint8List coverage = Uint8List(width * height);

  for (var x = 0; x < width; x++) {
    final int columnStart = data.getInt32(8 + x * 4, Endian.little);
    if (columnStart < 0 || columnStart >= length) {
      throw DoomFormatFailure(
        '$label: column $x points to $columnStart, outside the $length byte lump',
      );
    }
    var cursor = columnStart;
    var top = -1;
    while (true) {
      if (cursor >= length) {
        throw DoomFormatFailure(
          '$label: column $x runs past the end of the lump',
        );
      }
      final int topDelta = lump[cursor];
      if (topDelta == kPatchPostEnd) {
        break;
      }
      if (cursor + 3 > length) {
        throw DoomFormatFailure('$label: truncated post header in column $x');
      }
      final int postLength = lump[cursor + 1];
      // Tall-patch rule: a non-increasing topdelta continues the previous post.
      top = topDelta <= top ? top + topDelta : topDelta;
      final int pixels = cursor + 3;
      final int postEnd = pixels + postLength + 1;
      if (postEnd > length) {
        throw DoomFormatFailure(
          '$label: post in column $x ends at $postEnd, past the $length byte lump',
        );
      }
      // Clip to the declared height instead of rejecting overlong posts.
      var first = 0;
      if (top < 0) {
        first = -top;
      }
      var last = postLength;
      if (top + last > height) {
        last = height - top;
      }
      for (var i = first; i < last; i++) {
        final int target = (top + i) * width + x;
        indices[target] = lump[pixels + i];
        coverage[target] = 255;
      }
      cursor = postEnd;
    }
  }

  return PatchImage(
    width: width,
    height: height,
    leftOffset: leftOffset,
    topOffset: topOffset,
    indices: indices,
    coverage: coverage,
  );
}
