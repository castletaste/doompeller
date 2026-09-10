import 'dart:async';
import 'package:doompeller/ui/doom_startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('graphics startup shows progress, error and successful retry', (
    tester,
  ) async {
    final first = Completer<void>(), second = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      DoomStartup(
        initialize: () => ++calls == 1 ? first.future : second.future,
        child: const MaterialApp(home: Text('GAME READY')),
      ),
    );
    expect(find.text('STARTING GRAPHICS'), findsOneWidget);
    first.completeError(StateError('No adapter'));
    await tester.pump();
    expect(find.text('Could not start the 3D graphics.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-renderer')));
    await tester.pump();
    expect(find.text('STARTING GRAPHICS'), findsOneWidget);
    second.complete();
    await tester.pumpAndSettle();
    expect(find.text('GAME READY'), findsOneWidget);
    expect(calls, 2);
  });
  testWidgets('late initialization failure after unmount is harmless', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      DoomStartup(initialize: () => pending.future, child: const SizedBox()),
    );
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('late'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
