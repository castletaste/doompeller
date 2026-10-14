# Doompeller production plan

Goal: Doom running natively on Dart + Flutter + flutter_scene. Real GPU geometry
compiled from WAD data through Flutter GPU / Impeller on macOS and flutter_scene's
WebGL2 backend in a Flutter Wasm browser build. No FFI, WebView, emulator, wrapping an
existing Doom engine, or reuse of Doom's software renderer.

First target level: original **E1M1** only.

Current approved continuation: make the supplied original episode playable
across **E1M1–E1M9**, including the E1M3 secret exit, E1M9 return to E1M4,
and E1M8 boss ending. E1M1 remains the pinned regression baseline.

Episode acceptance requires actual command replays under normal gameplay
rules and a fresh replay verification. No-monster routing probes and scene
render sweeps are diagnostics, not completed-level evidence.

## Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Skeleton, package boundaries, pins, contracts | `flutter analyze` clean, empty app builds on macOS |
| M1 | `doom_wad`: container, resources, map lumps, synthetic fixture WAD | Fixture PWAD round-trips; hostile input yields typed failures; no commercial bytes in CI |
| M2 | `doom_geometry`: BSP-first hybrid compile to packed meshes | E1M1 compiles with zero gaps vs sector-loop oracle; bounded time |
| M3 | Adapter + shader: indexed palette rendering of E1M1 on Impeller | E1M1 visible, correct palette, 60 FPS budget met |
| M4 | `doom_core`: 35 Hz sim, movement, collision, doors/lifts, triggers | Deterministic replay hash stable; E1M1 traversable |
| M5 | Things: sprites, pickups, enemies, AI, combat, weapons | E1M1 playable start to exit |
| M6 | HUD, automap, sound, level exit, polish | Full E1M1 loop at 60 FPS |
| M7 | Flutter Wasm browser build (WebGPU at the time; WebGL2 since the flutter_scene migration) | Bundled E1M1 auto-starts at 60 FPS; local picker exists only in pause |

## The one big open technical risk

**BSP-first geometry is exactly what the spike did not prove.** The spike used
sector-loop triangulation. Vanilla `SEGS` omit minisegs, so a subsector's
polygon cannot be closed from segs alone: it must be clipped against the BSP
partition planes walked down from the root, which invites T-junction cracks and
degenerate polygons.

Mitigation, built into M2 rather than bolted on later:

1. Compile floors/ceilings both ways — BSP subsector clipping (primary) and
   sector-loop triangulation (oracle).
2. Compare per-sector covered area and edge adjacency. Report gaps, degenerate
   triangles, T-junctions and area deltas in `GeometryReport`.
3. If BSP output fails validation for a sector, fall back to the loop result for
   that sector and record it. Never silently drop geometry.
4. Kill condition: if E1M1 needs per-map manual patching to look right, stop and
   revisit the geometry policy with the user.

## Content path

- The default local source is `.local/doom/DOOM1.WAD`; desktop may override it
  with `DOOM_WAD_PATH`.
- Native and Wasm release builds validate and package that file as a Flutter
  asset. Web startup fetches `assets/.local/doom/DOOM1.WAD` automatically.
- Web release acceptance requires a dart2wasm-only bootstrap with no generated
  `main.dart.js` fallback.
- The browser local-file picker is available only from the pause menu.
- Unit tests keep generated regression fixtures; local acceptance also runs the
  original E1M1 report and deterministic traversal.
- Gameplay behaviour is reimplemented in Dart. Constants and mechanics may be
  re-derived from the GPL Doom source, but no C source is embedded, translated
  verbatim, or wrapped.

## Renderer pin policy

Flutter 3.47.7 / Dart 3.13.5, flutter_scene 0.24.3, flutter_gpu_shaders 0.5.2,
hooks 2.0.2, vector_math 2.4.0 — all exact. flutter_scene is pre-1.0 and its
minor releases may break, so all unstable surface area lives in `lib/adapter`,
and its internal `src/` imports in `lib/adapter/scene_gpu.dart` alone.
**Forking flutter_scene is forbidden.** On an unfixable upstream or adapter
blocker: stop and revisit the plan with the user.

A pinned-ABI tripwire test asserts that our packed 20-float vertex record, the
declared GPU vertex layout and the palette shader's attribute declarations
agree. Bumping any pin requires rerunning the shader, packed-buffer,
dynamic-upload, visual (including the exhaustive palette pattern), reload and
performance probes.

## Out of scope for now

- Desktop WAD import UI beyond the developer environment path
- iOS, Android, Windows, Linux
- Multiplayer, demo playback compatibility with vanilla, saves
- Doom II and episodes 2–4 (not present in the supplied DOOM1.WAD)
