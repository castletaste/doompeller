# Episode verification — 2026-09-06

Production continuation from `7bc0245`, then `85fe080`. Original local DOOM1.WAD, 4,196,020
bytes, MD5 `f0cefca49926d00903cf57551d901abe`. This report is not a claim that
every level has been completed.

## Evidence boundaries

- The pinned original E1M1 route uses normal medium-skill gameplay with enemies:
  2,151 commands, current hash `0x59c769da`, health 66, 6/6 kills. Its original-WAD
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

`flutter analyze` is clean; root Flutter suite passes 239 tests. Pure-Dart
core passes 174 tests, WAD passes 139, and geometry passes 128 (3 intentionally skipped):
680 passing tests in total. The project contract audit passes. Package analyzers
and shader bundle regeneration passed in the preceding production verification;
no shader or dependency changed in the subsequent dropped-item correction.
No external review finding is accepted without checking its
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

## Enemy drops and original E1M2 replay

The post-`85fe080` correction creates dropped clips and shotguns at the enemy's
exact fixed-point death coordinates, on the current sector floor. Dropped items
have their distinct ammo amounts; their sprites are included in the atlas even
when absent from the initial map actors. Tests cover exactly-once creation,
fractional coordinates, a raised floor, pickup amounts and sprite removal. The
E1M4 adapter probe uses original resources/geometry with an authored encounter;
it is not an E1M4 playthrough.

The E1M1 input stream is byte-identical before and after the drop correction:
2,151 commands, SHA-256
`dc82d56425fb8a29d2284a7a1d2d052db753692c42ad0db600db1d4bf006149c`.
The new actors intentionally change its hash from `0x36d1d056` to
`0x59c769da`; the 2,154-command keyboard variant changes to `0xc3964f83`.
Both original-WAD tests and the adapter replay pass. The earlier E1M1 Metal
measurements above remain historical results, not a new live run of this fix.

Original E1M2 now has a successful independent replay and a visible release
macOS Impeller Metal replay. Configuration is default medium skill, monsters
enabled, seed 0, fresh inventory; all movement and combat use `TicCmd` input.
Two fresh plain-core replays agree, and the live fixed-tick runtime agrees:

| E1M2 terminal result | Observed value |
|---|---:|
| Commands / first normal exit | 3,722 / 3,722 |
| Final hash | `0x4d7f66f0` |
| Health / armor | 16 / 0 |
| Kills | 24 / 41 |
| Dropped game tics | 0 |
| Retained surfaces / GPU buffers created / textures created | 187 / 202 / 6 |
| Initial upload bytes | 747,460 |
| Dynamic uploads / bytes | 152,292 / 169,416,720 |
| Warmup samples excluded / measured samples | 120 / 12,553 |
| Flutter total-span p95 / p99 | 3.354 / 4.125 ms |
| Maximum total span / 16.667 ms misses | 26.955 ms / 1 |

These are Flutter frame timings, not GPU or presented-frame timings. The
excluded setup/warmup maximum was 954.367 ms. Native logs explicitly report
`status=complete live_evidence=pass`; the visible window shows
`E1M2 REPLAY COMPLETE`, command 3722/3722 and 16% health, with an idle pistol
and no persistent firing effect. The native test window was closed afterward.

The first candidate had 109 commands after the exit and correctly failed the
live `early_exit` guard. The generator and independent preflight were corrected
to stop at the first terminal tic; the runtime guard was not weakened. The
accepted local recording is `.local/replays/E1M2-terminal.json`, SHA-256
`6fbfcb9f9deb77d18b34eec17e0c8a9dfeb2f1275f5dcaf7dfd670caa9df088d`.
Its native log is `.local/qa/episode-2026-09-06/native-e1m2-terminal.log`.
Recordings/logs remain local and ignored. The disposable planner and live
entrypoint remain in the temporary worktree and were not promoted to production.

The core fix received Sol review and root inspection. A bounded Opus review
timed out without delivering a review; it is not counted as approval.

After replay testing, the ordinary `lib/main.dart` macOS release was rebuilt
and visibly opened original E1M1 with its pistol and no startup picker. An
external `DOOM_WAD_PATH` override into the checkout failed under the app sandbox;
the normal launch with that override unset correctly loaded the bundled original
WAD. README now distinguishes those paths without weakening file-read errors or
entitlements. The Wasm/WebGPU release was rebuilt and audited as well:
`main.dart.wasm` is 1,979,291 bytes, with no dart2js fallback. This last web build
was not subjected to another browser playthrough.

## Still required

Normal-gameplay start-to-exit command streams and independent replay verification
for E1M3–E1M9, including secret-exit traversal and the complete E1M8 boss route.
The Codex goal must remain active until that evidence exists.
