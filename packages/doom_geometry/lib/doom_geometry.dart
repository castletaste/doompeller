/// Pure Dart Doom level geometry compiler.
///
/// Turns parsed map lumps into packed, GPU-ready meshes with no Flutter, Flame
/// or dart:ui dependency. The entry point is [DoomGeometryCompiler.compile];
/// everything else here exists so the result can be inspected, validated and
/// updated in place at runtime.
library;

export 'src/atlas.dart' show AtlasBuilder, AtlasEntry, AtlasPage, IndexedAtlas;
export 'src/bsp_regions.dart' show BspRegion, BspRegionBuilder, BspRegionSet;
export 'src/compiler.dart' show CompiledLevel, DoomGeometryCompiler;
export 'src/geometry_options.dart' show GeometryOptions;
export 'src/geometry_report.dart'
    show GeometryIssue, GeometryReport, SectorFinding, SectorMesh2D;
export 'src/geometry_validation.dart' show GeometryValidator;
export 'src/mesh_packer.dart' show FlatUvMapper, MeshPacker, kFlatTileSize;
export 'src/packed_mesh.dart'
    show
        DoomVertexAbi,
        PackedMesh,
        SectorPlaneRef,
        SurfaceKind,
        VertexRange,
        WallBandKind,
        WallBandRef;
export 'src/polygon.dart' show PolyBuffer, polygonArea, signedArea2;
export 'src/sector_loops.dart' show SectorLoopBuilder, SectorLoopResult;
export 'src/texture_source.dart'
    show
        MapTextureSource,
        ResourceTextureSource,
        TextureSource,
        WadTextureSource;
export 'src/tjunction.dart' show TJunctionRepairResult, repairTJunctions;
// The doom_wad types that appear in this package's own signatures, re-exported
// so a consumer needs one import rather than two.
export 'src/wad_types.dart'
    show
        DoomFailure,
        DoomFormatFailure,
        DoomLimitFailure,
        DoomLimits,
        FlatImage,
        Linedef,
        LinedefFlags,
        MapData,
        MapVertex,
        PatchImage,
        Sector,
        Seg,
        Sidedef,
        Subsector,
        TextureDef,
        TexturePatch,
        WadResources,
        kFlatBytes,
        kFlatSize,
        kNoSector,
        kNoSidedef,
        kNoTextureName,
        kSkyFlatName;
export 'src/triangulate.dart'
    show
        CheckBudget,
        EarClipper,
        Loop,
        TriangulationResult,
        triangulateConvexBoundary;
export 'src/walls.dart' show WallBuilder, WallQuad, WallSet;
