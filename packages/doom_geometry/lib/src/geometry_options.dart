import 'wad_types.dart';

/// Tuning for [DoomGeometryCompiler].
///
/// Defaults are the production settings: BSP-first with the sector-loop oracle
/// running as a cross-check. Turning [validateAgainstLoops] off skips the
/// oracle entirely, which also disables per-sector fallback, so it is only for
/// benchmarking.
class GeometryOptions {
  const GeometryOptions({
    this.bspFirst = true,
    this.validateAgainstLoops = true,
    this.limits = DoomLimits.defaults,
    this.epsilon = 1.0 / 1024.0,
    this.weldGrid = 65536.0,
    this.maxBspDepth = 256,
    this.areaToleranceFraction = 1e-6,
    this.areaToleranceFloor = 0,
    this.atlasPageSize = 2048,
    this.spriteGutter = 1,
    this.fakeContrast = true,
    this.skyTextureName = 'SKY1',
  });

  static const GeometryOptions defaults = GeometryOptions();

  /// Reconstruct subsector polygons by clipping down the BSP (primary path).
  ///
  /// When false the compiler emits the sector-loop triangulation directly and
  /// every sector is reported as a fallback.
  final bool bspFirst;

  /// Build the independent sector-loop oracle and compare it to the BSP result.
  final bool validateAgainstLoops;

  /// Budgets for untrusted input; [DoomLimits.maxIntersectionChecks] bounds the
  /// quadratic validation work.
  final DoomLimits limits;

  /// Distance in map units under which a point counts as lying on a plane.
  ///
  /// Doom vertices are integers, so anything below half a unit is safe; the
  /// default is deliberately far smaller because clipped points are exact
  /// rationals of integer inputs.
  final double epsilon;

  /// Reciprocal of the snap grid applied to clipped coordinates.
  ///
  /// Clipping the same partition from two different subsectors must produce
  /// bit-identical points or the shared edge cracks. Snapping both to a common
  /// grid guarantees it.
  ///
  /// The differences being defended against are floating-point last-bit noise,
  /// on the order of 1e-13 map units, not real geometric disagreement. So the
  /// lattice only has to be coarser than that noise, and every unit coarser
  /// than it needs to be is area error introduced for nothing. 65536 means a
  /// 2^-16 map-unit lattice: about nine orders of magnitude above the noise
  /// floor, and fine enough that a whole level's quantisation error stays far
  /// below one square map unit. Being a power of two it is exactly
  /// representable, so the snap is lossless and identical across runs.
  final double weldGrid;

  /// Hard cap on BSP recursion; a malformed tree cannot wedge the compiler.
  final int maxBspDepth;

  /// Allowed relative area difference between the BSP and oracle results
  /// before a sector is failed and falls back.
  final double areaToleranceFraction;

  /// Absolute area slack in square map units, for very small sectors where the
  /// relative tolerance would be tighter than the snap grid.
  final double areaToleranceFloor;

  /// Edge length of one atlas page in pixels.
  final int atlasPageSize;

  /// Transparent border packed around clamped (sprite) entries.
  final int spriteGutter;

  /// Apply Doom's classic light bias: brighter for north/south walls, darker
  /// for east/west ones.
  final bool fakeContrast;

  /// Classic camera-centred sky texture packed when a sector uses F_SKY1.
  final String skyTextureName;

  GeometryOptions copyWith({
    bool? bspFirst,
    bool? validateAgainstLoops,
    DoomLimits? limits,
    double? epsilon,
    double? weldGrid,
    int? maxBspDepth,
    double? areaToleranceFraction,
    double? areaToleranceFloor,
    int? atlasPageSize,
    int? spriteGutter,
    bool? fakeContrast,
    String? skyTextureName,
  }) {
    return GeometryOptions(
      bspFirst: bspFirst ?? this.bspFirst,
      validateAgainstLoops: validateAgainstLoops ?? this.validateAgainstLoops,
      limits: limits ?? this.limits,
      epsilon: epsilon ?? this.epsilon,
      weldGrid: weldGrid ?? this.weldGrid,
      maxBspDepth: maxBspDepth ?? this.maxBspDepth,
      areaToleranceFraction:
          areaToleranceFraction ?? this.areaToleranceFraction,
      areaToleranceFloor: areaToleranceFloor ?? this.areaToleranceFloor,
      atlasPageSize: atlasPageSize ?? this.atlasPageSize,
      spriteGutter: spriteGutter ?? this.spriteGutter,
      fakeContrast: fakeContrast ?? this.fakeContrast,
      skyTextureName: skyTextureName ?? this.skyTextureName,
    );
  }
}
