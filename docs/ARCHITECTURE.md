# Runtime boundaries

Doompeller keeps WAD decoding, geometry compilation, deterministic gameplay and
MUS/GENMIDI sequencing in four pure-Dart packages. Flutter, flutter_scene, browser
APIs and native audio stay in the app adapters. Rendering and audio consume
simulation output; they do not decide gameplay state or replay hashes.

## Loading and ownership

`DoomApp` owns the default controller and level preparer for the lifetime of
the app widget. Injected controllers and preparers remain caller-owned.
Replacing a controller detaches its listener and disposes only controllers
created by the app.

Asynchronous loading has separate ownership boundaries:

| Fence | Owner | Responsibility |
| --- | --- | --- |
| Request | `DoomAppController` | Reject stale source results and state publication |
| Picker | `DoomAppController` | Reject a late browser chooser without cancelling a level load |
| Load | `LevelLoadCoordinator` | Issue preparation tokens and publish only the newest result |
| Admission | `DoomLevelPreparer` | Keep one active worker and one replaceable pending request |

The preparer bounds native isolate admission. Cancellation prevents obsolete
publication and pending work, while an already-running isolate may finish.
GPU objects and scene assembly stay on the UI isolate. On web, preparation
still runs on the event loop and may block frames; the architecture does not
claim otherwise.

`PreparedDoomLevel.geometry` is a reusable read-only template. A runtime gets
its own mutable geometry copy for sector, wall and animation updates. Atlas
data, topology and lookup tables remain shared.

## Runtime and presentation

`DoomRuntimeGame` is the runtime facade. Replay delivery, audio bridging,
presentation synchronization and lifecycle helpers live in adjacent adapter
parts, with one owner for runtime state and disposal.

The game view owns the runtime, focus, lifecycle observer and optional frame
probe. `DoomRuntimeView` is a complete host contract covering observables,
input, pause, audio focus and disposal. `DoomGameHost` keeps custom runtime
creation paired with its surface builder so a mounted runtime cannot lack a
renderer. Production uses the built-in `DoomSceneSurface`.

## Rendering

The renderer core in `lib/adapter` is plain data: packed surfaces with their
dirty vertex ranges, sprite, weapon and sky objects with their transforms,
palette materials with their uniform state, and `DoomCamera`. GPU objects are
created only through `DoomGpu`, which production installs in
`initializeDoomRenderer` and tests replace with a recording fake, so every
geometry, animation and upload rule runs under `flutter test`.

`DoomSceneSurface` owns the frame clock and focus. Each displayed frame it
advances the host (`DoomSceneHost`: the runtime or the renderer smoke
harness), then `DoomScenePresenter` mirrors the scene into a flutter_scene
`Scene`: one node per object, one shader material per palette material and
culling mode, and geometries that read the surfaces' own buffers. Only changed
vertex ranges and uniform blocks are uploaded. The palette shader draws with
`DoomCamera`'s own view and projection, so the image does not depend on
flutter_scene's camera conventions; flutter_scene's camera is used only to cull.
Scene settings make the resolve pass an exact sRGB re-encode, so PLAYPAL bytes
reach the screen unchanged.

The game surface keeps stable widget identity while HUD, overlays and automap
listen in their own subtrees. Loading, failure and ready are sealed app states;
ready always contains a prepared level. No router or dependency-injection
package is needed.

## Browser input

One browser bridge owns pointer lock and coarse-pointer detection. Each mounted
level receives a revocable input lease. A pending browser request blocks a new
request until its result arrives; a late capture after pause, replacement or
disposal is released. Native builds use a no-op browser driver.

Blur, hidden tabs, pause and teardown clear held input. Returning to a tab leaves
the game paused. Pointer capture failure leaves keyboard and touch controls
usable and exposes a retry hint. Touch preference and mouse sensitivity belong
to the app session; explicit user choice wins over later device detection.

## Audio

`DoomApp` owns one default `DoomAudioSession`; injected sessions remain owned by
their caller. Each level gets a generation-fenced backend lease. Replacing a
level retires voices and music while preserving the browser context and the
two session-only volume preferences.

Browser music runs in a separately compiled Dart Wasm worker. `doom_music` owns
the MUS clock and OPL2 synthesis; the AudioWorklet consumes PCM through a
bounded queue. Music configuration is latest-wins and ordered behind retire
acknowledgements. A sample-rate or worker failure disables music while leaving
PCM effects available.

Effects use a bounded sound queue with critical-cue overflow rules. Backend
failures are recorded without poisoning later playback or preventing disposal.
Native audio leases the transport by messenger identity; takeover dispatches
the previous owner's cleanup before the new owner can send commands.

## Content and verification

Commercial WAD files stay developer-local and ignored. Synthetic fixtures are
source-generated. The app does not embed, wrap, download or extract another
Doom engine, and direct flutter_scene usage remains confined to `lib/adapter`.

The 20-float vertex ABI, dependency versions and replay/geometry hashes are
explicit contracts. Run the project and content audits through
`sh tool/ci_contracts.sh`; it also runs the ABI, geometry and replay tripwires.
Use `dart run tool/test.dart` for synthetic app tests and add
`--include-content` with a local `DOOM_WAD_PATH` for original-content
acceptance. The local IWAD is never committed.

macOS renders through Flutter GPU on Impeller Metal; the web renders through
flutter_scene's WebGL2 backend under Wasm. GPU objects are reclaimed when the
engine or browser collects them, never on demand, so stable resource counts are
regression evidence rather than proof of reclamation.
