import 'package:flutter_test/flutter_test.dart';

import 'package:senior_care_family/main.dart';

void main() {
  testWidgets('SmartFrameApp renders', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartFrameApp());
    // 앱이 정상적으로 렌더링되는지 확인
    await tester.pumpAndSettle();
  });
}
