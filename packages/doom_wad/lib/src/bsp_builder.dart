import 'dart:math' as math;

/// A deterministic binary space partition builder.
///
/// This exists so fixtures can ship a real NODES/SEGS/SSECTORS tree without
/// copying one out of a commercial WAD. The algorithm is the standard one every
/// node builder uses and is re-derived here from the published lump layout:
/// recursively choose a seg whose line divides the remaining segs, split the
/// ones that straddle it, and stop when no seg has anything behind it, which is
/// exactly the condition for a convex leaf.
///
/// Determinism matters more than tree quality here: candidates are scanned in
/// index order and ties resolve to the lowest index, so the same input always
/// produces byte-identical lumps.

/// A seg being built. Coordinates are carried directly because splitting
/// introduces points that are not yet vertices.
class BspSeg {
  const BspSeg({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.linedef,
    required this.side,
  });

  final int x1;
  final int y1;
  final int x2;
  final int y2;

  /// Index of the linedef this seg lies on.
  final int linedef;

  /// 0 when the seg runs along the linedef's front side, 1 when reversed.
  final int side;

  int get dx => x2 - x1;
  int get dy => y2 - y1;
}

/// A finished leaf: a contiguous run in the flattened seg list.
class BspSubsector {
  const BspSubsector({required this.firstSeg, required this.segCount});

  final int firstSeg;
  final int segCount;
}

/// A finished internal node.
class BspNodeOut {
  const BspNodeOut({
    required this.x,
    required this.y,
    required this.dx,
    required this.dy,
    required this.rightBox,
    required this.leftBox,
    required this.rightChild,
    required this.leftChild,
  });

  final int x;
  final int y;
  final int dx;
  final int dy;

  /// Bounding boxes as top, bottom, left, right.
  final List<int> rightBox;
  final List<int> leftBox;

  /// Raw child words; bit 0x8000 marks a subsector.
  final int rightChild;
  final int leftChild;
}

/// The result of [buildBspTree]. Nodes are in post-order, so the root is last,
/// which is the layout the NODES lump requires.
class BspTree {
  const BspTree({
    required this.segs,
    required this.subsectors,
    required this.nodes,
    required this.rootChild,
  });

  /// Segs flattened in subsector order.
  final List<BspSeg> segs;
  final List<BspSubsector> subsectors;
  final List<BspNodeOut> nodes;

  /// Raw child word for the root, for maps too small to need any node.
  final int rootChild;
}

/// Marks a child word as pointing at a subsector.
const int kBspSubsectorBit = 0x8000;

/// Builds a BSP tree over [input].
///
/// [maxDepth] bounds recursion; a region that is still not convex at the limit
/// is emitted as a leaf. That keeps a pathological input from recursing without
/// end at the cost of a slightly wrong tree, which only matters for inputs this
/// builder is never given.
BspTree buildBspTree(List<BspSeg> input, {int maxDepth = 64}) {
  final List<BspSeg> flatSegs = <BspSeg>[];
  final List<BspSubsector> subsectors = <BspSubsector>[];
  final List<BspNodeOut> nodes = <BspNodeOut>[];

  final int root = _build(input, flatSegs, subsectors, nodes, 0, maxDepth);

  return BspTree(
    segs: flatSegs,
    subsectors: subsectors,
    nodes: nodes,
    rootChild: root,
  );
}

/// Recursively partitions [segs], appending to the output lists, and returns
/// the child word for the region.
int _build(
  List<BspSeg> segs,
  List<BspSeg> flatSegs,
  List<BspSubsector> subsectors,
  List<BspNodeOut> nodes,
  int depth,
  int maxDepth,
) {
  final int partition = depth >= maxDepth ? -1 : _choosePartition(segs);
  if (partition < 0) {
    return _emitSubsector(segs, flatSegs, subsectors);
  }

  final BspSeg divider = segs[partition];
  final List<BspSeg> front = <BspSeg>[];
  final List<BspSeg> back = <BspSeg>[];
  for (final BspSeg seg in segs) {
    _partitionSeg(seg, divider, front, back);
  }

  if (front.isEmpty || back.isEmpty) {
    // The chooser promised both sides are populated; if geometry rounding broke
    // that promise, emit a leaf rather than recursing forever.
    return _emitSubsector(segs, flatSegs, subsectors);
  }

  final int rightChild = _build(
    front,
    flatSegs,
    subsectors,
    nodes,
    depth + 1,
    maxDepth,
  );
  final List<int> rightBox = _boundingBox(front);
  final int leftChild = _build(
    back,
    flatSegs,
    subsectors,
    nodes,
    depth + 1,
    maxDepth,
  );
  final List<int> leftBox = _boundingBox(back);

  nodes.add(
    BspNodeOut(
      x: divider.x1,
      y: divider.y1,
      dx: divider.dx,
      dy: divider.dy,
      rightBox: rightBox,
      leftBox: leftBox,
      rightChild: rightChild,
      leftChild: leftChild,
    ),
  );
  return nodes.length - 1;
}

int _emitSubsector(
  List<BspSeg> segs,
  List<BspSeg> flatSegs,
  List<BspSubsector> subsectors,
) {
  final int first = flatSegs.length;
  flatSegs.addAll(segs);
  subsectors.add(BspSubsector(firstSeg: first, segCount: segs.length));
  return (subsectors.length - 1) | kBspSubsectorBit;
}

/// Which side of [divider] the point lies on: positive front, negative back.
///
/// The front of a line running in direction (dx, dy) is the half-plane the
/// vector (dy, -dx) points into, which is the right-hand side when facing
/// along the line. That matches how sidedefs are wound.
int _pointSide(int x, int y, BspSeg divider) =>
    (x - divider.x1) * divider.dy - (y - divider.y1) * divider.dx;

/// Picks the seg that best divides [segs], or -1 when the set is convex.
///
/// A set is convex exactly when no seg lies even partly behind another seg's
/// line, so "no candidate has anything behind it" is the stopping condition.
int _choosePartition(List<BspSeg> segs) {
  var best = -1;
  var bestCost = 0;
  for (var i = 0; i < segs.length; i++) {
    final BspSeg candidate = segs[i];
    if (candidate.dx == 0 && candidate.dy == 0) {
      continue;
    }
    var front = 0;
    var back = 0;
    var splits = 0;
    for (var j = 0; j < segs.length; j++) {
      if (i == j) {
        front++;
        continue;
      }
      switch (_classify(segs[j], candidate)) {
        case _Side.front:
          front++;
        case _Side.back:
          back++;
        case _Side.split:
          splits++;
      }
    }
    if (back + splits == 0) {
      continue;
    }
    // Splitting a seg costs geometry and lump space, so weight it heavily;
    // the balance term breaks ties toward an even tree.
    final int cost = splits * 8 + (front - back).abs();
    if (best < 0 || cost < bestCost) {
      best = i;
      bestCost = cost;
    }
  }
  return best;
}

enum _Side { front, back, split }

_Side _classify(BspSeg seg, BspSeg divider) {
  final int a = _pointSide(seg.x1, seg.y1, divider);
  final int b = _pointSide(seg.x2, seg.y2, divider);
  if (a == 0 && b == 0) {
    // Collinear: the direction decides, which is what separates the two segs
    // of a two-sided linedef.
    final int dot = seg.dx * divider.dx + seg.dy * divider.dy;
    return dot >= 0 ? _Side.front : _Side.back;
  }
  if (a >= 0 && b >= 0) {
    return _Side.front;
  }
  if (a <= 0 && b <= 0) {
    return _Side.back;
  }
  return _Side.split;
}

void _partitionSeg(
  BspSeg seg,
  BspSeg divider,
  List<BspSeg> front,
  List<BspSeg> back,
) {
  switch (_classify(seg, divider)) {
    case _Side.front:
      front.add(seg);
    case _Side.back:
      back.add(seg);
    case _Side.split:
      final List<int> hit = _intersection(seg, divider);
      final BspSeg first = BspSeg(
        x1: seg.x1,
        y1: seg.y1,
        x2: hit[0],
        y2: hit[1],
        linedef: seg.linedef,
        side: seg.side,
      );
      final BspSeg second = BspSeg(
        x1: hit[0],
        y1: hit[1],
        x2: seg.x2,
        y2: seg.y2,
        linedef: seg.linedef,
        side: seg.side,
      );
      // A zero-length half means the split landed on an endpoint; keep only the
      // real piece so no degenerate seg reaches the lump.
      final bool firstDegenerate = first.x1 == first.x2 && first.y1 == first.y2;
      final bool secondDegenerate =
          second.x1 == second.x2 && second.y1 == second.y2;
      if (firstDegenerate || secondDegenerate) {
        final BspSeg whole = firstDegenerate ? second : first;
        if (_pointSide(seg.x1, seg.y1, divider) +
                _pointSide(seg.x2, seg.y2, divider) >=
            0) {
          front.add(whole);
        } else {
          back.add(whole);
        }
        return;
      }
      if (_pointSide(seg.x1, seg.y1, divider) > 0) {
        front.add(first);
        back.add(second);
      } else {
        back.add(first);
        front.add(second);
      }
  }
}

/// Where [seg] crosses the infinite line of [divider], as integer coordinates.
///
/// Axis-aligned dividers are handled exactly, which covers every split the
/// fixture map produces; anything else falls back to rounding the parametric
/// solution, which is deterministic under IEEE arithmetic.
List<int> _intersection(BspSeg seg, BspSeg divider) {
  if (divider.dx == 0) {
    final int x = divider.x1;
    if (seg.dx == 0) {
      return <int>[x, seg.y1];
    }
    final int y = seg.y1 + ((x - seg.x1) * seg.dy) ~/ seg.dx;
    return <int>[x, y];
  }
  if (divider.dy == 0) {
    final int y = divider.y1;
    if (seg.dy == 0) {
      return <int>[seg.x1, y];
    }
    final int x = seg.x1 + ((y - seg.y1) * seg.dx) ~/ seg.dy;
    return <int>[x, y];
  }
  final int a = _pointSide(seg.x1, seg.y1, divider);
  final int b = _pointSide(seg.x2, seg.y2, divider);
  final double t = a / (a - b);
  return <int>[(seg.x1 + t * seg.dx).round(), (seg.y1 + t * seg.dy).round()];
}

/// Bounding box of [segs] as top, bottom, left, right.
List<int> _boundingBox(List<BspSeg> segs) {
  var top = -2147483648;
  var bottom = 2147483647;
  var left = 2147483647;
  var right = -2147483648;
  for (final BspSeg seg in segs) {
    top = math.max(top, math.max(seg.y1, seg.y2));
    bottom = math.min(bottom, math.min(seg.y1, seg.y2));
    left = math.min(left, math.min(seg.x1, seg.x2));
    right = math.max(right, math.max(seg.x1, seg.x2));
  }
  if (segs.isEmpty) {
    return <int>[0, 0, 0, 0];
  }
  return <int>[top, bottom, left, right];
}

/// Binary angle measure of the direction (dx, dy): a full turn is 65536.
int bamAngle(int dx, int dy) {
  final double radians = math.atan2(dy.toDouble(), dx.toDouble());
  return (radians * 32768.0 / math.pi).round() & 0xFFFF;
}

/// Rounded Euclidean distance, used for seg offsets along a linedef.
int distanceBetween(int x1, int y1, int x2, int y2) {
  final int dx = x2 - x1;
  final int dy = y2 - y1;
  return math.sqrt((dx * dx + dy * dy).toDouble()).round();
}
