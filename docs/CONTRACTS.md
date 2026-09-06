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
            maxTextures, maxPatchesPerTexture, maxBlockmapCells,
            maxBlockmapEntries, maxIntersectionChecks, maxSoundSamples,
            maxSoundSampleRate;
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
class DoomSound { String name; int sampleRate, sampleCount; Uint8List pcm; }
class DoomMusicInfo { String name; int byteLength; bool isMus; }
class WadResources {
  static WadResources load(WadSet set, {DoomLimits limits});
  Playpal get playpal; Colormap get colormap;
  PatchImage? composite(String textureName);   // TEXTURE1/2 + PNAMES composed
  FlatImage? flat(String name);
  PatchImage? sprite(String lumpName);
  TextureDef? textureDef(String name);
  List<String> get spriteNames;
  DoomSound? sound(String lumpName);       // lazy, memoised unsigned 8-bit PCM
  List<String> get soundNames;             // DS* lumps, sorted
  DoomMusicInfo? music(String lumpName);   // D_* length + MUS signature only
}

enum DoomAnimationKind { flat, wall }
class DoomAnimationDefinition { DoomAnimationKind kind; String startName, endName; int speed; }
class DoomAnimation { DoomAnimationDefinition definition; List<String> frames; }
class DoomSwitchPair { String offName, onName; }
DoomAnimationResolution resolveDoomAnimations(WadResources resources);

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
  List<AnimatedSurfaceRef> animations; // page-local atlas-rect mutations
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
  static GameState start(MapData map, GameConfig config, {int seed, PlayerLoadout? loadout});
  LevelExit? get levelExit;           // completed map, exit kind, immutable inventory
  int get initialSeed;                     // exact restart seed, hash-neutral
  void runTic(TicCmd cmd);
  int get tic;
  int get playerSectorIndex;          // read-only current sector for UI discovery
  int get levelTime;
  int get killCount, totalKills, itemCount, totalItems;
  int get secretsFound, totalSecrets;
  PlayerView get player;              // x, y, z, angle, viewZ, health, armor, ammo, weapon, weaponAnimation
  Iterable<MobjView> get mobjs;       // position/height, angle, sprite/frame, flags, light/fullbright
  Iterable<SectorRuntime> get sectors; // current floor/ceiling heights, light, flats
  List<SoundEvent> get soundJournal;   // retained output, excluded from hashState
  List<SoundEvent> consumeSoundJournal();
  List<SwitchTextureChange> get switchJournal; // retained visual output
  int hashState();                    // deterministic replay oracle
}

abstract final class DoomCoreCatalog {
  static Set<int> get supportedLinedefSpecials;
  static Set<int> get supportedSectorSpecials;
  static Set<String> get soundIds;             // canonical DS* lump names
  static MobjInfo? infoForEdNum(int doomEdNum);
  static Key? requiredKeyForLineSpecial(int special);
  static Key? keyForEdNum(int doomEdNum);
}
```

`GameConfig.maxSoundPropagationVisits` bounds one weapon-noise sector walk and
defaults to `DoomLimits.defaults.maxSectors` (65535). The ruleset value is
future-affecting and is included in `hashState()`.

`GameConfig.maxStairBuildVisits` similarly bounds one stair-building traversal,
defaults to 65535, and is included in `hashState()`. `DoomCoreCatalog` is the
single public capability-audit entry point: its linedef set is assembled from
the exact dispatcher classifier sets; actor/key lookups share spawn and pickup
classification; sound ids are the canonical DS lump names emitted by the core.

`GameConfig.maxDonutBuildVisits` bounds donut and floor-model topology walks,
also defaults to 65535, and is hashed with a versioned sentinel when non-default
so the established default replay schema remains stable.

Episode transitions are in-memory. `PlayerLoadout` carries health, armor,
ammo, current weapon and immutable weapon ownership; position, keys,
statistics, movers and transient actor/weapon state start fresh. A prepared
level retains its entry loadout for deterministic restart. `DoomEpisode`
maps E1M3's secret exit to E1M9, E1M9 to E1M4 and ends at E1M8.
The app retains the completed level until successor preparation succeeds;
request/generation fences discard obsolete loads, and failed transitions
remain retryable. Default startup still loads the original bundled IWAD;
file selection remains in the pause menu.

Monster awareness stores the latest live sound target per reached sector.
Traversal uses pre-indexed touching linedefs, crosses at most one
`ML_SOUNDBLOCK` boundary, observes current two-sided openings, and caps both
queue growth and visits at the configured budget. Sector sound targets, ambush
state, individual reaction/threshold/move counters and actor targets are all
hashed; death-camera descent and turn toward the killer are visual-only and
excluded. They alter `PlayerView` presentation but never the hashed player
actor angle or a future simulation decision.

### doom_core M4/M5 supported special subset

The core classifies specials by their explicit map-format values in
`doom_core/src/specials.dart`, never by tag alone. Implemented use/cross paths:

| Category | values | current behaviour |
|---|---|---|
| normal door | 1, 31 | tag-0 uses the used line's back sector; tagged lines target matching sectors; 1 opens, waits 150 tics, then closes; 31 stays open |
| locked door | 26/32 blue, 27/34 yellow, 28/33 red | requires collected key, otherwise leaves the line inactive; wait-close for 26/27/28, stay-open for 32/33/34 |
| switch doors | 61, 99, 103, 134 | recognized by the same door/key policy; S1 stays pressed, SR resets after 35 tics |
| walk doors | W1 2 open-stay, 3 close, 4 open-wait-close, 16 close-wait-open; WR 75 close, 86 open-stay, 90 open-wait-close | tagged sectors only; normal speed; waits 150 tics at top and 1050 tics for close-wait-open; closing never damages an obstructing live actor; W1 consumes the line, WR may retrigger |
| crushers | W1 6 fast, 25 normal; S1 49 normal; WR 73 normal, 77 fast; stop W1 57 / WR 74 | ceiling cycles from its initial height to floor+8; normal speed is one unit/tic and slows to 1/8 on contact, fast stays two; every fourth tic deals 10 damage and crushed monster corpses gib; stopped crushers retain their future direction for restart; doors remain non-crushing |
| lifts | 10, 21, 62, 88, 120..123 | sector floor descends to lowest neighbour, waits 35 tics, then returns |
| raise floors | 5 walk / 24 gun to eight below lowest neighbouring ceiling; S1 18 and W1/WR 119/128 to next higher neighbouring floor; W1 58 by 24; WR 91 to lowest neighbouring ceiling | tagged sectors use distinct height queries; W1/S1 are one-shot, WR retriggers after the previous mover completes |
| raise and change | S1 20 / W1 22 to next higher floor; W1 59 by 24 | 20/22 move at half speed, take the trigger front-sector flat immediately and clear the sector special; 59 moves at floor speed and immediately takes the front-sector flat and special |
| lower floors | W1 19 to highest neighbour, 36 turbo to highest neighbour plus 8, 38 to lowest neighbour; S1 23 and WR 82 to lowest neighbour | tagged sectors; normal one-unit speed except 36 at four units/tic; lowering cannot crush |
| lower and change | W1 37 | lowers at one unit/tic; on arrival takes flat and special from the first neighbouring model at the destination height |
| stairs | S1 7, W1 8 | raises a directed front-to-back chain of same-floor-flat sectors in successive 8-unit steps at quarter floor speed; traversal and queue growth stop at `maxStairBuildVisits` |
| donut | S1 9 | tagged inner floor and surrounding ring converge on the outer model height at half speed; the ring takes the outer flat and clears its special; topology visits stop at `maxDonutBuildVisits` |
| switch exit (S1) | 11 normal, 51 secret | front-side player use, once; records `levelComplete` and secret-trigger intent |
| walk exit (W1) | 52 normal, 124 secret | player crossing in either direction, once; records the same completion state |
| sector effects | 1..5, 7..9, 11..13, 17 | deterministic flicker/strobe/glow journals light deltas; 5/7/11 damage at 32-tic cadence; 9 increments one-time secret count |

The implementation does **not** claim demo compatibility, generalized Boom
specials, teleporters, the remaining classic ceiling/floor/platform families,
or a complete commercial-E1M1 audit. The supported crushers, floor-model
transfers and donut above have synthetic deterministic coverage but still need
runtime verification with the developer-local WAD, never a committed asset.

Collision treats a loaded `BLOCKMAP` as advisory candidate ordering, not as
authority: candidates are unioned with the loader-bounded canonical linedef
list. This intentionally favors fail-closed E1M1 correctness over broadphase
speed until a separately validated pure-Dart spatial index replaces the union.

Persistent momentum is clamped symmetrically and split into two collision
steps when either component exceeds half the per-tic maximum. Splitting
negative as well as positive components is an intentional anti-tunnelling
strengthening; vanilla only split positive components. Player
input adds thrust only while `Mobj.isOnGround`, preventing future vertical
physics from introducing air control.

`GameState.changeJournal` retains ordered floor, ceiling, light, and floor-flat records
until `consumeChangeJournal()` is called. This prevents a renderer that misses
one 35 Hz tic from silently losing an earlier plane update; consuming returns
an immutable snapshot and clears the pending records.
The pending journal is deliberately excluded from `hashState()`: consuming
renderer output cannot affect a future simulation tic, and hashing it would
make replay identity depend on renderer polling. Player bob is likewise
excluded because it is derived renderer output from the hashed tic and
momentum. Future-affecting input latch, actor-id allocator, activated one-shot
lines, mutable actor flags/frame, and mover/actor state are hashed.

`PlayerView.weaponAnimation` exposes the first-person weapon phase, body/flash
lamps, remaining tic count and psprite Y. Phase, body-state cursor, body lamp,
tics and Y are hashed because they gate future firing. The flash lamp and its
visual-only lifetime are excluded. The adapter maps lamp indices to exact
supplemental sprite names and never makes firing decisions.

Actor animation uses a clean-room Dart state table. The stable FNV-1a identity
of the selected record's semantic name is hashed in addition to the coarse
phase, frame and remaining tics because two consecutive records may
deliberately display the same lamp but have different successors. Actor types
are identified the same way from `MobjType.name`; neither identity depends on
an enum index or physical table cursor, so unrelated insertions do not move the
replay oracle. `MobjView.fullBright` and `lightLevel` carry the selected record
and current sector light into the adapter; these renderer-facing values are
derived from that already-hashed actor/sector state.

The E1M1 thing catalog also recognizes deathmatch start 11 as non-spawning map
metadata and renders thing 24 plus pickup types 2003, 2019, 2046, 2048 and
2049. Mega armor, bullet boxes and shell boxes apply their current player-state
effects. Rocket launcher and rocket box are deliberately collectable visual
placeholders until rockets and a rocket weapon exist; they never fall through
to an unrelated health or ammo effect.

Classic flat/wall animation ranges and switch pairs are clean-room Dart data.
Flat ranges follow WAD directory order; wall ranges follow TEXTURE1/TEXTURE2
declaration order. Missing endpoints or frame data degrade to static and appear
in `GeometryReport.animationFailures`. Animation selection is derived from
`levelTime ~/ speed` and adds no state to `hashState()`. Pressed S1 state and
SR button timers affect future activation and are hashed; their retained
renderer journal is output-only and excluded.

`GameState.soundJournal` follows the same retained-until-consumed contract and
returns immutable `SoundEvent` snapshots containing the DS lump id, fixed-point
source position, and `world` / `player` / `nonPositional` origin. It is also
excluded from `hashState()`: playback polling is output-only. Any state that
decides future sound emission remains ordinary hashed simulation state; door
and lift phase is already represented by each mover's hash words.

Each event also carries `sourceId` and `tic`. Together they let a consumer
collapse duplicates honestly: one emitter, one lump, one tic. Position alone is
wrong, because two actors can stand on the same spot and one actor can fire
twice across skipped tics. Actor ids are positive, the player is zero, sectors
are `-index - 1`, and non-positional events use a single reserved id.

The journal is capped so a renderer that never polls cannot grow it without
bound. On overflow the oldest expendable event is dropped first; door, lift,
death and exit cues are treated as critical and are preserved in preference to
ordinary cues. Dropped events are counted, and that counter is output-only too.

The synthetic replay oracle is pinned by `doom_core/test/core_test.dart` at
`0xe553be3f` for seed 7 and its documented twenty-command stream. It reflects
long-linedef collision, barrel no-blood flags, exact ray-circle targeting, and
unified actor hit effects. The isolated combat oracle is pinned at
`0x2a47da36`: its hash is sampled before that test's movement assertion. Both
pins use semantic actor/state identities; inserting an unused actor state or
actor type does not change them.
The generated PWAD itself is pinned at
`0xbeff6842cbe7b69e` and 498292 bytes (including nine generated episode sound
lumps). Spawn order is intentionally part of
deterministic identity and therefore part of the hash; actor hashing itself
sorts by stable actor id.

The synthetic MAP97 completion stream is separately pinned at `0x9113cff2`
after deterministic pickup state and unified actor hit effects. The
developer-local shareware E1M1 production traversal is pinned at `0x36d1d056`
for its generated 2151-command stream. The separate keyboard-sampling
acceptance path is pinned at `0x82b6aada` for 2154 commands.

### WebGPU boundary

The web target is Flutter Wasm and flame_3d's conditional WebGPU backend.
`assets/shaders/doom_palette.wgslbundle` is generated by naga through
`flame_3d:build_shaders --with-web-gpu` and remains a gitignored build
artifact alongside the native shader bundle. The same 20-float vertex record,
uint16 mesh split, atlas pages, palette/COLORMAP lookup and dirty buffer writes
are used on both backends.

The web release validates `.local/doom/DOOM1.WAD`, packages it at
`build/web/assets/.local/doom/DOOM1.WAD`, and fetches it automatically at
startup. The finalizer removes Flutter's generated dart2js build target and
`main.dart.js`; `dart2wasm` is the only app compile target. The same bounded
in-memory parser handles both the bundled response and a local file selected
only from the pause menu. Platform environment and file APIs live behind
conditional imports so Wasm startup never evaluates `dart:io`.

The supported browser runtime and acceptance gate is Wasm/WebGPU.

## lib/adapter public API

```dart
class DoomVertexAbi { static const int floatsPerVertex = 20; ... }
class PackedFlameSurface extends Surface { ... }   // wraps Float32List + Uint16List
class PaletteMaterial extends Material { ... }     // index atlas -> COLORMAP -> PLAYPAL
class PaletteTextures { ... }                      // uploads atlas/colormap/playpal
class DoomScene { ... }                            // builds MeshComponents, updates planes
```

`DoomScene.updateTextureAnimations(levelTime)` and
`updateSwitchTexture(change)` rewrite only atlas-rect floats 12..15 for the
referenced vertices and reuse dirty-range uploads. Every animation/switch group
is packed atomically on one page; exceeding `maxAtlasPixels` is a typed compile
failure, never a silently dropped frame.

Classic linedef special 48 is a visual geometry capability exposed through
`DoomGeometryCompiler.supportedLinedefSpecials`. Its front-sided wall bands
advance texture-local U by one texel per level tic through the same retained
mesh and dirty-range upload path. The offset is derived from `levelTime`, so it
adds no mutable simulation state and does not enter `GameState.hashState()`.

`DoomScene.updateSectorFloorFlat(sectorIndex, flatName)` uses the same atlas-rect
dirty-range path for mutable floors. The geometry compiler transitively merges
overlapping animation and floor-transfer co-location groups; a missing entry or
cross-page mutation is a typed failure rather than a material mismatch.

## Frame budget

Target 60 FPS. Spike baseline on macOS release: p50 0.77 ms, p95 1.09 ms,
p99 2.04 ms Flutter `FrameTiming.totalSpan` with 24 GPU buffers. E1M1 is much
larger, so every milestone re-measures.

## Addendum: doom_wad, as implemented

Appended by the doom_wad implementation. The signatures above are unchanged
except where noted here.

### PatchImage pixel order is ROW-major

The sketch above annotated `PatchImage` as "column-major decoded". The
implementation stores pixels ROW-major: pixel (x, y) lives at
`y * width + x`, for both `indices` and `coverage`.

On disk a Doom patch *is* column-major, but the decoder transposes once at load
time because every consumer downstream wants scanline order: atlas packing,
composite blitting and GPU upload all walk rows. Leaving it column-major would
push a transpose into each of them.

Consumers in `doom_geometry` and `lib/adapter` must index accordingly.

### Additive API beyond the sketch

Nothing below removes or changes a signature above; it is extra surface the
implementation needed.

- `FlatImage` gained a `name` field, so its constructor is
  `FlatImage({required String name, required Uint8List indices})`. It carries
  `isSky`, which is how F_SKY1 is detected without a second lookup.
- `WadResources` also exposes `patchNames`, `patchAt(int)`,
  `patchByName(String)`, `flatNames` and `textureNames`.
- `WadFile` also exposes `lastIndexOfLump`, `byteLength` and `length`;
  `LumpEntry` carries `index`, `name`, `offset`, `size` and `isMarker`.
- `WadSet` also exposes `nameAt`, `entryAt`, `wadIndexAt`, `indexOfFrom`,
  `require` and `length`.
- `Playpal.toArgb(int)` and `Colormap.toPlane()` pack palettes and light
  maps for texture upload.

### Test fixtures

`DoomFixtures` generates a synthetic PWAD in memory with a real BSP tree, so
no test needs a commercial WAD. `DoomFixtures.wadSet()` is the entry point;
`DoomFixtures.hash()` is pinned in `test/fixture_test.dart` to catch drift.
Its MAP01 has a convex sector, a concave L, a sector with a hole, two-sided
lines with mismatched heights and an F_SKY1 ceiling.

`buildWad`, `encodeDoomPatch` and `buildBspTree` are exported so the other
packages can build their own fixtures rather than duplicating the writers.

## doom_geometry addendum (M2)

Additive only: every signature in the doom_geometry section above still holds.
`DoomGeometryCompiler.compile(MapData, WadResources, {GeometryOptions})` is
unchanged and returns `CompiledLevel` as specified.

### Vertex ABI

doom_geometry writes the 20-float record defined by `lib/adapter/vertex_abi.dart`,
**including** that file's repurposing of the skinning slots. The adapter remains
the authority; `packages/doom_geometry/test/vertex_abi_test.dart` is a tripwire
that fails if the two drift apart.

| floats | contents |
|--------|----------|
| 0..2   | position x, y, z |
| 3..4   | texCoord u, v |
| 5..8   | light, 1, 1, alpha |
| 9..11  | normal x, y, z |
| 12..15 | atlas rect u0, v0, u1, v1 |
| 16..19 | fullBright, lightRow, uvMode, unused |

World space is `(mapX, height, -mapY)`. The Y negation preserves map winding
seen from above, so floors keep a +Y normal and ceilings are emitted reversed.

### Additional public surface

- `GeometryOptions` carries, beyond the three fields specified: `epsilon`,
  `weldGrid`, `maxBspDepth`, `areaToleranceFraction`, `areaToleranceFloor`,
  `atlasPageSize`, `spriteGutter` and `fakeContrast`. All have defaults, so
  `const GeometryOptions()` is still valid.
- `DoomGeometryCompiler.compileWithTextures(MapData, TextureSource, ...)` is a
  test-only entry point taking synthetic textures instead of a parsed WAD.
  `ResourceTextureSource` adapts a real `WadResources` to `TextureSource`.
- `CompiledLevel` exposes `setFloorHeight`, `setCeilingHeight` and
  `updateWallsForSector` for in-place door and lift updates. No mesh is
  rebuilt or reallocated; only vertex floats are rewritten.
- `SectorPlaneRef` holds `List<VertexRange> ranges` rather than a single mesh
  index, because a sector's floor can straddle a 65535-vertex mesh split.
- `WallBandRef` carries the pegging inputs (`lowerUnpegged`, `upperUnpegged`,
  `textureHeight`, `yOffset`, `atlasV0`, `atlasV1`) so a moving wall re-pegs
  its texture without a rebuild.
- `GeometryReport` adds `repairedTJunctionVertices` and `repairedRegions`.
- `GeometryOptions.skyTextureName` selects the classic camera-centred sky
  texture (`SKY1` by default). `CompiledLevel.skyTextureName` and
  `skyTextureEntry` expose it when present. `F_SKY1` is a sentinel opening and
  emits no floor or ceiling plane; the renderer owns the sky cube geometry.

### Atlas tiling scheme

Pages are RGBA8 because flame_3d 0.3.0 has no R8 format: R is the palette
index, G and A are coverage, B is reserved. World textures tile; each vertex
carries its own atlas sub-rect in floats 12..15 and `uvMode = uvModeRepeat`,
and the shader wraps within that rect, so UVs past 1.0 are expected and a
region boundary is always a texture boundary. Sprites use `uvModeClamp` and
get a transparent gutter.

### T-junction repair

Between BSP region reconstruction and triangulation, vertices lying in the
interior of another region's edge **of the same sector** are inserted into that
edge. Area and shape are unchanged; both sides of a shared boundary then agree
vertex for vertex, which is what closes the hairline cracks that BSP-first
geometry was flagged as risky for.

### Oracle reliability and shape findings

Self-referencing linedefs do not bound a sector floor and are excluded from the
sector-loop oracle. If an oracle still has an open chain or incomplete
triangulation, its area is explicitly non-comparable: the finding remains
visible but contributes zero to `GeometryReport.totalAreaDelta` and cannot by
itself condemn separately validated BSP output. Equal-area coverage differences
use `GeometryIssue.shapeMismatch`; `areaMismatch` is reserved for measured area
disagreement. Internal triangulation seams are accepted only when their probes
are covered by the other mesh.
