# Web audio verification — 2026-09-09

**Numeric fidelity and runtime checks pass. Listening acceptance is pending.**

Production implementation starts from `61818662fee3d6d90f788c9af0950a0218eec181`.
The local original shareware IWAD is 4,196,020 bytes, SHA-256
`1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771`.
The reference implementations and WAD-derived traces/audio remain in ignored
local evidence directories; they are not runtime dependencies or repository assets.

The musical frontend passes the pinned Chocolate Doom `opl_doom_1_9`/OPL2
register oracle at 49,716 Hz. All 11 required tracks (`D_E1M1`–`D_E1M9`,
`D_INTER`, `D_VICTOR`) and the extra `D_INTRO` have exactly matching ordered
register streams over 300 seconds each; every horizon crosses at least one
loop. Seven synthetic cases cover pitch, volume, sustain, voice stealing,
percussion, double voices and looping. All 16,384 note/bend combinations and
16,256 channel-volume/velocity combinations match the oracle. See the
[table provenance and trace command](../packages/doom_music/tool/DMX_TABLE_PROVENANCE.md).

The parser includes the reserved word at offsets 14–15 in the physical
16-byte MUS header. An authored regression checks that this word is excluded
from the declared instrument list; all 147 WAD-package tests pass. After this
correction, all 12 original 300-second register traces were re-rendered and
remain exact (summary SHA-256
`38dfbc6e361be8e39aa3b8f8ee791d21bc6878014df725c46a359d168cd2054c`).
The seven behavior fixtures and eight exhaustive sweep inputs also pass again;
their new summary SHA-256 is
`820fa41af48525388f3995d1daee3509fcf6ee15041b7e84218ec6f5b912cd25`.

The content-inclusive app suite passes **321 tests**. Original E1M1 remains
2,160 tics with hash `0x9c565b42`, including the FakeGPU adapter replay;
keyboard acceptance remains 2,155 tics with hash `0x55608565`. The existing
native ownership/protocol tests pass in the same suite. Root Flutter analysis
is clean. The actual JavaScript worklet has three passing Node protocol tests;
the artifact-policy tests pass all five cases, including missing audio assets.
Shared production-state tests cover bounded replacement, pause behind pending
resume, requested-rate constructor fallback, and late events after transport
failure/disposal.

Register equivalence does not establish waveform equivalence. PCM comparisons use the
same native sample rate, sample-zero alignment, no trimming and no gain fit.
Required limits include 1 cent steady pitch, envelope landmarks within
max(1 ms, 2% of the interval), p95 RMS-envelope difference at most 1 dB, and
p95 log-STFT magnitude difference at most 1 dB. The spectrum uses a 2,048-frame
Hann window, 256-frame hop and the union of each signal's active bins above
−60 dBFS and within 40 dB of its local peak. Numeric gates do not replace the
separate listening check, which remains open.

The full 300-second PCM corpus, on core SHA-256
`a188e39613c6d05cd3e73d0465269729761b80698800e990f33fc30ccc97512d`,
passes both dB gates for all 11 required tracks. The worst spectrum p95 is
0.313376 dB (D_INTER); the worst RMS-envelope p95 is 0.016449 dB (E1M4).
Every track crosses a loop, and none has reference or produced clipped frames.
The hash-fenced local corpus summary has SHA-256
`65f631ab41747af0cae5836295b53b7348391af65e11a87c11912fd162083491`.
All 31 music-package tests and its analyzer pass; the content-inclusive app
suite was rerun after the parser correction and still passes all 321 tests.
All 11 complete PCM streams are byte-identical between the Dart VM and compiled
WebAssembly: 164,062,800 mono s16 samples in total. The parity report SHA-256 is
`c99027d300221497f3e253655c6ca2df468c1a7becc65fe6c302fd9e6b85e6fc`.

Authored regressions cover history-sensitive envelope transitions as well as
fresh notes: zero-rate decay can reach sustain, and a live sustain-level write
matches the current 16-step attenuation band without increasing its amplitude.
The original VICTOR reduction has 117 register writes; after the corrected
transition, every post-transition sample matches the oracle. Rare transient
differences remain in the full corpus, so this is not a claim of chip-wide
bit-exact YM3812 emulation for arbitrary register sequences.

Independent authored active-vibrato probes cover all seven nonzero FNUM
high-bit groups, shallow/deep depth and two complete LFO cycles. Maximum
measured pitch difference is 0.011132 cent; each PCM stream differs by at most
one s16 unit. The one-second envelope fixture is byte-identical to the oracle,
including its measured attack/release landmarks, and live envelope changes
first affect frames 580 and 801 in both implementations. These claims apply
to those covered rates and transitions; the full corpus provides the broader
numeric acceptance gate.

The first browser transport checkpoint exercised the actual production session,
Wasm worker and AudioWorklet with synthetic MUS/GENMIDI/PCM inputs:

- Before a trusted gesture, the context was suspended at 49,716 Hz, eight
  music blocks were queued, no music frames had played, and a dropped effect
  completed without occupying a channel.
- Main-thread stalls of 500 ms and 2 seconds left music underruns at zero.
  One hundred synchronous score replacements produced one final configuration
  after the active work; no pending configuration or retirement remained.
- Pause kept exactly 9,743,616 played frames across repeated observations.
  Resume, replacement after stale-lease disposal and lifecycle focus recovery
  resumed progress. This did not capture the intermediate focus-suspended state.
- Malformed MUS produced a typed failure; effects still completed. A real
  uncaught worker failure disabled music while effects continued. Disposal
  closed the context and left no active voices or cached PCM buffers.

These are transport observations, not original-WAD sound or perceptual proof.
The first checkpoint exposed stale diagnostic counters after failure/disposal;
those paths were subsequently changed. The completed follow-up confirmed that
malformed MUS preserves effects (3/3 completions), stale-lease disposal preserves
the successor (4/4), focus recovery works (6/6), and a real worker crash clears
music diagnostics while effects still complete (7/7). Three post-disposal
observations show a closed context, zero voices/cache entries, no pending
commands and no reappearing music counters. This checkpoint's main Wasm SHA-256
is `a6ea7024b6f4b808a01de60bab63fbb805ccff3f4e023c16b47f617623da59b1`.
Two earlier follow-up attempts crashed the browser tab on START with forced
Flutter semantics enabled; the normal Flutter harness mode completed. Pending
autoplay transition ordering is covered by tests of the shared production state
class; it was not reproduced as an unresolved browser `resume()` promise.

A native macOS debug build passes. This is compilation evidence only; no new
native audible-output check is claimed. Original E1M1 also rendered in the
browser, and the pause music slider changed independently of the effects slider.
The final release build passes its artifact and project-contract checks. A
browser probe using that exact music worker confirmed original E1M1 music
progressing from 2,049,920 to 2,547,072 played frames, a seven-to-eight-block
queue and zero underruns. The screenshot at 1280×720 shows Enter firing the
pistol (ammo 50→49); the browser error log is empty. The same window reported
Flutter `FrameTiming.totalSpan` p95 2.799 ms and p99 4.176 ms over 7,168 samples
after a five-second warmup, with one sample above 16.667 ms. The histogram
includes frames before the first trusted audio gesture, and other local
validation work was running; this is a bounded smoke, not an isolated benchmark
or presented-frame timing. The final worker Wasm SHA-256 is
`9ee665ddb0f5e1239c2613e1f05f041808f91fdc23e3b97f222317527f2ff579`.
Original-rate A/B clips for every track's opening and first loop transition
are available locally for the outstanding listening check; no perceptual pass
is claimed from the numeric results or browser counters.

The subsequent CI integration fix aligns the trusted preview headers and exact
audio-file allowlist with the production bundle. All 35 trusted-policy tests
and five artifact tests pass. Worker compilation now stages its auxiliary
files outside the web bundle and omits source maps. The resulting worker
SHA-256 is `929983c10a87721185a8c8a63f573199535e47340612a6dec4ee6d0b056922ce`;
all non-custom Wasm sections are byte-identical to the browser-tested worker
above. The real release archive passes packing and the updated preview
sanitizer. Automatic preview publication still uses the policy from `main`,
which rejects these new audio assets until that policy is updated there.

---

# Architecture refactor verification — 2026-09-07

Refactor of baseline `d12073a`, integrated with main `6e8ba73` in `67f82ef`;
see [runtime boundaries](ARCHITECTURE.md). Main's Enter/touch controls and CI
policies are retained.
The results in this section were rerun on the refactored worktree. Existing
per-map recordings were reused as inputs; their original capture evidence is
retained below.

- App: `dart run tool/test.dart` **266 PASS** without an IWAD;
  `dart run tool/test.dart --include-content` **302 PASS**, using the ignored
  local original DOOM1.WAD. Content is read directly and is not copied into the
  temporary Flutter test asset bundle.
- Packages: `doom_core` **190 PASS**, `doom_geometry` **129 PASS / 3 opt-in stress
  skips**, `doom_wad` **139 PASS**. **760 tests pass** across packages and the
  content-inclusive app suite; synthetic tests are a subset, not additional.
- Root Flutter analyzer and all three package analyzers: no issues. Formatter
  dry run: 209 files unchanged. Project contract audit and `git diff --check` pass.
- Production E1M1 and FakeGPU adapter replay: **2,160 tics, `0x9c565b42`**.
  Keyboard route: **2,155 tics, `0x55608565`**. Both match the baseline.
  Native preparation also covered every episode successor and secret-map branch.
- All nine existing original E1 recordings were replayed against the refactored
  core twice, first forward and then in reverse map order. Every hash, first-exit
  tic, health and inventory result matched the pinned recording. All six negative
  verifier cases were rejected. The disposable verifier was run with this
  worktree's `.dart_tool/package_config.json`, ensuring imports used the changed
  packages. This is simulation replay evidence, not native rendering evidence.
- Admission regression: 1,000 successive requests execute only the active and
  final pending job, with peak concurrency one; 999 stale requests cannot publish.
- Geometry tests reproduce two runtimes sharing a prepared template and verify
  independent vertices, plane/wall state, texture updates and restart. Repeated
  restart plateau remains 9 surfaces, 9 buffers, 13 components, 5 actors,
  9 actor registry entries, 1 HUD listener and 1 automap listener after 30 cycles.
- Audio tests cover separate messengers/channels, replacement owners, stale
  dispose/stop/play and completion IDs, delayed replies, bounded overflow with
  critical cues retained, failure recovery and disposal after stop failure.
  Native ownership takeover also covers voices on channels the new owner does
  not reuse, delayed cleanup replies and observable cleanup failure.
- macOS Release: `flutter build macos --release --no-pub` passes (45.7 MB).
  The exact `719f61c` worktree app was opened through macOS Launch Services
  (PID 60316, executable path verified). Fresh GUI observations showed E1M1,
  Enter firing (ammo 50 to 49), pause/resume, the touch-controls switch, touch
  automap open/close and touch firing (ammo 49 to 48). Cmd+Q closed the app and
  the PID disappeared. The same build's startup log confirms Impeller Metal.
  This is a targeted smoke, not a native full-episode replay or audible-output
  test. Automation must target the worktree bundle explicitly; its bundle ID
  also identifies the separately installed app, and direct executable launches
  are not reliably recognized by XCTest.
- Wasm/WebGPU: `tool/build_web_release.sh` passes with the pinned Flutter SDK,
  including shader verification, bootstrap finalization, pins and local IWAD
  checksum. `main.dart.wasm` is 2,061,337 bytes; packaged IWAD is 4,196,020 bytes.
  The build retains the existing optional Cupertino icon-font warning.
  Three actual Chrome Wasm regressions pass: line-37 collision, corner running
  wall-slide and line-125 puff impact. These are targeted engine regressions,
  not a browser gameplay performance measurement.
- CI-policy checks: **35 Node tests**, **8 Python shareware-fetch tests** and
  **4 Python artifact tests** pass. GitHub Actions run
  [34111409455](https://github.com/castletaste/doompeller/actions/runs/34111409455)
  passed Verify and build Wasm for `719f61c`; deployment was skipped.

Pinned toolchain: Flutter 3.44.4, Dart 3.12.2, naga 30.0.1. No dependency versions,
renderer pins, native audio protocol, gameplay rules or replay schemas changed.
Web CPU-stage blocking, synchronous sprite packing and the renderer's lack of
explicit GPU disposal remain documented limitations. No native app was installed.
The production deploy job was skipped; the repository's existing PR automation
publishes a separate preview of the verified bundle.

---

# Episode verification — 2026-09-07

Production continuation from `7bc0245`, `85fe080`, `3106b9c`, `89063ed`, then `f3bd4d1`. Original local DOOM1.WAD, 4,196,020
bytes, MD5 `f0cefca49926d00903cf57551d901abe`. All nine E1 maps now have
independently repeated, input-only normal-exit recordings. The user narrowed
the replay task to E1; no E2/E3 download or verification is required for it.
This is not continuous episode traversal or full-game/native-render completion.
The current combat correction after `cb84aa6`
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
| E1M3 input-only, independently repeated strict replay | 5,927 | 42 / 1 | 53/74 | `0x07246777` |
| E1M4 input-only, independently repeated strict replay | 10,064 | 80 / 0 | 35/54 | `0xdd47f342` |
| E1M5 input-only, independently repeated strict replay | 7,819 | 44 / 116 | 80/91 | `0xd32974c7` |
| E1M6 input-only, independently repeated strict replay | 7,933 | 39 / 43 | 93 | `0xd28054b8` |
| E1M7 input-only, independently repeated strict replay | 14,565 | 40 / 75 | 76/84 | `0x14d19d2d` |
| E1M8 input-only, independently repeated strict replay | 7,328 | 7 / 57 | 12 | `0x37b5e98c` |
| E1M9 input-only, independently repeated strict replay | 8,006 | 43 / 48 | 67 | `0x8e3dca7b` |

All use default medium skill, monsters enabled, seed 0, and default starting
inventory. E1M1 still proves ARM1 pickup, door, lift, damaging floor and normal
exit. E1M2's first normal exit is exactly its final command; an independent
verifier additionally checks legal button bits, command ranges, default inventory
and survival throughout. Its new recording and planner remain in the disposable
`replay_m2_spread` directory, not production code.

A separate fail-closed verifier replayed the complete M2/M3/M4/M6/M8
recordings from freshly parsed maps, then repeated them in reverse map order.
All five retained their pinned hashes and survived every command; the first
normal exit was exactly the last command. Six deliberately invalid variants
were rejected: disabled monsters, out-of-range movement, invalid weapon slot,
stale hash, truncated stream, and an extra post-exit command. This validates
the verifier's rejection paths as well as these five recordings; it does not
count unfinished maps as passes. The gameplay package tree remains
`dde4417dda5d0988ceab0b9b5934959958b6a624`, identical to `82a9bd5`.
Local log: `.local/qa/episode-2026-09-06/current-reordered-strict-suite.txt`.
The verifier remains disposable at `tool/replay_perf/strict_suite.dart` in
the replay worktree, with no production source change.

The subsequent combined suite includes all seven completed maps
(M1/M2/M3/M4/M6/M7/M8). It passes forward and reverse-order fresh replays,
including the same six rejection cases. E1M1's unchanged production runner
was exported as ordinary commands before independent verification; its ARM1
pickup occurs at tic 346 and its final hash remains `0x9c565b42`.
Recording: `/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_perf/e1m1_commands.json`,
SHA-256 `81fd592223dd5418de9d9ccdee18b0695a36e121d4c0dc84d8038e24094c2c13`.
Combined log: `.local/qa/episode-2026-09-06/current-seven-map-strict-suite.txt`.
M5 and M9 are not counted in that suite.

E1M9 subsequently completed on the same unchanged gameplay core. Its route
uses the real tag-4 resource lift, all three keys, switch 362 opening the
tag-1 passages, blue door 533, switch 567 raising the final bridge, and the
low-side lift 587 / door 586 return. A perimeter route reaches the last
medikit and normal exit 551 on command 8,006. No sector planes or gameplay
snapshots were injected. The independent fail-closed verifier replayed the
entire stream twice from fresh default state: minimum 18 HP, final 43 HP /
48 armor, identical hash, and first normal exit exactly last. All six negative
cases were rejected. Recording:
`/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_m9_finish/lift_resource_attempt64.json`,
SHA-256 `4cbf1ccf50d0865436abe84b9523f8c1ae9af1194648c390468c9a42b0b91e5b`,
unchanged before and after verification. Independent log:
`.local/qa/episode-2026-09-06/m9-full-current-independent.txt`.
Current preflight is `READY WITH FALLBACKS`: 3,725 triangles, two meshes,
one atlas page, 5,651 total vertices, one fallback sector with area delta
0.0023374954271275783, and zero unmatched edges, degenerate triangles or
T-junctions. No missing expected resources were reported. Local log:
`.local/qa/episode-2026-09-06/m9-current-wad-report.txt`.
This is original-map input-only completion, not a new native-render or frame
performance claim. M9 normal exit does not prove the separate M3 secret exit.
The subsequent combined eight-map suite (M1/M2/M3/M4/M6/M7/M8/M9) also passes
fresh forward and reverse-order replays with identical pinned results and all
six negative cases rejected. It excludes unfinished M5 and the unproven M3
secret exit. Log:
`.local/qa/episode-2026-09-06/current-eight-map-strict-suite.txt`.

E1M5 subsequently completed on the same unchanged core. The route collects
the yellow key, takes the real blue-armor detour, activates switch 189, follows
the outer stair/ring route to the blue key, then passes the final doors and
normal exit 409. All state changes come from ordinary input. The independent
fail-closed verifier replayed all 7,819 commands twice from fresh default state:
minimum 11 HP, final 44 HP / 116 armor, 80 kills, matching hash, survival
throughout, and first normal exit exactly last. All six negative cases were
rejected. Recording:
`/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_m5_exit_rush/e1m5_commands.json`,
SHA-256 `2f886666781397cb42e4e0c9347eedff38d0932a4fd632e7d739684479f9416f`,
unchanged before and after verification. Independent log:
`.local/qa/episode-2026-09-06/m5-full-current-independent.txt`.
Preflight is `READY WITH FALLBACKS`: 5,121 triangles, 7,611/65,535 vertices,
one mesh/atlas page, three fallback sectors with area delta 107.76868818015828,
zero unmatched edges or degenerate triangles, and one T-junction diagnostic.
BSP work is 150,116/1,000,000; no missing expected resources were reported.
Local log: `.local/qa/episode-2026-09-06/m5-current-wad-report.txt`.
This does not establish pixel-perfect geometry or a rendered E1M5 playthrough.

The final combined suite includes every E1 map (M1 through M9), each from
default pistol inventory with monsters enabled. All nine pass fresh forward
and reverse-order replays with identical pinned results; all six invalid
variants are rejected. Log:
`.local/qa/episode-2026-09-06/current-nine-map-strict-suite.txt`.
This completes the user-narrowed per-map E1 replay coverage. It does not prove
continuous inventory-carrying traversal, the M3 secret exit into M9, or a fresh
native rendered playthrough of the entire episode.

E1M8 was regenerated on the unchanged `82a9bd5` gameplay core. Both Barons
are dead, the tag-666 floor lowered, the line-233 staircase reached its full
13-step profile, and the final teleport/damaging-floor exit completed on the
last command. The map-specific verifier and a separately authored verifier
both replayed the entire stream twice from fresh default state. The independent
verifier additionally checked survival throughout and default inventory.
The recording is local disposable evidence:
`/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_m8_spread/e1m8_commands.json`,
SHA-256 `7fa3c2797c6212c895cc95fab22bd4f535808b604215ae2f228dae26b32b364c`.
Independent log: `.local/qa/episode-2026-09-06/m8-current-independent.txt`.
No new native-render or foreground-frame claim accompanies this input replay.

E1M4 was also regenerated on `82a9bd5`: both keys collected, door 548 reopened
and crossed, then normal exit 554 activated on command 10,064. The full command
stream survived from default spawn/inventory in two fresh independent replays,
with the expected final hash. Recording:
`/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_m4_spread/e1m4_commands.json`,
SHA-256 `b554d4b0eae329bf2af7499a7a2ebb439ac590497ba7e0d4d4ac718a2c68a78b`.
Log: `.local/qa/episode-2026-09-06/m4-current-independent.txt`.
This is input-only proof, not a fresh native-render result. Earlier stopped
routes were planner/timing failures: direct legal movement crossed open door
776 in six tics, and prompt traversal of reopened door 548 resolved the last
gate without changing gameplay collision or door timing.

E1M6 now has a complete current-core recording as well: all three keys,
switch 599 opening sector 28, manual door 614, and normal exit 627. The first
exit is command 7,933; the player survives every preceding command. The
map-specific verifier and independent full-stream verifier each replayed it
twice from fresh default state with identical hash. Recording:
`/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_m6_finish/e1m6_commands.json`,
SHA-256 `9c3386df925b693ed5ce6f4965238bd4489c294bba5f3b3fd1f61d425ca95181`.
Log: `.local/qa/episode-2026-09-06/m6-full-current-independent.txt`.
The successful input strategy starts the final fight with 100 HP, uses cover,
then collects reachable healing before the final doors. Earlier late low-HP
attempts remain failed bot strategies, not gameplay defects. No production
source change or fresh E1M6 native-render proof accompanies this result.

E1M7 now has a complete recording on the same core: all three keys and normal
exit on command 14,565, with 76/84 kills, 40 HP and 75 armor. The independent
fail-closed verifier replayed the entire stream twice from fresh default
state, confirmed identical hashes, survival throughout (minimum 20 HP), and
first normal exit exactly last. Recording:
`/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_m7_final/e1m7_commands.json`,
SHA-256 `adf7bf3ccd34023177886a5c586eb12d08260126e767eb2b7966b3840ff73ae4`.
Log: `.local/qa/episode-2026-09-06/m7-full-current-independent.txt`.
Fresh preflight is `READY WITH FALLBACKS`: no missing textures, flats, sprites
or expected sounds; 5,168 triangles, one mesh/atlas, 7,858/65,535 vertices,
zero unmatched edges or degenerate triangles. Eighteen fallback sectors have
area delta 1630.1131288869 and three T-junction diagnostics remain. Log:
`.local/qa/episode-2026-09-06/m7-current-wad-report.txt`.
This is input-only completion and geometry diagnostics, not a native rendered
E1M7 playthrough or a pixel-perfect geometry claim.

E1M3 now also has a complete recording on `82a9bd5`: both keys, actual W1
stair trigger 967, completed real stair movers, manual door 624, and normal
exit 982 on command 5,927. The final ten stair floors are
`[56,64,72,80,88,96,104,112,120,128]`; no projected sector planes were injected
into gameplay. Waiting and fighting from covered sector 15 preserved health
while the stairs rose. The independent verifier confirms survival throughout,
default inventory, first normal exit exactly last, and two matching fresh
replays. Recording:
`/Users/savva/.cache/doompeller-replay-20260906.WFKcX4/wt/tool/replay_m3_spread/e1m3_commands.json`,
SHA-256 `5bfb0c5d2df2b15288d8ac9df1981dffe5367060880fc9a7825f38f8516b4faa`.
Log: `.local/qa/episode-2026-09-06/m3-full-current-independent.txt`.
This is input-only evidence, not a new rendered or manual playthrough.
Fresh E1M3 preflight is `READY WITH FALLBACKS`: no missing textures, flats,
sprites or expected sounds; 6,249 triangles in two meshes on one atlas page,
zero unmatched edges, degenerate triangles or T-junctions. Three fallback
sectors have total area delta 96.20179168632603. The largest surface uses
9,174/65,535 vertices and BSP work is 175,723/1,000,000. Local log:
`.local/qa/episode-2026-09-06/m3-current-wad-report.txt`.

The focused original-E1M1 regression rerun passed all 11 tests covering armor
pickup, effect lifecycle, collision, large-move tunneling, full input route,
keyboard route and retained-renderer replay lifecycle. Log:
`.local/qa/episode-2026-09-06/current-original-e1m1-regressions.txt`.
Edge-case component tests use original geometry with authored actor placement;
the adapter test uses FakeGPU. These do not provide new native GPU evidence.

The current E1M1 release executable logged Impeller Metal and completed all
2,160 commands through the ordinary Flame update/render path with the expected
hash and zero dropped tics. It created 86 surfaces, 94 GPU buffers and six
textures; initial upload was 386,364 bytes, followed by 12,026 dynamic uploads
(19,564,640 bytes). After 120 warmup samples, 7,246 `FrameTiming.totalSpan`
samples had p95 2.747 ms, p99 3.980 ms, max 5.262 ms and zero >16.667 ms spans.
These are Flutter timings, not GPU or presented-frame measurements. The worst
warmup span was 48.622 s total, including 48.596 s vsync overhead; foreground
focus throughout was not verified. This is not an all-foreground 60 FPS claim.
Log: `.local/qa/episode-2026-09-06/native-e1m1-spread.log`.
The first GUI inspection was unverified: agent-device 0.20.3 timed out on both
accessibility capture and the screenshot retry. Opening by bundle ID also
launched the separately registered Debug build; that process is not release
evidence. Both identified test processes were closed. No screenshot or manual
playthrough is claimed for this correction.
The initial follow-up doctor check reported `APP_NOT_INSTALLED`; this was
subsequently resolved by the user-approved local installation described below.

### Installed Release GUI smoke

The user approved installation at `/Applications/Doompeller.app`. The installed
main executable and underlying `App.framework/Versions/A/App` are byte-identical
to the current Release build; both bundle signatures verify. The AOT binary
SHA-256 is `31997cdd67b5e3f8f9fd31b90fa1ec04844390a6b2c4a1d408a2a710b67f6177`.
Bundled DOOM1.WAD matches the approved local input byte-for-byte. Generated
build metadata names `lib/main.dart` without replay defines; this is provenance
support, not a cryptographically bound entrypoint assertion.

Opening by shared bundle ID initially selected the old Debug build again.
That process was identified and closed. Launching the installed executable
directly, then attaching agent-device, selected PID 60243 at the exact installed
path. Its log confirms Impeller Metal. The first Debug screenshot
`installed-release-start.png` is **not Release evidence**, despite its filename.

Actual Release observations: original E1M1 starts without a picker, pause and
resume respond, W/A/D move the player, primary-button drag turns the camera,
and held fire reduces pistol ammo from 50 to 45. The later idle screenshot
shows the normal weapon frame without a persistent muzzle flash. This does
not prove every explosion lifetime, enemy facing, or collision edge case.
ARM1 pickup and full start-to-exit traversal were not reached in this GUI
attempt; their prior automated evidence is not relabelled as manual proof.
Native pause intentionally shows Resume only: the approved local-file picker
is browser-only, while desktop import UI remains outside scope.

Agent-device's delayed 96-character W sequence exceeded its main-thread
timeout; runner diagnostics show the abandoned input work drained after
37.066 seconds. A subsequent screenshot succeeded and the game log had no
new exception. This is an automation timeout, not evidence of an app crash.
Shorter zero-delay input sequences succeeded. Recording and both identified
test processes were closed; the installed application remains available.
No new frame-percentile or presented-60-FPS claim accompanies this smoke test.

Local ignored evidence under `.local/qa/episode-2026-09-06/`:

- `installed-release.log`: correct installed process and Impeller Metal.
- `installed-release-e1m1.png`: original default startup.
- `installed-release-pause-verified.png`: pause overlay.
- `installed-release-after-input.png`: moved viewpoint, 45 ammo, idle weapon.
- `installed-release-stairs-approach.png`: final partial traversal state.
- `installed-release-input.mp4`: 407.067-second encoded app-only recording
  (439.475 seconds of wall-clock session time), not a complete playthrough or
  performance benchmark.

The old E1M2/M4/M8 input recordings diverge under corrected RNG/sight and die
at tics 2,072/1,322/1,379 respectively, identically on two fresh attempts.
Their former native-success evidence cannot be reused for this core revision.
Current-core input-only completion is now independently verified for all nine
E1 maps as listed above. Failed and partial route recordings remain diagnostic
evidence, not additional full exits. The checkpoint details near the end of
this document remain historical unless explicitly marked otherwise.

The disposable planner's new canonical-linedef candidate index passed two
differential suites over all nine original maps: 83,850 swept queries per
suite, comparing every relevant line against exhaustive collision, with zero
false negatives. One suite used initial sector planes; the other closed all
portals diagnostically to exercise initially open boundaries. This is planner
component evidence, not gameplay or a production runtime change. Exact live
`MapRuntime` narrowphase checks remain in use. Logs:
`.local/qa/episode-2026-09-06/replay-candidate-index.txt` and
`.local/qa/episode-2026-09-06/replay-candidate-index-allclosed.txt`.

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

## Remaining product verification beyond the per-map replay task

All nine E1 normal exits now have current-core start-to-exit command streams
and independent repeat/reorder verification. Separate E1M3 secret-exit traversal,
continuous episode traversal and fresh native-render verification beyond E1M1
remain unproven. The user explicitly stopped the replay scope at E1 after
confirming that no full DOOM.WAD was available; E2/E3 are outside that task,
not failed or passed maps. Completing this replay task does not close the
broader product-quality gaps or the timing defect below.

### Confirmed lift-timing divergence

The frozen current core initializes `_LiftMover._wait` to 35; its bottom
countdown uses a post-decrement. Original Doom's `downWaitUpStay` initializes
the wait to `35 * PLATWAIT`, where `PLATWAIT` is 3:
[platform implementation](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_plats.c)
and [constants](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_spec.h).
This is a confirmed timing mismatch, not proof that E1M3's secret exit is
unreachable. The attempted secret-route timing and alternative activators
still require causal verification. No production timing change or secret-exit
completion is claimed here; the nine completed recordings above retain their
original current-core identities.

## Historical checkpoints (superseded)

The checkpoint details below describe the prior core revision. They are not
the current completion checklist; the current results are listed above.

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
