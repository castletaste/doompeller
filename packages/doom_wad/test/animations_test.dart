import 'package:doom_wad/doom_wad.dart';
import 'package:test/test.dart';

void main() {
  test(
    'flat range follows effective WAD directory order, not name suffixes',
    () {
      final WadResources resources = WadResources.load(DoomFixtures.wadSet());
      final DoomAnimationResolution resolution = resolveDoomAnimations(
        resources,
        definitions: const <DoomAnimationDefinition>[
          DoomAnimationDefinition(
            kind: DoomAnimationKind.flat,
            startName: 'FLOOR0',
            endName: 'FLAT1',
          ),
        ],
      );
      expect(resolution.failures, isEmpty);
      expect(resolution.animations.single.frames, <String>[
        'FLOOR0',
        'CEIL0',
        'FLAT1',
      ]);
    },
  );

  test('missing end frame degrades to static with an explicit failure', () {
    final WadResources resources = WadResources.load(DoomFixtures.wadSet());
    final DoomAnimationResolution resolution = resolveDoomAnimations(
      resources,
      definitions: const <DoomAnimationDefinition>[
        DoomAnimationDefinition(
          kind: DoomAnimationKind.flat,
          startName: 'NUKAGE1',
          endName: 'NOFRAME',
        ),
      ],
    );
    expect(resolution.animations, isEmpty);
    expect(resolution.failures.single.reason, contains('endpoint'));
  });

  test('fixture publishes generated classic-compatible animations', () {
    final DoomAnimationResolution resolution = resolveDoomAnimations(
      WadResources.load(DoomFixtures.wadSet()),
    );
    expect(
      resolution.animations
          .firstWhere(
            (animation) => animation.definition.startName == 'NUKAGE1',
          )
          .frames,
      <String>['NUKAGE1', 'NUKAGE2', 'NUKAGE3'],
    );
    expect(
      resolution.animations
          .firstWhere(
            (animation) => animation.definition.startName == 'BLODGR1',
          )
          .frames,
      <String>['BLODGR1', 'BLODGR2', 'BLODGR3', 'BLODGR4'],
    );
  });
}
