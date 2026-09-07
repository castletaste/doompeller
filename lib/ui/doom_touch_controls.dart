import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../game/doom_input.dart';

/// Pointer-safe touch controls layered over the playable viewport.
///
/// The parent owns input aggregation. Every held control is paired with the
/// pointer that acquired it and is released through [onPointerUp], so lifting
/// one finger cannot cancel another finger's intent.
final class DoomTouchControls extends StatefulWidget {
  const DoomTouchControls({
    super.key,
    required this.enabled,
    required this.resetGeneration,
    required this.onMove,
    required this.onLook,
    required this.onControlDown,
    required this.onPointerUp,
    required this.onUse,
    required this.onSelectWeapon,
    required this.onToggleMap,
    required this.onZoomMap,
    required this.onPause,
    this.mapOpen = false,
  });

  final bool enabled;

  /// Changing this value cancels every pointer captured by the overlay.
  final int resetGeneration;
  final void Function(int pointer, int forward, int side) onMove;
  final ValueChanged<double> onLook;
  final void Function(int pointer, DoomControl control) onControlDown;
  final void Function(int pointer, bool cancelled) onPointerUp;
  final VoidCallback onUse;
  final ValueChanged<int> onSelectWeapon;
  final VoidCallback onToggleMap;

  /// `true` zooms in and `false` zooms out.
  final ValueChanged<bool> onZoomMap;
  final VoidCallback onPause;
  final bool mapOpen;

  @override
  State<DoomTouchControls> createState() => _DoomTouchControlsState();
}

final class _DoomTouchControlsState extends State<DoomTouchControls> {
  static const String _moveSurface = 'move';
  static const String _lookSurface = 'look';
  static const String _mouseLookSurface = 'mouse-look';
  static const String _fireSurface = 'fire';
  static const String _runSurface = 'run';
  static const double _stickDeadZone = 0.16;

  final Map<String, int> _surfaceOwners = <String, int>{};
  final Map<int, String> _pointerSurfaces = <int, String>{};
  final Map<int, VoidCallback> _pendingOneShots = <int, VoidCallback>{};
  Offset _stickOffset = Offset.zero;
  bool _weaponsOpen = false;

  @override
  void didUpdateWidget(covariant DoomTouchControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.enabled && oldWidget.enabled) ||
        widget.resetGeneration != oldWidget.resetGeneration) {
      _clearCaptures(rebuild: false);
    }
  }

  @override
  void dispose() {
    _clearCaptures(rebuild: false);
    super.dispose();
  }

  bool _capture(String surface, int pointer) {
    if (!widget.enabled ||
        _surfaceOwners.containsKey(surface) ||
        _pointerSurfaces.containsKey(pointer)) {
      return false;
    }
    _surfaceOwners[surface] = pointer;
    _pointerSurfaces[pointer] = surface;
    return true;
  }

  bool _owns(String surface, int pointer) =>
      _surfaceOwners[surface] == pointer &&
      _pointerSurfaces[pointer] == surface;

  void _release(String surface, int pointer, {required bool cancelled}) {
    if (!_owns(surface, pointer)) return;
    final pendingOneShot = _pendingOneShots.remove(pointer);
    _surfaceOwners.remove(surface);
    _pointerSurfaces.remove(pointer);
    if (surface == _moveSurface) {
      widget.onMove(pointer, 0, 0);
      if (mounted) setState(() => _stickOffset = Offset.zero);
    } else if ((surface.startsWith('weapon-') ||
            (cancelled && surface == 'weapons')) &&
        mounted) {
      setState(() => _weaponsOpen = false);
    }
    widget.onPointerUp(pointer, cancelled);
    if (!cancelled) pendingOneShot?.call();
  }

  void _clearCaptures({required bool rebuild}) {
    final captures = Map<int, String>.of(_pointerSurfaces);
    _surfaceOwners.clear();
    _pointerSurfaces.clear();
    _pendingOneShots.clear();
    for (final entry in captures.entries) {
      if (entry.value == _moveSurface) {
        widget.onMove(entry.key, 0, 0);
      }
      widget.onPointerUp(entry.key, true);
    }
    _stickOffset = Offset.zero;
    _weaponsOpen = false;
    if (rebuild && mounted) setState(() {});
  }

  void _updateStick(int pointer, Offset localPosition, double diameter) {
    if (!_owns(_moveSurface, pointer)) return;
    final radius = diameter / 2;
    final raw = localPosition - Offset(radius, radius);
    final distance = raw.distance;
    final visualRadius = radius * 0.58;
    final clamped = distance > visualRadius && distance > 0
        ? raw * (visualRadius / distance)
        : raw;
    final normalizedDistance = distance / radius;
    var magnitude = 0.0;
    if (normalizedDistance > _stickDeadZone) {
      magnitude =
          ((normalizedDistance.clamp(_stickDeadZone, 1.0) - _stickDeadZone) /
                  (1 - _stickDeadZone))
              .clamp(0.0, 1.0);
    }
    final direction = distance == 0 ? Offset.zero : raw / distance;
    final side = (direction.dx * magnitude * 1000)
        .round()
        .clamp(-1000, 1000)
        .toInt();
    final forward = (-direction.dy * magnitude * 1000)
        .round()
        .clamp(-1000, 1000)
        .toInt();
    widget.onMove(pointer, forward, side);
    if (mounted) setState(() => _stickOffset = clamped);
  }

  void _oneShotDown(String surface, PointerDownEvent event, VoidCallback fire) {
    if (!_capture(surface, event.pointer)) return;
    _pendingOneShots[event.pointer] = fire;
  }

  Widget _oneShotButton({
    required Key key,
    required String surface,
    required String label,
    required double size,
    required VoidCallback onPressed,
    Color color = const Color(0xA8323232),
  }) => Listener(
    key: key,
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) => _oneShotDown(surface, event, onPressed),
    onPointerUp: (event) => _release(surface, event.pointer, cancelled: false),
    onPointerCancel: (event) =>
        _release(surface, event.pointer, cancelled: true),
    child: _ControlDisc(label: label, size: size, color: color),
  );

  Widget _heldButton({
    required Key key,
    required String surface,
    required String label,
    required double size,
    required DoomControl control,
    bool lookOnDrag = false,
    Color color = const Color(0xA8323232),
  }) => Listener(
    key: key,
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) {
      if (_capture(surface, event.pointer)) {
        widget.onControlDown(event.pointer, control);
      }
    },
    onPointerMove: lookOnDrag
        ? (event) {
            if (_owns(surface, event.pointer)) widget.onLook(event.delta.dx);
          }
        : null,
    onPointerUp: (event) => _release(surface, event.pointer, cancelled: false),
    onPointerCancel: (event) =>
        _release(surface, event.pointer, cancelled: true),
    child: _ControlDisc(label: label, size: size, color: color),
  );

  Widget _weaponPicker(double maxWidth) {
    const slotSize = 44.0;
    final selectWeapon = widget.onSelectWeapon;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xD9161616),
          border: Border.all(color: Colors.white38),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 3,
            runSpacing: 3,
            children: <Widget>[
              for (var slot = 0; slot < 6; slot++)
                _oneShotButton(
                  key: Key('touch-weapon-$slot'),
                  surface: 'weapon-$slot',
                  label: '${slot + 1}',
                  size: slotSize,
                  onPressed: () => selectWeapon(slot),
                  color: const Color(0xC04A4030),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isLookSurface(String? surface) =>
      surface == _lookSurface || surface == _mouseLookSurface;

  void _lookDown(PointerDownEvent event) {
    final isMouse = event.kind == PointerDeviceKind.mouse;
    final isPrimaryMouse =
        isMouse && (event.buttons & kPrimaryMouseButton) != 0;
    if (isMouse && !isPrimaryMouse) return;
    final surface = isMouse ? _mouseLookSurface : _lookSurface;
    if (!_capture(surface, event.pointer)) return;
    if (isPrimaryMouse) {
      widget.onControlDown(event.pointer, DoomControl.attack);
    }
  }

  void _lookMove(PointerMoveEvent event) {
    if (!_isLookSurface(_pointerSurfaces[event.pointer])) return;
    if (event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryMouseButton) == 0) {
      return;
    }
    widget.onLook(event.delta.dx);
  }

  void _lookRelease(int pointer, {required bool cancelled}) {
    final surface = _pointerSurfaces[pointer];
    if (!_isLookSurface(surface)) return;
    _release(surface!, pointer, cancelled: cancelled);
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.enabled,
    child: Opacity(
      opacity: widget.enabled ? 1 : 0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final zoomMap = widget.onZoomMap;
          final mediaSize = MediaQuery.sizeOf(context);
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : mediaSize.width;
          final height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : mediaSize.height;
          final stickSize = math
              .min(width * 0.32, height * 0.38)
              .clamp(96.0, 152.0)
              .toDouble();
          final actionSize = (stickSize * 0.68).clamp(64.0, 92.0).toDouble();
          final smallSize = (stickSize * 0.43).clamp(44.0, 56.0).toDouble();
          const edge = 10.0;
          const gap = 7.0;

          return Stack(
            key: const Key('touch-controls'),
            fit: StackFit.expand,
            children: <Widget>[
              // Only the right side owns the broad look surface. The unused
              // upper-left viewport remains available to the game surface.
              Positioned(
                left: width * 0.42,
                top: 0,
                right: 0,
                bottom: 0,
                child: Listener(
                  key: const Key('touch-look'),
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _lookDown,
                  onPointerMove: _lookMove,
                  onPointerUp: (event) =>
                      _lookRelease(event.pointer, cancelled: false),
                  onPointerCancel: (event) =>
                      _lookRelease(event.pointer, cancelled: true),
                ),
              ),
              Positioned(
                left: edge,
                bottom: edge,
                width: stickSize,
                height: stickSize,
                child: Listener(
                  key: const Key('touch-stick'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (_capture(_moveSurface, event.pointer)) {
                      _updateStick(
                        event.pointer,
                        event.localPosition,
                        stickSize,
                      );
                    }
                  },
                  onPointerMove: (event) => _updateStick(
                    event.pointer,
                    event.localPosition,
                    stickSize,
                  ),
                  onPointerUp: (event) =>
                      _release(_moveSurface, event.pointer, cancelled: false),
                  onPointerCancel: (event) =>
                      _release(_moveSurface, event.pointer, cancelled: true),
                  child: _AnalogStickFace(
                    diameter: stickSize,
                    knobOffset: _stickOffset,
                  ),
                ),
              ),
              Positioned(
                right: edge,
                bottom: edge,
                child: _heldButton(
                  key: const Key('touch-fire'),
                  surface: _fireSurface,
                  label: 'FIRE',
                  size: actionSize,
                  control: DoomControl.attack,
                  lookOnDrag: true,
                  color: const Color(0xB0742727),
                ),
              ),
              Positioned(
                right: edge + actionSize + gap,
                bottom: edge,
                child: _oneShotButton(
                  key: const Key('touch-use'),
                  surface: 'use',
                  label: 'USE',
                  size: smallSize,
                  onPressed: widget.onUse,
                ),
              ),
              Positioned(
                right: edge + actionSize + gap,
                bottom: edge + smallSize + gap,
                child: _heldButton(
                  key: const Key('touch-run'),
                  surface: _runSurface,
                  label: 'RUN',
                  size: smallSize,
                  control: DoomControl.runLeft,
                ),
              ),
              Positioned(
                right: edge,
                bottom: edge + actionSize + gap,
                child: _oneShotButton(
                  key: const Key('touch-weapons'),
                  surface: 'weapons',
                  label: 'WPN',
                  size: smallSize,
                  onPressed: () => setState(() {
                    _weaponsOpen = !_weaponsOpen;
                  }),
                ),
              ),
              Positioned(
                top: edge,
                right: edge,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _oneShotButton(
                      key: const Key('touch-map'),
                      surface: 'map',
                      label: 'MAP',
                      size: smallSize,
                      onPressed: widget.onToggleMap,
                    ),
                    if (widget.mapOpen) ...<Widget>[
                      const SizedBox(width: gap),
                      _oneShotButton(
                        key: const Key('touch-map-zoom-out'),
                        surface: 'zoom-out',
                        label: '−',
                        size: smallSize,
                        onPressed: () => zoomMap(false),
                      ),
                      const SizedBox(width: gap),
                      _oneShotButton(
                        key: const Key('touch-map-zoom-in'),
                        surface: 'zoom-in',
                        label: '+',
                        size: smallSize,
                        onPressed: () => zoomMap(true),
                      ),
                    ],
                    const SizedBox(width: gap),
                    _oneShotButton(
                      key: const Key('touch-pause'),
                      surface: 'pause',
                      label: 'II',
                      size: smallSize,
                      onPressed: widget.onPause,
                    ),
                  ],
                ),
              ),
              if (_weaponsOpen)
                Positioned(
                  top: edge + smallSize + gap,
                  left: 0,
                  right: 0,
                  child: Center(child: _weaponPicker(width - edge * 2)),
                ),
            ],
          );
        },
      ),
    ),
  );
}

final class _ControlDisc extends StatelessWidget {
  const _ControlDisc({
    required this.label,
    required this.size,
    required this.color,
  });

  final String label;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white54, width: 1.5),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: size < 46 ? 13 : 12,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    ),
  );
}

final class _AnalogStickFace extends StatelessWidget {
  const _AnalogStickFace({required this.diameter, required this.knobOffset});

  final double diameter;
  final Offset knobOffset;

  @override
  Widget build(BuildContext context) {
    final knobSize = diameter * 0.42;
    return Semantics(
      label: 'MOVE',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x70202020),
          border: Border.all(color: Colors.white38, width: 1.5),
        ),
        child: Stack(
          children: <Widget>[
            Positioned(
              left: diameter / 2 - knobSize / 2 + knobOffset.dx,
              top: diameter / 2 - knobSize / 2 + knobOffset.dy,
              width: knobSize,
              height: knobSize,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xB8E0E0E0),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
