import 'package:audiobook_player/windows_terms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'explicit agreement is required before accepting component terms',
    (tester) async {
      var accepted = 0;
      var declined = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsTermsScreen(
            document: 'Intel and Microsoft component terms',
            onAccept: () async => accepted++,
            onDecline: () => declined++,
          ),
        ),
      );
      await tester.tap(find.text('Accept and start AudioSubs'));
      await tester.pump();
      expect(accepted, 0);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Accept and start AudioSubs'));
      await tester.pump();
      expect(accepted, 1);
      expect(declined, 0);
    },
  );

  testWidgets(
    'missing terms cannot be accepted and decline remains available',
    (tester) async {
      var accepted = false;
      var declined = false;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsTermsScreen(
            document: null,
            failure: 'Restore the complete package',
            onAccept: () async => accepted = true,
            onDecline: () => declined = true,
          ),
        ),
      );
      await tester.tap(find.text('Accept and start AudioSubs'));
      await tester.pump();
      expect(accepted, isFalse);
      expect(find.text('Restore the complete package'), findsOneWidget);
      await tester.tap(find.text('Decline and exit'));
      expect(declined, isTrue);
    },
  );

  testWidgets('save failure keeps terms visible and allows another attempt', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsTermsScreen(
          document: 'Full component terms',
          onAccept: () async {
            attempts++;
            if (attempts == 1) throw StateError('read-only support directory');
          },
          onDecline: () {},
        ),
      ),
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Accept and start AudioSubs'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Acceptance could not be saved'),
      findsOneWidget,
    );
    expect(find.text('Full component terms'), findsOneWidget);
    await tester.tap(find.text('Accept and start AudioSubs'));
    await tester.pump();
    expect(attempts, 2);
  });
}
