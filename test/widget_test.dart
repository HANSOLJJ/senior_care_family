import 'package:flutter_test/flutter_test.dart';

import 'package:senior_care_family/app.dart';

void main() {
  testWidgets('SeniorCareFamily renders', (WidgetTester tester) async {
    await tester.pumpWidget(const SeniorCareFamily());
    await tester.pumpAndSettle();
  });
}
