# Doompeller package contracts

This file is the coordination contract between packages. Agents implementing a
package must keep these public signatures stable; changing one requires
updating this file in the same commit and telling the orchestrator.

## Layering

```
packages/doom_wad       pure Dart, zero Flutter deps  -> WAD bytes to typed data
packages/doom_geometry  pure Dart, depends on doom_wad -> map data to packed meshes
packages/doom_core      pure Dart, depends on doom_wad -> 35 Hz gameplay simulation
lib/adapter             the ONLY place that touches flame_3d / flutter_gpu
lib/game                Flame game wiring, input, HUD, camera
```

Hard rules:

- `doom_wad`, `doom_geometry`, `doom_core` must not import `dart:ui`,
  `package:flutter`, `package:flame`, `package:flame_3d` or `dart:ffi`.
- Only `lib/adapter` imports `package:flame_3d`. Everything else consumes the
  adapter's own types.
- No original Doom C source is embedded, translated verbatim, or wrapped.
  Gameplay constants may be re-derived; behaviour is reimplemented in Dart.
- No commercial asset bytes are committed anywhere, ever.

## doom_wad public API

```dart
/// Typed, non-throwing-by-default failures.
sealed class DoomFailure { String get message; }
class DoomFormatFailure extends DoomFailure   // structurally invalid data
class DoomLimitFailure extends DoomFailure    // exceeded a configured budget
class DoomMissingLumpFailure extends DoomFailure

class DoomLimits {
  const DoomLimits({ ... });
  static const DoomLimits defaults;
  final int maxLumpCount, maxLumpBytes, maxVertices, maxLinedefs, maxSidedefs,
            maxSectors, maxSegs, maxSubsectors, maxNodes, maxThings,
            maxTextures, maxPatchesPerTexture, maxIntersectionChecks;
}

class WadFile {
  static WadFile parse(Uint8List bytes, {DoomLimits limits});  // throws DoomFailure
  WadKind get kind;                    // iwad | pwad
  List<LumpEntry> get lumps;
  Uint8List lumpBytes(int index);
  int? indexOfLump(String name, {int from});
}

/// Later lumps win, so a PWAD can override an IWAD.
class WadSet {
  WadSet(List<WadFile> wads);
  Uint8List? read(String name);
  int? indexOf(String name);
  Uint8List bytesAt(int index);
  List<String> mapNames();             // ExMy and MAPxx present
}

class Playpal { List<Uint8List> palettes; }            // 14 palettes x 256 x RGB
class Colormap { List<Uint8List> maps; }               // 34 maps x 256 indices
class PatchImage { int width, height, leftOffset, topOffset;
                   Uint8List indices; Uint8List coverage; }  // column-major decoded
class FlatImage  { Uint8List indices; }                // 64x64
class TextureDef { String name; int width, height; List<TexturePatch> patches; }
class WadResources {
  static WadResources load(WadSet set, {DoomLimits limits});
  Playpal get playpal; Colormap get colormap;
  PatchImage? composite(String textureName);   // TEXTURE1/2 + PNAMES composed
  FlatImage? flat(String name);
  PatchImage? sprite(String lumpName);
  TextureDef? textureDef(String name);
  List<String> get spriteNames;
}

/// Raw map lumps, all validated against DoomLimits.
class MapData {
  static MapData load(WadSet set, String mapName, {DoomLimits limits});
  String name;
  List<MapVertex> vertices;   // int x, y  (map units)
  List<Linedef> linedefs;     // v1, v2, flags, special, tag, rightSidedef, leftSidedef(-1)
  List<Sidedef> sidedefs;     // xOffset, yOffset, upper, lower, middle, sector
  List<Sector> sectors;       // floorHeight, ceilingHeight, floorFlat, ceilingFlat, light, special, tag
  List<Seg> segs;             // v1, v2, angle, linedef, side, offset
  List<Subsector> subsectors; // segCount, firstSeg
  List<BspNode> nodes;        // partition x,y,dx,dy; bbox[2]; children[2] (subsector bit 0x8000)
  List<Thing> things;         // x, y, angle, type, flags
  Blockmap? blockmap;
}
```

## doom_geometry public API

```dart
class GeometryOptions {
  final bool bspFirst;            // default true
  final bool validateAgainstLoops; // run sector-loop oracle and report deltas
  final DoomLimits limits;
}

/// Packed, GPU-ready, no Flutter types.
class PackedMesh {
  Float32List vertices;   // 20 floats per vertex, Flame ABI (see adapter)
  Uint16List indices;
  int vertexCount, indexCount;
  int atlasPage;
  SurfaceKind kind;       // opaque | masked | sky
}

class CompiledLevel {
  List<PackedMesh> meshes;
  IndexedAtlas atlas;                 // index+coverage planes, page size
  List<SectorPlaneRef> floorPlanes;   // for dynamic height updates
  List<SectorPlaneRef> ceilingPlanes;
  List<WallBandRef> wallBands;        // for door/lift wall updates
  GeometryReport report;              // triangles, gaps found, degenerate polys, fallbacks
}

class DoomGeometryCompiler {
  static CompiledLevel compile(MapData map, WadResources res, {GeometryOptions options});
}
```

## doom_core public API

```dart
const int kTicRate = 35;

class TicCmd { int forwardMove, sideMove, angleTurn; int buttons; }

class GameState {
  static GameState start(MapData map, GameConfig config, {int seed});
  void runTic(TicCmd cmd);
  int get tic;
  PlayerView get player;              // x, y, z, angle, viewZ, health, armor, ammo, weapon
  Iterable<MobjView> get mobjs;       // x, y, z, angle, sprite, frame, flags
  Iterable<SectorRuntime> get sectors; // current floor/ceiling heights, light, flats
  int hashState();                    // deterministic replay oracle
}
```

## lib/adapter public API

```dart
class DoomVertexAbi { static const int floatsPerVertex = 20; ... }
class PackedFlameSurface extends Surface { ... }   // wraps Float32List + Uint16List
class PaletteMaterial extends Material { ... }     // index atlas -> COLORMAP -> PLAYPAL
class PaletteTextures { ... }                      // uploads atlas/colormap/playpal
class DoomScene { ... }                            // builds MeshComponents, updates planes
```

## Frame budget

Target 60 FPS. Spike baseline on macOS release: p50 0.77 ms, p95 1.09 ms,
p99 2.04 ms Flutter `FrameTiming.totalSpan` with 24 GPU buffers. E1M1 is much
larger, so every milestone re-measures.
