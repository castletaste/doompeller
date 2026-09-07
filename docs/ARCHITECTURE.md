# Runtime boundaries

The three packages remain usable without Flutter: `doom_wad` decodes content,
`doom_geometry` compiles it, and `doom_core` owns the deterministic 35 Hz
simulation. Only `lib/adapter` imports flame_3d. Rendering, audio and UI consume
simulation output; they do not decide or hash gameplay state.

## Loading and ownership

`DoomApp` owns its default controller and a level preparer for the lifetime of
the app widget. An injected controller belongs to its caller. Replacing it
detaches the old subscription and disposes only a controller created by the app.
Ownership is initialized before the first build. Internally created replacements
reuse the preparer, so retiring a controller
cannot bypass its CPU admission limit. Separately injected preparers/controllers
have independent lifetimes by design.

The controller fences content reads, file-picker results and episode transitions
by request generation. Choosers have their own generation, so dismissing one
does not invalidate an existing load. A displaced pending preparation that is
still current for another controller reports a retryable failure.
`LevelLoadCoordinator` separately fences CPU preparation
and synchronous assembly. Both fences tolerate disposal and synchronous listener
reentrancy. A failed episode transition keeps the completed map available for a
retry; an obsolete result cannot replace the current level.

`DoomLevelPreparer` admits one active worker and one replaceable pending request.
A native `compute` worker receives only content and immutable configuration:
resources, map parsing and world geometry compilation run there. Cancellation
prevents publication and skips obsolete pending work; it does not kill an
already running isolate. The source content identity is preserved on return.
GPU objects and sprite scene assembly stay on the UI isolate.

On web, Flutter's `compute` executes on the calling event loop. Preparation
yields between CPU stages but each stage can still block rendering. There is
no browser worker or claim of jank-free custom-WAD loading. Sprite atlas packing
also remains synchronous; the disposable design measurements did not justify
another worker protocol for the current episode.

`PreparedDoomLevel.geometry` is a reusable template. `DoomRuntimeGame` calls
`copyForRuntime` once when assembling a scene: vertices and mutable floor,
ceiling and wall handles are independent. Atlas data, topology and lookup tables
are shared as read-only data. Restart mutates only the runtime's copy. Direct
`DoomScene.fromCompiledLevel` callers retain the existing buffer ownership
contract; they supply the mutable geometry that the scene will update.

## Simulation and presentation

`GameState` orchestrates each tic and owns map/actor state. Actor tuning and
special classification are separate tables; sector movers and the player weapon
state machine own their local state. Their inputs are narrow callbacks or values,
not access to the entire game. Actor iteration, RNG calls, integer arithmetic
and replay hash word order remain unchanged.

The runtime owns keyboard/pointer latches, replay progress and the scene. Replay
completion callbacks run after the tick driver returns so a callback may safely
restart or dispose the runtime. `DoomScene` composes dynamic world geometry,
sky, sprite components and an actor pool. Dynamic geometry indexes sector and
animation ranges once, then updates retained buffers through dirty ranges.
Automap heights and player discovery publish together once per tic.

The game view owns the runtime, focus, lifecycle observer and optional frame
probe. Disposal is explicit and idempotent through `DoomRuntimeLifecycle`, also
used by Flame removal. Legacy injected `DoomRuntimeView` implementations remain
valid without that optional interface.

The game surface has stable widget identity across gameplay publications.
Factories create runtimes when a level is mounted or replaced; changing a
callback closure does not restart gameplay. A new host key explicitly replaces
a live runtime. Surface builder changes update the existing runtime's view, and
a directly embedded game view handles level replacement itself.
HUD, overlays and automap listen
within their own subtrees. Equal HUD snapshots suppress redundant notification.
The three StatefulWidgets have actual ownership duties: the app controller,
the runtime/focus, and the intermission animation. Loading, failure and ready
are sealed states, with a non-null prepared level in the ready state. Navigation
continues to use these states and overlays; no router or DI package is needed.

## Audio and failures

`DoomSoundOutput` serializes mixer work without adding a future for every empty
tic. At most 128 sound events wait behind the active batch. Overflow follows
the core journal's critical-cue policy: remove the oldest expendable sound first;
ordinary incoming sounds cannot evict a queue containing only critical cues.
Stop/restart/dispose discard queued events and invalidate an active batch at its
next async boundary. Backend failures are recorded and do not poison later
output or prevent backend disposal. An active native call must still settle
before the same output pump can complete teardown.

`WadSoundCatalog` caches immutable WAV encodings for WAD samples. Custom catalogs
may provide an immutable encoding through `SoundDefinition.wavBytes`; mutable
custom PCM without one continues to be encoded per request.

`MacOsAudioBackend` leases the transport by BinaryMessenger identity and channel
name. Only the newest owner can send native commands or deliver completions.
Transport playback IDs are unique across owners, even when logical mixer IDs
restart from zero. Ownership is checked at dispatch, and no await precedes a
native teardown dispatch. Flutter's MethodChannel FIFO ordering preserves that
order. Weak owner references avoid retaining retired runtimes. The native
protocol is unchanged.

## Compatibility and verification

Public entrypoints keep their original exports and constructors. The geometry
copy helpers, optional runtime lifecycle, preparation worker injection and
optional WAV encoding are additive. The 20-float vertex ABI and exact renderer
dependency pins remain unchanged. Unused direct `meta` dependencies were removed;
no dependency versions were upgraded.

Run `dart run tool/test.dart` for synthetic app tests without an IWAD, and add
`--include-content` with a local `DOOM_WAD_PATH` for original-content acceptance.
The test runner creates a temporary source projection, preserving Flutter's
standard shader assets without changing the production asset manifest. Package
tests run directly with `dart test`. Native preparation is tested with real
controller loads. Widget tests control the preparation completion explicitly;
original-content setup runs outside the fake widget clock with
`WidgetTester.runAsync`.

Key regressions cover stable surface rebuilds, controller replacement/reentrancy,
picker cancellation, independent runtime geometry, bounded preparation/audio
queues, audio ownership and delayed replies, replay callbacks and repeated
restart resource counts. See `VERIFICATION.md` for target-specific evidence.
Flame 3D exposes no per-resource GPU disposal API; stable resource counts do not
prove native GPU reclamation. Existing gameplay limitations remain separate
from this architecture change.
