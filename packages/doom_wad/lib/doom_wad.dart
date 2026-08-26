/// Pure Dart Doom WAD container, resource and map-lump parser.
///
/// Nothing here imports dart:ui, dart:ffi, Flutter or Flame: the package turns
/// WAD bytes into typed data and stops there. Hostile input surfaces as a
/// [DoomFailure] rather than an untyped error, and every allocation is bounded
/// by [DoomLimits].
library;

export 'src/animations.dart';
export 'src/bsp_builder.dart'
    show
        BspNodeOut,
        BspSeg,
        BspSubsector,
        BspTree,
        bamAngle,
        buildBspTree,
        distanceBetween,
        kBspSubsectorBit;
export 'src/failures.dart';
export 'src/fixture_map.dart'
    show
        FixtureGeometry,
        FixtureMapLumps,
        buildFixtureMapLumps,
        buildFixtureBlockmap;
export 'src/fixtures.dart'
    show
        DoomFixtures,
        buildFixtureColormap,
        buildFixtureFlat,
        buildFixturePatch,
        buildFixturePlaypal,
        buildFixtureSound,
        buildFixtureSprite;
export 'src/scale_fixture.dart' show DoomScaleFixture, ScaleFixtureConfig;
export 'src/limits.dart';
export 'src/map_loader.dart'
    show
        kLinedefBytes,
        kMapLumpNames,
        kNodeBytes,
        kSectorBytes,
        kSegBytes,
        kSidedefBytes,
        kSubsectorBytes,
        kThingBytes,
        kVertexBytes,
        loadMapData,
        parseBlockmap;
export 'src/map_model.dart';
export 'src/playthrough_fixture.dart' show DoomPlaythroughFixture;
export 'src/resources.dart' show WadResources, decodeDoomPatch, decodeDoomSound;
export 'src/resources_model.dart';
export 'src/wad.dart';
export 'src/wad_builder.dart'
    show LumpSource, buildWad, encodeDoomPatch, fnv1a64;
