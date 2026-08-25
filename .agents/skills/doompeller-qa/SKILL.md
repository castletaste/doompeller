---
name: doompeller-qa
description: "Validate Doompeller changes across pure-Dart package tests, Flutter analyze and test, the macOS Impeller target, geometry reports, replay determinism, and frame performance. Does not authorize commit, push, deploy, or release."
---

# Doompeller QA

Match evidence to the claim: inspection proves a code path exists, tests prove a contract is exercised, a build proves packaging, a live run proves only the target and mode observed. Record checkout and dirty state, and keep unrelated WIP separate.

- Per package (`doom_wad`, `doom_geometry`, `doom_core`): `/Users/savva/fvm/versions/stable/bin/dart analyze` and `dart test`. App: the same SDK's `flutter analyze` and `flutter test` from the root. System `dart`/`flutter` are older and fail. Zero analyzer warnings is the standard.
- Layering is testable and should be tested: the three packages import no `dart:ui`, `dart:ffi`, Flutter, Flame, or flame_3d; only `lib/adapter` imports flame_3d; and no FFI, WASM, WebView, or wrapped engine exists anywhere in project code.
- Geometry claims need the `GeometryReport` — area deltas, unmatched edges, T-junctions, degenerate triangles, fallback sectors — not a screenshot. Gameplay claims need a replay: same seed and command stream, stable `hashState()`, repeated and reordered. An unexplained hash change is a regression until proven otherwise.
- Renderer claims need a live frontmost macOS release target with the Impeller Metal backend confirmed in the log; a throttled background window degrades frame stats misleadingly. Check pegging, seams, cutouts, sky, billboards, depth order, palette flashes, and moving sectors across several cycles.
- Performance is warmed release percentiles on a stated scene, with surface, buffer, upload, and triangle counters. Say plainly that it is Flutter `FrameTiming.totalSpan`, not presented frames. Memory: repeated load/unload with settled RSS rules out explosive growth but cannot prove reclamation, since flame_3d exposes no live resource counter. Spike numbers are history, never a production result.

Report command, scenario, target, mode, pass/fail, and untested scope, separating pre-existing failures. Commit, push, deploy, and external actions remain separate explicit approvals.
