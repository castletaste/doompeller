import 'package:doompeller/adapter/adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'doom_runtime_game_test.dart' as fixture;
import 'fake_gpu_backend.dart';

void main() {
  setUp(FakeGpuBackend.new);

  test(
    'runtime floor changes preserve its template and sibling buffer',
    () async {
      final level = await fixture.fixtureLevel();
      final plane = level.geometry.floorPlanes.first;
      final range = plane.ranges.first;
      final sourceHeight = plane.height;
      final heightOffset = DoomVertexAbi.floatOffsetOf(range.firstVertex) + 1;
      final first = DoomRuntimeGame(level);
      final second = DoomRuntimeGame(level);
      addTearDown(() async {
        first.dispose();
        second.dispose();
        await first.soundPlaybackIdleForTest;
        await second.soundPlaybackIdleForTest;
      });

      expect(
        first.scene.updateSectorPlane(
          sectorIndex: plane.sector,
          height: sourceHeight + 7,
          isCeiling: false,
        ),
        isTrue,
      );
      expect(
        first.scene
            .surfaceForMesh(range.meshIndex)
            .packedVertices[heightOffset],
        sourceHeight + 7,
      );
      expect(
        second.scene
            .surfaceForMesh(range.meshIndex)
            .packedVertices[heightOffset],
        sourceHeight,
        reason: 'a runtime must not write another runtime vertex buffer',
      );
      expect(
        level.geometry.meshes[range.meshIndex].vertices[heightOffset],
        sourceHeight,
        reason: 'prepared geometry must remain a reusable template',
      );
      expect(
        plane.height,
        sourceHeight,
        reason: 'plane handles belong to one runtime',
      );
    },
  );

  test('plane state and restart remain independent across runtimes', () async {
    final level = await fixture.fixtureLevel();
    final plane = level.geometry.floorPlanes.first;
    final range = plane.ranges.first;
    final sourceHeight = plane.height;
    final heightOffset = DoomVertexAbi.floatOffsetOf(range.firstVertex) + 1;
    final first = DoomRuntimeGame(level);
    final second = DoomRuntimeGame(level);
    addTearDown(() async {
      first.dispose();
      second.dispose();
      await first.soundPlaybackIdleForTest;
      await second.soundPlaybackIdleForTest;
    });

    first.scene.updateSectorPlane(
      sectorIndex: plane.sector,
      height: sourceHeight + 7,
      isCeiling: false,
    );
    expect(
      second.scene.updateSectorPlane(
        sectorIndex: plane.sector,
        height: sourceHeight + 7,
        isCeiling: false,
      ),
      isTrue,
      reason: 'sibling plane state must not suppress a real update',
    );
    first.restartLevel();
    expect(
      second.scene.surfaceForMesh(range.meshIndex).packedVertices[heightOffset],
      sourceHeight + 7,
      reason: 'restart may only restore its own scene',
    );
  });
}
