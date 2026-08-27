# Doompeller production plan

Goal: Doom running natively on Dart + Flutter + Flame 3D. Real GPU geometry
compiled from WAD data through Flutter GPU / Impeller on macOS and flame_3d
WebGPU in a Flutter Wasm browser build. No FFI, WebView, emulator, wrapping an
existing Doom engine, or reuse of Doom's software renderer.

First target level: original **E1M1** only.

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
| M7 | Flutter Wasm + flame_3d WebGPU | Bundled E1M1 auto-starts at 60 FPS; local picker exists only in pause |

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

Flutter 3.44.4 / Dart 3.12.2, Flame 1.38.0, flame_3d 0.3.0, vector_math 2.2.0 —
all exact. flame_3d is experimental with no semver guarantee, so all unstable
surface area lives in `lib/adapter`. **Forking flame_3d is forbidden.** On an
unfixable upstream or adapter blocker: stop and revisit the plan with the user.

A pinned-ABI tripwire test asserts our packed 20-float vertex layout still
matches flame_3d's own `Vertex.storage`. Bumping any pin requires rerunning the
shader, packed-buffer, dynamic-upload, visual, reload and performance probes.

## Out of scope for now

- Desktop WAD import UI beyond the developer environment path
- iOS, Android, Windows, Linux
- Multiplayer, demo playback compatibility with vanilla, saves
- Doom II, episodes beyond E1M1
