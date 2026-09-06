# Episode verification — 2026-09-07

Production continuation from `7bc0245`, `85fe080`, `3106b9c`, `89063ed`, then `f3bd4d1`. Original local DOOM1.WAD, 4,196,020
bytes, MD5 `f0cefca49926d00903cf57551d901abe`. This report is not a claim that
every level has been completed. The current combat correction after `cb84aa6`
supersedes the earlier replay identities; those results remain historical.

## Current monster spread and portal sight correction

POSS now fires one spread ray and SPOS fires three independent spread rays.
Every pellet consumes two angle draws and one damage draw, including misses.
Open two-sided movement-blocking rails no longer block sight or wall-impact
traces. Sight clips a target-body vertical interval through every crossed
portal; incompatible successive openings cannot each independently grant sight.
Movement collision flags and actor-state cadence are unchanged. Behavior was
checked against the original [enemy attacks](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_enemy.c)
and [sight rules](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_sight.c).
This does not claim complete vanilla vertical hitscan/autoaim parity.

Independent tests cover seeded misses, distinct shotgun pellet impacts,
missed-pellet RNG consumption, single action-frame firing, rail collision vs
visibility, wall-puff placement, partially visible targets, closed walls, and
cumulative vertical occlusion. The new defect tests fail on the old core.
Two independent test owners and a separate read-only Sol review checked the
source correction. The attempted Opus review failed before running with
`unreadable_encrypted_agent_task`; it is not an Opus approval.

Current checks: root Flutter 241 PASS, core 190 PASS, WAD 139 PASS, geometry
128 PASS with 3 intentional skips (698 passing tests). All four analyzers and
the project-contract audit pass. E1M1 preflight remains `READY WITH FALLBACKS`:
2,800 triangles, zero unmatched/degenerate edges/triangles and T-junctions,
six fallback sectors with area delta 51.40640861486281. No geometry changed.

| Current original-map proof | Tics | Health / armor | Kills | Hash |
|---|---:|---:|---:|---|
| E1M1 input-only and native Metal replay | 2,160 | 84 / 97 | 6/6 | `0x9c565b42` |
| E1M1 keyboard-input route | 2,155 | 80 / nonzero | 6/6 | `0x55608565` |
| E1M2 input-only, two fresh strict replays | 3,880 | 19 / 0 | 23/41 | `0x4105ae29` |

All use default medium skill, monsters enabled, seed 0, and default starting
inventory. E1M1 still proves ARM1 pickup, door, lift, damaging floor and normal
exit. E1M2's first normal exit is exactly its final command; an independent
verifier additionally checks legal button bits, command ranges, default inventory
and survival throughout. Its new recording and planner remain in the disposable
`replay_m2_spread` directory, not production code.

The current E1M1 release executable logged Impeller Metal and completed all
2,160 commands through the ordinary Flame update/render path with the expected
hash and zero dropped tics. It created 86 surfaces, 94 GPU buffers and six
textures; initial upload was 386,364 bytes, followed by 12,026 dynamic uploads
(19,564,640 bytes). After 120 warmup samples, 7,246 `FrameTiming.totalSpan`
samples had p95 2.747 ms, p99 3.980 ms, max 5.262 ms and zero >16.667 ms spans.
These are Flutter timings, not GPU or presented-frame measurements. The first
warmup span included a 48.622 s vsync delay, and foreground focus throughout
was not verified. This is not an all-foreground 60 FPS acceptance claim.
Log: `.local/qa/episode-2026-09-06/native-e1m1-spread.log`.
Current GUI inspection is unverified: agent-device 0.20.3 timed out on both
accessibility capture and the screenshot retry. Opening by bundle ID also
launched the separately registered Debug build; that process is not release
evidence. Both identified test processes were closed. No screenshot or manual
playthrough is claimed for this correction.

The old E1M2/M4/M8 input recordings diverge under corrected RNG/sight and die
at tics 2,072/1,322/1,379 respectively, identically on two fresh attempts.
Their former native-success evidence cannot be reused for this core revision.
Only E1M2 has been regenerated so far. The bounded new M4 planner attempt was
stopped after about 150 seconds without producing a recording; it is not a
gameplay completion or a demonstrated engine defect. E1M3/M5/M6/M7/M9 partial
checkpoints below are likewise historical, not current replay guarantees.

## Evidence boundaries

- The previous original E1M1 route used normal medium-skill gameplay with enemies:
  2,175 commands, historical hash `0xaac341ce`, health 84, 6/6 kills. Its original-WAD
  regression also verifies transfer of the final inventory into original E1M2.
- Original E1M2, E1M4 and E1M8 also have input-only, default-loadout medium-skill
  terminal recordings, independently replayed from fresh state. Their exact
  source revision and live-render evidence are recorded below.
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

## Earlier automated checks (before the current combat correction)

`flutter analyze` is clean; root Flutter suite passes 241 tests. Pure-Dart
core passes 181 tests, WAD passes 139, and geometry passes 128 (3 intentionally skipped):
689 passing tests in total. The project contract audit passes. Package analyzers
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

## Enemy drops and original E1M2 replay at `3106b9c` (historical)

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

## Corrected monster action cadence at `89063ed`

The subsequent replay work exposed a gameplay defect: full-speed monster chase,
reaction counters and attack decisions ran every game tic even though the walk
states last two to four tics. Look and Chase now run on state entry, as described
by the original [actor states](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/info.c)
and [state dispatcher](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_mobj.c).
Dividing movement speed alone would not correct the accelerated attack decisions
or random-number consumption.

Initial actor construction assigns the spawn frame without running its action;
this avoids accessing the player before all THINGS are initialized. Later
transitions dispatch once, including the first Chase entered by Look. Disabled
AI still allows animations, effects and death callbacks. Exact timing,
monster-before-player construction and disabled-AI tests pass; Sol independently
reviewed the state-entry lifecycle. No public API or replay-schema field changed.

An input-only probe of unchanged original E1M9 walks out of spawn for 40 tics,
then waits for 70. The old `85fe080` core produced 234 cadence violations among
237 compared movement intervals; the fixed core produces zero among 61.
The root regression requires actual observed pursuit, so an idle, occluded
spawn cannot pass vacuously. These are timing probes, not E1M9 completion.

The unchanged E1M1 route generator now emits 2,175 commands, hash `0xaac341ce`;
its keyboard-sampled variant emits 2,157 commands, hash `0x41a2a970` (82 HP).
Both retain armor/door/lift/damage/collision/all-kills checks and match two fresh
replays. The historical 2,151-command stream dies on the new rules instead of
exiting; its old success and timing remain historical. No old pin was simply
relabelled as a passing replay.

The new E1M1 release Metal replay also completed visibly and matched the core:
2,175/2,175 commands, hash `0xaac341ce`, 84 HP, 97 armor, 6/6 kills, zero dropped
tics. The final screen shows the exit switch and an idle pistol. Its 7,243
post-warmup Flutter total-span samples measured p95 2.708 ms, p99 3.683 ms,
maximum 6.830 ms and zero 16.667 ms deadline misses. There were 86 surfaces,
94 created buffers, six created textures, 386,364 initial upload bytes and
12,103 dynamic uploads totaling 19,710,880 bytes. The excluded setup maximum
was 48,869.957 ms because this developer target synchronously generates its
route; ordinary startup does not. These are not presented-frame/GPU timings.
Log: `.local/qa/episode-2026-09-06/native-e1m1-cadence.log`.

The regenerated E1M2 stream also passed independent fresh replays and the live
release Metal target, with first normal exit exactly on the last command:

| E1M2 result at `89063ed` | Observed value |
|---|---:|
| Commands / hash | 3,677 / `0xc6d1affc` |
| Health / armor / kills | 4 / 0 / 23 of 41 |
| Dropped game tics | 0 |
| Surfaces / created buffers / created textures | 191 / 206 / 6 |
| Initial upload bytes | 748,788 |
| Dynamic uploads / bytes | 155,659 / 167,137,520 |
| Warmup excluded / measured samples | 120 / 12,435 |
| Flutter total-span p95 / p99 / maximum | 3.499 / 4.139 / 25.974 ms |
| 16.667 ms deadline misses | 1 |

The excluded setup maximum was 834.988 ms. The visible final window shows
`E1M2 REPLAY COMPLETE`, 3677/3677, 4% health and the idle pistol. Log:
`.local/qa/episode-2026-09-06/native-e1m2-cadence.log`. The accepted local input
record is `.local/replays/E1M2-cadence.json`, SHA-256
`d10ee236f16d015d6604abb939dbf90b1f60186dc06dd75501566733c57cff42`.
The old 3,722-command stream no longer reaches the exit under corrected AI;
neither its old hash nor its old frame measurements are current evidence.

## Switch 103 opens and stays open (historical replay evidence)

Original E1M3's yellow-key return route exposed a wrong special classification:
line 535 is special 103, tag 10. Its door sector 121 opened to ceiling 172 but
then returned to floor/ceiling 64, blocking the return across line 532. This was
not a requirement to race a timed door: original [switch dispatch](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_switch.c)
defines 103 as S1 open-and-stay, 61 as repeatable open-and-stay, and 63 as
repeatable open-wait-close.

The core now dispatches 103 to open-stay, preserving one-shot consumption and
pressed switch state. The corrected public constant is `switchDoorOpenStayOnce`;
the old misleading name remains a deprecated alias for source compatibility.
Before the fix, the new core regression failed at ceiling 64 instead of 172;
61/63 already passed. All three now pass repeated deterministic replays.

The original-WAD component probe retains every E1M3 geometry/special lump and
places a single player on the switch's front side. It observes actual switch
535 activation and ceiling 172 throughout 700 idle tics, with no button reset
or second activation. This authored-spawn probe is not a full-level replay.
Sol independently reviewed dispatch, one-shot state and hashing, and reran the
60 core specials tests plus the original E1M3 probe. A bounded Opus CLI smoke
check failed because its OAuth session had expired; no Opus approval is claimed.

The E1M1 full input and keyboard tests retain hashes `0xaac341ce` and
`0x41a2a970`. The unchanged 3,677-command E1M2 recording still exits on its final
command with 4 HP in two fresh core runs, but its hash is now `0x36a3ec92`.
The accepted local record is `.local/replays/E1M2-switch103.json`, SHA-256
`4885e5e7c93a7f122ca756723dd661964db8e864e376f3e26862c47dc3fc05fb`.
Its command array is unchanged from the cadence record (canonical JSON SHA-256
`3db99ec9a479e3ad2c42d6902821e9dc9ee160424ba8b9356bb1e2d0dfe59529`).
The first native build attempt rejected a multiline compile-time replay value;
minifying the developer-only define fixed packaging without changing any input
command. The fresh release macOS run confirms Impeller Metal and visibly reaches
`E1M2 REPLAY COMPLETE`: 3,677/3,677 commands, hash `0x36a3ec92`, 4 HP, zero armor,
23/41 kills, and zero dropped game tics. Log:
`.local/qa/episode-2026-09-06/native-e1m2-switch103.log`.

It retained 191 surfaces, created 206 buffers and six textures, and uploaded
748,788 initial bytes plus 167,091,600 bytes in 155,488 dynamic uploads. After
120 excluded warmup samples (worst setup span 574.368 ms), 12,449 Flutter
`FrameTiming.totalSpan` samples measured p95 1.739 ms, p99 2.010 ms, maximum
17.058 ms and one 16.667 ms deadline miss. The window was explicitly raised
by command 1,259; earlier samples include background time. These are diagnostic
whole-run timings, not an all-foreground benchmark, GPU timings, presented-frame
measurements or a 60 FPS guarantee. The successful test process was closed.

The ordinary Wasm/WebGPU release was rebuilt and audited: `main.dart.wasm`
1,979,471 bytes, original bundled WAD 4,196,020 bytes, no dart2js fallback.
This is build evidence, not a new browser playthrough.

## Original E1M4 strict replay

The disposable planner now produces a complete original E1M4 command stream:
6,871 commands, normal exit exactly on the last command, 56 HP, hash
`0x2d9975d8`. It starts with the unmodified map, default pistol inventory,
medium skill, enabled monsters and seed zero. The route collects a dropped
shotgun, supplies, chaingun, blue key and yellow key, opens lines 571/564 and
uses exit line 554. Only `TicCmd` input changes gameplay state.

An independent Sol reviewer inspected the generator and its imported planner,
finding no direct changes to player position, health, inventory, original map
or game configuration. The mutable planning-sector mirror is separate from the
simulation. Two reviewer processes each ran two fresh strict replays; root ran
the verifier separately as well. All agree on the terminal tic, health and hash.
The generator itself is not rerun by the read-only verifier.

Accepted local record: `.local/replays/E1M4-switch103.json`, SHA-256
`ea26c7318c130ed35d464970a89f8ffa431e7bb0085418652854ef96934609d3`.
Canonical command-array SHA-256:
`106da2de1415865fbcf86f039be6ac0a7ca60a4503dbf816810439645dc5c6b3`.
Planner, recording and developer replay target remain local spike artifacts,
not production code or release assets.

The new release macOS target also completed visibly on Impeller Metal, with
the ordinary fixed-tic `DoomRuntimeGame` consuming replay-exclusive input:

| E1M4 live result | Observed value |
|---|---:|
| Commands / final hash | 6,871 / `0x2d9975d8` |
| Health / armor / kills | 56 / 100 / 39 of 54 |
| Dropped game tics | 0 |
| Surfaces / created buffers / created textures | 169 / 228 / 6 |
| Initial upload bytes | 700,176 |
| Dynamic uploads / bytes | 157,998 / 129,560,640 |
| Warmup excluded / measured samples | 120 / 23,422 |
| Flutter total-span p95 / p99 / maximum | 3.268 / 4.620 / 26.573 ms |
| 16.667 ms deadline misses | 1 |

The excluded setup maximum was 3,341.058 ms. The window was raised near the
beginning and explicitly focused by clicking its container late in the run;
foreground was visually confirmed at command 5,570 and at completion. The click
did not affect the replay: its final hash still exactly matches the plain core.
Whole-run frame samples can include background time and are not an all-foreground
benchmark, GPU/presented-frame timing or a 60 FPS guarantee. The visible final
screen shows the exit switch, both keys, 100% armor, 56% health and an idle shotgun.
Log: `.local/qa/episode-2026-09-06/native-e1m4-switch103.log`. The test window was
closed afterward; the ordinary `lib/main.dart` release target is restored.

## Original E1M8 boss route and foreground-start native replay

Production source remains `f3bd4d1`; no gameplay or renderer change was needed
for this route. The disposable driver records 8,416 commands from the original
spawn with medium skill, monsters enabled, seed 0 and the default loadout.
Both Barons are dead at tic 7,097 (92 HP, ten kills, hash `0x27681527`). The
tag-666 floor lowers, switch 233 builds the tag-9 stairs, and the teleporter
leads to the damaging exit sector. The first and only normal exit occurs on
the final command: tic 8,416, 8 HP, 60 armor, ten of 27 kills, hash `0xaf3e0376`.
Two fresh recorded-command replays agree; a separate root-agent invocation of
the strict replay verifier repeats both runs and obtains the same result.

The initial suspicion of a broken stair special was disproved. An isolated
original-map component probe and temporary instrumentation showed that the
spike approach helper could exhaust its loop without sending `Buttons.use`.
Correcting that driver made the existing production stair implementation work.
This is a planner fix, not a production engine fix. Instrumented and no-monster
diagnostic runs are not the accepted command stream.

Accepted local recording: `.local/replays/E1M8-f3bd4d1.json`, SHA-256
`e6c71e777519274b3cd1d257f40baef810e3428c651cfdd3c675d51bf8e669b3`.
The native harness validates command bounds, the default starting inventory,
the first-exit-last invariant, health, kills and final hash before rendering.
The first packaging attempt passed raw telemetry as compile-time definitions
and exceeded macOS argument limits. The accepted build instead transports
exactly the same JSON through a round-trip-checked gzip/base64 definition:
391,484 JSON bytes become 24,284 encoded characters. This changes neither the
recording nor gameplay, and exists only in the disposable native harness.
The accepted build definitions are `.local/replays/E1M8-f3bd4d1-defines.json`
(also retained as `E1M8-f3bd4d1-defines-gzip.json`); the failed raw-definition
file is kept separately with the failed-build evidence.

Release macOS run through the ordinary `DoomRuntimeGame`, Flame renderer and
fixed-tick driver: **PASS**, with Impeller Metal explicitly confirmed in the
log. A harness-only `START REPLAY` button allows foregrounding before mounting
the game; the waiting screen is outside the frame-recording window. Foreground
and progress were visually checked at startup, commands 3,028 and 6,175, and at
completion. The displayed final state is `E1M8 REPLAY COMPLETE`, 8% health,
60% armor and an idle chaingun under the final exit-sector damage tint.

- Commands/tics: 8,416/8,416; hash `0xaf3e0376`; dropped tics: 0.
- Renderer: 75 surfaces, 128 created GPU buffers, six textures,
  255,766 initial upload bytes; 141,880 dynamic uploads / 76,552,080 bytes.
- Frame window: 120 warmup samples excluded, then 28,724 samples.
  Flutter `FrameTiming.totalSpan`: p95 1.612 ms, p99 2.037 ms, maximum 36.149 ms;
  four samples exceed 16.667 ms. Worst excluded warmup: 51.256 ms.
- These are Flutter frame-span measurements on this observed route, not GPU
  timestamps, presented-frame measurements or a guarantee for every level.

Log: `.local/qa/episode-2026-09-06/native-e1m8-f3bd4d1.log`.
The test window was closed after verification. No test browser tab was opened.
The ordinary `lib/main.dart` release target was rebuilt and launched afterward:
it immediately rendered original E1M1 with 50 bullets, 100% health and the pistol,
without an initial picker or the replay harness screen. Its pause/resume overlay
also opened. That control-run window was closed as well. Logs:
`.local/qa/episode-2026-09-06/native-after-e1m8-default-build.log` and
`.local/qa/episode-2026-09-06/native-after-e1m8-default.log`.

## Still required

Current-core normal-gameplay start-to-exit command streams and independent
replay verification for E1M3 through E1M9, including secret-exit traversal;
fresh native-render verification beyond E1M1. Only episode one is present in
the supplied DOOM1.WAD, so the wider original-Doom goal also lacks E2/E3 input.
The Codex goal must remain active until that evidence exists.

The remaining checkpoint details below describe the prior core revision.

With switch 103 corrected, E1M3 reaches its yellow key alive at tic 1,408,
31 HP, hash `0x639a728b`, with an exact fresh replay. It returns through the
previously blocked door and crosses line 568 at tic 1,745 with 41 HP. The newer
route activates line 1020 before approaching the blue key, raises the bridge,
and reaches tic 2,338 at (-669, -752), 27 HP, hash `0x1bc86fd0`, with an exact
fresh replay. The next attempted passage dies in hitscanner crossfire. Neither
the normal nor secret exit has been reached.

E1M5's yellow-room route now crosses sectors 92, 91, 79, 78 and 63 without
crossing the one-sided wall that invalidated the earlier planner. Its exact
fresh-replayed checkpoint is tic 8,374, 95 HP, yellow key, hash `0x20293768`.
The newer saved checkpoint activates switch 189: tic 9,240, 49 HP, yellow
key, sector 21, hash `0xa508e99a`, repeated in two fresh simulations. Sector
82 is opening (floor 0, ceiling 44 at that tic); this is not a blue-key or
level-exit claim. A later two-fresh-replay prefix reaches sector 127 at tic
11,060, 18 HP, yellow key, hash `0x8f991e6c`. The next attempt dies in combat
before sector 128; blue and the exit remain unproven.

E1M6's authored medikit-and-retreat tactic survives its red-key/tag-10 ambush at
tic 1,167, 48 HP, eight kills, hash `0x1e671cdc`; fresh replay and a repeated
run agree. Continuation reaches tic 5,231 with red and blue keys, 100 HP,
71 armor, 45 kills and hash `0xeabea644`, verified by replaying the entire input
prefix from startup. A longer failed run remains alive at tic 16,000 with hash
`0xf0d2cff1` but loops around a lift. Further planner investigations found stale
blocked-cell memory and a manual-door helper that could turn back through a
door after momentum had already crossed its threshold. None of these failed
or partial runs proves a level exit.

The newer E1M6 route resolves the yellow-key prerequisite: crossing line 460
lowers sector 151 from 192 to 48; manual door 1119, the small stairs and blue
door 1139 then become traversable. Two fresh input replays confirm all three
keys at tic 5,935, 37 HP, 100 armor, hash `0xeb3374ee`; and passage through
yellow door 1089 at tic 6,775, 38 HP, hash `0xd0cfd863`. The route subsequently
activates both S103 switches 822/tag 1 and 599/tag 3. Its independently repeated
input-only final-room checkpoint is tic 7,939, 37 HP, 87 armor, sector 20,
hash `0x23ca4252`. This is not a complete E1M6 replay: subsequent attempts die
in the final-room fight before exit 627. No native E1M6 render or frame result
is claimed from these command-only checks.

All of these changes are confined to the disposable input driver. The
production core remains `f3bd4d1`. Two additional bot failure modes were
identified: a kill-count change can exhaust the driver's route-retry budget
despite actual progression, and navigation can keep pushing into a melee
enemy instead of retreating between shots. An attempted eastern-pit shortcut
was rejected correctly by production collision: lines 736/981/982 carry
`ML_BLOCKING` (flags 5), despite being two-sided with sufficient vertical
clearance. A sector graph that ignores that bit is not evidence of a core
collision defect. E1M7 and E1M9 also remain incomplete.

E1M7 now crosses yellow door 905, triggers the tag-9 lift through line 248,
and enters the red-key room through line 644. The saved two-fresh-replay
checkpoint is tic 6,210, 23 HP, 40 armor, 39 kills, yellow key, sector 73,
hash `0xa50c9298`. The subsequent route bypasses the room's one-sided wall
652, but dies in the red-key fight; neither red nor blue is claimed collected.

E1M9's saved two-fresh-replay checkpoint reaches both yellow and red keys:
tic 829, 93 HP, shotgun, 15 of 72 kills, hash `0x2df9f32a`. The next combat
cluster prevents the attempted continuation. Its no-monster topology checks
are not accepted gameplay evidence, and neither blue nor an exit is claimed.

All new checkpoints above use original DOOM1.WAD, medium skill, monsters,
seed 0 and input replay from the default spawn/loadout. The local WAD was
rechecked at 4,196,020 bytes with MD5 `f0cefca49926d00903cf57551d901abe`.
The E1M6 final-room prefix was additionally reviewed and repeated
by a separate agent: 7,939 commands, hash `0x23ca4252`; its input-only JSON
SHA-256 is `b0650dcad678c9134f552619861ec6d3c47e87409e80b23ecfa5712a897237c0`.

Separate confirmed gameplay follow-ups remain: blue armor currently saves the
same fraction as green armor, and ammo/backpack capacity rules are incomplete.
They require their own focused inventory and episode-carry regressions; they
were not bundled into the monster-cadence correction.
