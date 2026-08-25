# Doompeller production plan

Goal: Doom running natively on Dart + Flutter + Flame 3D. Real GPU geometry
compiled from WAD data through Flutter GPU / Impeller. No FFI, no WASM, no
WebView, no emulator, no wrapping an existing Doom engine, no reuse of Doom's
software renderer.

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

## Content and licensing posture

- Original Doom content is not public domain. No WAD, no extracted asset, and
  nothing derived from a commercial IWAD is ever committed, pushed, packaged in
  an artifact, or released.
- Developer-only local scheme: the user's own legally obtained copy at
  `.local/doom/DOOM.WAD`, read at runtime via the `DOOM_WAD_PATH` environment
  variable. `.local/` and `*.wad`/`*.WAD` are gitignored.
- Nothing downloads or otherwise obtains a WAD automatically.
- All automated tests run against the synthetic fixture PWAD generated in Dart,
  never against a commercial IWAD.
- Gameplay behaviour is reimplemented in Dart. Constants and mechanics may be
  re-derived from the GPL Doom source, but no C source is embedded, translated
  verbatim, or wrapped.
- Public free demo content is deferred to backlog.

## Renderer pin policy

Flutter 3.44.4 / Dart 3.12.2, Flame 1.38.0, flame_3d 0.3.0, vector_math 2.2.0 —
all exact. flame_3d is experimental with no semver guarantee, so all unstable
surface area lives in `lib/adapter`. **Forking flame_3d is forbidden.** On an
unfixable upstream or adapter blocker: stop and revisit the plan with the user.

A pinned-ABI tripwire test asserts our packed 20-float vertex layout still
matches flame_3d's own `Vertex.storage`. Bumping any pin requires rerunning the
shader, packed-buffer, dynamic-upload, visual, reload and performance probes.

## Out of scope for now

- User-facing WAD import UI
- iOS, Android, web, Windows, Linux
- Multiplayer, demo playback compatibility with vanilla, saves
- Doom II, episodes beyond E1M1
