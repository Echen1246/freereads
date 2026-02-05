import 'package:flutter_test/flutter_test.dart';
import 'package:freereads/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const FreeReadsApp());

    // Verify the home screen loads
    expect(find.text('FreeReads'), findsOneWidget);
    expect(find.text('Local-only audiobooks'), findsOneWidget);
  });
}
