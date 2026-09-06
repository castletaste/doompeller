# Episode verification — 2026-09-06

Production continuation from `7bc0245`, `85fe080`, `3106b9c`, then `89063ed`. Original local DOOM1.WAD, 4,196,020
bytes, MD5 `f0cefca49926d00903cf57551d901abe`. This report is not a claim that
every level has been completed.

## Evidence boundaries

- The pinned original E1M1 route uses normal medium-skill gameplay with enemies:
  2,175 commands, current hash `0xaac341ce`, health 84, 6/6 kills. Its original-WAD
  regression also verifies transfer of the final inventory into original E1M2.
- Original E1M2 and E1M4 also have input-only, default-loadout medium-skill
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

## Automated checks

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

## Switch 103 opens and stays open (current)

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

## Still required

Normal-gameplay start-to-exit command streams and independent replay verification
for E1M3 and E1M5–E1M9, including secret-exit traversal and the complete E1M8 boss route.
The Codex goal must remain active until that evidence exists.

With switch 103 corrected, E1M3 reaches its yellow key alive at tic 1,408,
31 HP, hash `0x639a728b`, with an exact fresh replay. It returns through the
previously blocked door and crosses line 568 at tic 1,745 with 41 HP, but the
current blue-key approach dies in combat at tic 1,890. It has not reached the
normal or secret exit. E1M8 reaches its first Baron encounter at tic 2,601,
92 HP, 104 chaingun bullets and eight kills, hash `0x0efc5896`, after the
barrel trap, armor/weapon collection, pursuit combat and the tag-6 lift.
Neither that checkpoint nor E1M5/E1M6/E1M7/E1M9 failed runs prove completion.
E1M6's authored medikit-and-retreat tactic survives its red-key/tag-10 ambush at
tic 1,167, 48 HP, eight kills, hash `0x1e671cdc`; fresh replay and a repeated
run agree. It has not been continued to an exit.

Separate confirmed gameplay follow-ups remain: blue armor currently saves the
same fraction as green armor, and ammo/backpack capacity rules are incomplete.
They require their own focused inventory and episode-carry regressions; they
were not bundled into the monster-cadence correction.
