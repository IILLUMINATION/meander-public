import 'package:canvas_app/core/services/build_info_service.dart';
import 'package:canvas_app/features/app/screens/about_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('«О приложении» показывает ветку и коммит сборки', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AboutScreen(
          buildInfo: const AppBuildInfo(branch: 'ui-update', commit: 'ab9b92c'),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Ветка: ui-update · Коммит: ab9b92c'), findsOneWidget);
  });
}
