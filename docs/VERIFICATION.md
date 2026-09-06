# Episode verification — 2026-09-06

Production continuation from `7bc0245`. Original local DOOM1.WAD, 4,196,020
bytes, MD5 `f0cefca49926d00903cf57551d901abe`. This report is not a claim that
every level has been completed.

## Evidence boundaries

- The pinned original E1M1 route uses normal medium-skill gameplay with enemies:
  2,151 commands, final hash `0x36d1d056`, health 66, 6/6 kills. Its original-WAD
  regression also verifies transfer of the final inventory into original E1M2.
- The controller test prepares all nine actual maps in episode/secret order,
  preserves inventory, rejects stale/duplicate transitions and supports retry
  after a failed preparation. This proves transitions, not navigation.
- Component probes using original geometry with authored actor placement are
  explicitly labelled in their tests. They prove weapon/power/effect contracts,
  not original-map playthroughs.
- Disposable route-planner work is not production code. No-monster route
  results are diagnostic, not acceptance for normal gameplay.

## Original-map preflight

All E1M1–E1M9 reports return `READY WITH FALLBACKS`; no unresolved map textures,
flats, unknown things or unsupported catalogued specials. All have zero
unmatched edges and zero degenerate triangles. BSP sector fallbacks remain;
T-junction diagnostics remain on E1M2 (9), E1M5 (1), E1M6 (2), E1M7 (3).
These are not a claim of pixel-perfect geometry.

## Automated checks

`flutter analyze` is clean; root Flutter suite passes 238 tests. Pure-Dart
core passes 171 tests, WAD passes 139, and geometry passes 128 (3 intentionally skipped);
their analyzers are clean. Shader bundle regeneration and the project contract
audit also pass. No external review finding is accepted without checking its
code path against the intended behavior and, where relevant, the
[original sector/damage rules](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_spec.c).

Reproduce each full report with:

```sh
/Users/savva/fvm/versions/stable/bin/dart run tool/wad_report.dart \
  --map E1M8 .local/doom/DOOM1.WAD
```

## Native scene sweep

Release macOS executable logged `Using the Impeller rendering backend (Metal)`.
Each original scene ran normally for 2 seconds of warmup and 6 seconds of
sampling. This first sweep preceded the corrected weapon projection and power
visuals; it identified an offscreen weapon defect during visual inspection.

| Scene | Frame samples | p95 total span (ms) | p99 (ms) | Surfaces |
|---|---:|---:|---:|---:|
| E1M1 | 724 | 3.085 | 3.772 | 87 |
| E1M2 | 725 | 3.589 | 4.812 | 182 |
| E1M3 | 724 | 3.499 | 3.711 | 302 |
| E1M4 | 722 | 2.679 | 3.536 | 192 |
| E1M5 | 726 | 1.970 | 2.191 | 217 |
| E1M6 | 725 | 3.605 | 3.951 | 373 |
| E1M7 | 723 | 3.589 | 3.751 | 272 |
| E1M8 | 725 | 1.401 | 2.174 | 94 |
| E1M9 | 724 | 3.297 | 3.546 | 190 |

These are Flutter `FrameTiming.totalSpan`, **not GPU or presented-frame timing**.
RSS ranged 248–273 MB over this sweep; it does not prove GPU resource reclamation.
Scene sweeps do not prove navigation, combat or exit completion.

```sh
/Users/savva/fvm/versions/stable/bin/flutter build macos --release \
  -t tool/episode_render_smoke.dart \
  --dart-define=DOOM_EPISODE_RENDER_SMOKE=true
```

The smoke target is developer-only. Rebuild the ordinary `lib/main.dart` target
afterward before handing off the application.

## Native original E1M1 replay

The release target `tool/e1m1_live_replay.dart` completed all 2,151 commands
through the normal fixed-tick runtime on Impeller Metal, with zero dropped
tics, hash `0x36d1d056`, health 66, armor 88 and 6/6 kills. After the first
120 frame samples were excluded, 7,245 Flutter total-span samples measured
p95 2.703 ms, p99 4.014 ms and zero 16.667 ms deadline misses.

This run preceded the final weapon clip-depth/CPU-culling correction: the
automatic replay passed but visual inspection still found the weapon missing.
The developer replay also synchronously plans its command stream before
showing the scene (about 48 seconds in this native run); that setup frame is
excluded, not hidden as gameplay performance. Normal startup does not run the
route planner.

## Final visible startup and firing

The ordinary `lib/main.dart` release target was rebuilt after all weapon fixes.
Native Metal visual inspection confirms original E1M1 auto-starts with the
pistol visibly at the bottom center; a primary click changes ammo 50 to 49,
then the gun returns to idle with no lingering flash. The runtime retains the
original IWAD as the default content.

The final Wasm/WebGPU release also renders original E1M1 with the pistol visible
in Codex's in-app browser. The pause screenshot shows `SELECT LOCAL IWAD` only
inside that menu. The build audit confirms a Wasm-only bootstrap and no
`main.dart.js` fallback; `main.dart.wasm` is 1,979,069 bytes. This browser check
proves startup/menu rendering, not a browser playthrough or performance budget.
The temporary browser tab and native test windows were closed after testing.

## Still required

Normal-gameplay start-to-exit command streams and independent replay verification
for E1M2–E1M9, including secret-exit traversal and the complete E1M8 boss route.
The Codex goal must remain active until that evidence exists.
