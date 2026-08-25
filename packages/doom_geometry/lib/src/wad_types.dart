// Single choke point for everything doom_geometry consumes from doom_wad.
//
// Every other file in this package imports this one rather than doom_wad
// directly, so the dependency surface is visible in one place and a change
// upstream has exactly one place to land.
export 'package:doom_wad/doom_wad.dart'
    show
        Blockmap,
        BspNode,
        Colormap,
        DoomFailure,
        DoomFormatFailure,
        DoomLimitFailure,
        DoomLimits,
        DoomMapFailure,
        DoomMissingLumpFailure,
        FlatImage,
        Linedef,
        LinedefFlags,
        MapData,
        MapVertex,
        PatchImage,
        Playpal,
        Sector,
        Seg,
        Sidedef,
        Subsector,
        TextureDef,
        TexturePatch,
        Thing,
        ThingFlags,
        WadResources,
        kFlatBytes,
        kFlatSize,
        kNoSector,
        kNoSidedef,
        kNoTextureName,
        kSkyFlatName,
        kSubsectorBit;
