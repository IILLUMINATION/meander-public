import 'package:canvas_app/features/editor/widgets/editor_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Уведомление о добавлении контента не должно копиться в очереди: очередь
/// из четырёхсекундных SnackBar'ов закрывает нижнюю панель после каждой
/// правки, хотя сказать уже нечего.
void main() {
  Future<void> pumpHost(
    WidgetTester tester,
    void Function(BuildContext) onBuild,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              onBuild(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('второе уведомление заменяет первое, а не встаёт в очередь', (
    tester,
  ) async {
    late BuildContext ctx;
    await pumpHost(tester, (context) => ctx = context);

    showEditorNotice(ctx, 'Элемент вставлен');
    showEditorNotice(ctx, 'Элемент вставлен');
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.duration, const Duration(milliseconds: 1400));
    // Поднято над нижней панелью канваса, а не поверх её кнопок.
    expect(snack.behavior, SnackBarBehavior.floating);
    expect(snack.margin, const EdgeInsets.fromLTRB(16, 0, 16, 112));
  });

  testWidgets('через полторы секунды панель снова видна', (tester) async {
    late BuildContext ctx;
    await pumpHost(tester, (context) => ctx = context);

    showEditorNotice(ctx, 'Элемент скопирован');
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);

    // Показ + 1.4 с + анимация ухода: раньше уведомление жило четыре
    // секунды, и этого не хватало.
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}