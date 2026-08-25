import 'dart:math' as math;

import 'package:doompeller/adapter/adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Dart mirror of the fragment shader's UV resolution.
///
/// The shader itself cannot be executed in a widget test: flame_3d needs a real
/// GPU to compile a pipeline. This oracle reproduces the exact arithmetic in
/// shaders/doom_palette.frag so the seam and bleed rules can be verified on
/// CPU. It must be updated in lockstep with the shader.
({double u, double v}) resolveAtlasUv({
  required double u,
  required double v,
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double uvMode,
  required int atlasWidth,
  required int atlasHeight,
}) {
  final localU = uvMode > 0.5 ? u - u.floorToDouble() : u.clamp(0.0, 1.0);
  final localV = uvMode > 0.5 ? v - v.floorToDouble() : v.clamp(0.0, 1.0);

  var atlasU = left + (right - left) * localU;
  var atlasV = top + (bottom - top) * localV;

  final halfTexelU = 0.5 / atlasWidth;
  final halfTexelV = 0.5 / atlasHeight;

  atlasU = atlasU.clamp(
    left + halfTexelU,
    math.max(right - halfTexelU, left + halfTexelU),
  );
  atlasV = atlasV.clamp(
    top + halfTexelV,
    math.max(bottom - halfTexelV, top + halfTexelV),
  );
  return (u: atlasU, v: atlasV);
}

void main() {
  const atlasWidth = 256;
  const atlasHeight = 256;
  // A 64x64 entry at atlas origin (64, 0).
  const left = 64 / atlasWidth;
  const right = 128 / atlasWidth;
  const top = 0.0;
  const bottom = 64 / atlasHeight;

  ({double u, double v}) resolve(double u, double v, double mode) =>
      resolveAtlasUv(
        u: u,
        v: v,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        uvMode: mode,
        atlasWidth: atlasWidth,
        atlasHeight: atlasHeight,
      );

  group('repeating world UV', () {
    test('tiles inside its own atlas rect', () {
      // Doom wall UVs run far past 1.0; each whole step must land in the same
      // place inside the entry, never in the neighbouring one.
      final atOne = resolve(1.25, 0.5, DoomVertexAbi.uvModeRepeat);
      final atFive = resolve(5.25, 0.5, DoomVertexAbi.uvModeRepeat);
      expect(atOne.u, closeTo(atFive.u, 1e-9));
      expect(atOne.u, greaterThanOrEqualTo(left));
      expect(atOne.u, lessThanOrEqualTo(right));
    });

    test('never samples outside the entry, even at a tile seam', () {
      for (final u in [0.0, 0.999999, 1.0, 2.0, 7.5]) {
        final resolved = resolve(u, 0.5, DoomVertexAbi.uvModeRepeat);
        expect(
          resolved.u,
          inInclusiveRange(left + 0.5 / atlasWidth, right - 0.5 / atlasWidth),
          reason: 'u=$u bled outside its atlas entry',
        );
      }
    });

    test('a negative UV still lands inside the entry', () {
      // Doom sidedef X offsets are routinely negative.
      final resolved = resolve(-0.25, -0.75, DoomVertexAbi.uvModeRepeat);
      expect(resolved.u, inInclusiveRange(left, right));
      expect(resolved.v, inInclusiveRange(top, bottom));
    });
  });

  group('clamped sprite UV', () {
    test('pins out-of-range UVs to the entry edge', () {
      final past = resolve(1.8, 1.8, DoomVertexAbi.uvModeClamp);
      final atEdge = resolve(1.0, 1.0, DoomVertexAbi.uvModeClamp);
      expect(past.u, closeTo(atEdge.u, 1e-9));
      expect(past.v, closeTo(atEdge.v, 1e-9));
    });

    test('does not wrap to the opposite edge', () {
      final low = resolve(-0.5, 0.5, DoomVertexAbi.uvModeClamp);
      final high = resolve(1.5, 0.5, DoomVertexAbi.uvModeClamp);
      expect(low.u, lessThan(high.u));
      expect(low.u, closeTo(left + 0.5 / atlasWidth, 1e-9));
    });
  });

  group('half-texel inset', () {
    test('keeps sampling on the first and last texel centres', () {
      final atMin = resolve(0, 0, DoomVertexAbi.uvModeClamp);
      final atMax = resolve(1, 1, DoomVertexAbi.uvModeClamp);

      // The first texel of a 64-wide entry starting at atlas x=64 has its
      // centre at 64.5 / 256; the last at 127.5 / 256.
      expect(atMin.u, closeTo(64.5 / atlasWidth, 1e-9));
      expect(atMax.u, closeTo(127.5 / atlasWidth, 1e-9));
      expect(atMin.v, closeTo(0.5 / atlasHeight, 1e-9));
      expect(atMax.v, closeTo(63.5 / atlasHeight, 1e-9));
    });

    test('a one-texel entry collapses without inverting', () {
      // A degenerate rect must not produce min > max, which would make the
      // clamp undefined.
      final resolved = resolveAtlasUv(
        u: 0.5,
        v: 0.5,
        left: 0,
        top: 0,
        right: 1 / atlasWidth,
        bottom: 1 / atlasHeight,
        uvMode: DoomVertexAbi.uvModeRepeat,
        atlasWidth: atlasWidth,
        atlasHeight: atlasHeight,
      );
      expect(resolved.u, closeTo(0.5 / atlasWidth, 1e-9));
      expect(resolved.v, closeTo(0.5 / atlasHeight, 1e-9));
    });

    test('adjacent entries can never sample each other', () {
      const neighbourLeft = 128 / atlasWidth;
      final rightEdge = resolve(1, 0.5, DoomVertexAbi.uvModeRepeat);
      expect(
        rightEdge.u,
        lessThan(neighbourLeft),
        reason: 'the inset is what prevents a bright seam on every wall',
      );
    });
  });

  group('per-vertex atlas rect', () {
    test('travels in the repurposed skinning slots', () {
      final vertices = DoomVertexAbi.allocate(1);
      DoomVertexAbi.writeVertex(
        vertices,
        0,
        x: 0,
        y: 0,
        z: 0,
        u: 0,
        v: 0,
        atlasLeft: left,
        atlasTop: top,
        atlasRight: right,
        atlasBottom: bottom,
        uvMode: DoomVertexAbi.uvModeClamp,
      );

      final rect = DoomVertexAbi.atlasRectOffset;
      expect(vertices[rect], closeTo(left, 1e-6));
      expect(vertices[rect + 1], closeTo(top, 1e-6));
      expect(vertices[rect + 2], closeTo(right, 1e-6));
      expect(vertices[rect + 3], closeTo(bottom, 1e-6));
      expect(
        vertices[DoomVertexAbi.paramsOffset + 2],
        DoomVertexAbi.uvModeClamp,
      );
    });
  });
}
