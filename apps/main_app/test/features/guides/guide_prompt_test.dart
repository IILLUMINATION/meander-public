// Приглашение в гайд при входе в раздел. Ошибки здесь тихие: попап либо не
// появляется, либо возвращается каждый вход. Поэтому проверяем и правило, и
// три кнопки, и то, что «Позже» действительно только до перезапуска.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено): не добавлять id в `_shownThisSession` —
// падает тест «второй вход в тот же запуск молчит»; не звать
// `SectionHintService.dismiss` на «Больше не спрашивать» — падает тест про
// закрытие навсегда.

import 'package:canvas_app/features/guides/models/guide.dart';
import 'package:canvas_app/features/guides/screens/guide_screen.dart';
import 'package:canvas_app/features/guides/widgets/guide_prompt.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _info = GuideInfo(
  id: 'market',
  section: GuideSection.market,
  icon: Icons.storefront_rounded,
  accent: Color(0xFF7C4DFF),
);

Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      // Стрелки на схемах гайда двигаются по кругу: без этого флага
      // `pumpAndSettle` после открытия гайда не дождётся покоя.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => GuidePrompt.maybeShow(context, _info),
              child: const Text('открыть'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openPrompt(WidgetTester tester) async {
  await tester.tap(find.text('открыть'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GuidePrompt.resetSession();
  });

  test('правило показа: закрытое или уже показанное — молчим', () {
    expect(GuidePrompt.shouldShow(dismissed: false, alreadyShown: false), isTrue);
    expect(GuidePrompt.shouldShow(dismissed: true, alreadyShown: false), isFalse);
    expect(GuidePrompt.shouldShow(dismissed: false, alreadyShown: true), isFalse);
    expect(GuidePrompt.shouldShow(dismissed: true, alreadyShown: true), isFalse);
  });

  testWidgets('попап объясняет, что внутри, и закрывается по «Позже»', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _openPrompt(tester);

    expect(find.text('Хотите узнать, как создать квест?'), findsOneWidget);
    expect(
      find.text('Короткий офлайн-гайд: статья, видео и схемы с подсказками.'),
      findsOneWidget,
    );
    expect(find.text('Статья'), findsOneWidget);
    expect(find.text('Видео'), findsOneWidget);
    expect(find.text('Схемы'), findsOneWidget);
    expect(find.text('Открыть гайд'), findsOneWidget);

    await tester.tap(find.text('Позже'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    // «Позже» не закрывает навсегда.
    expect(
      await SectionHintService.isDismissed(GuidePrompt.hintId),
      isFalse,
    );

    // Второй вход в том же запуске — молчим.
    await _openPrompt(tester);
    expect(find.byType(AlertDialog), findsNothing);

    // Новый запуск (или сброс из настроек) — снова спрашиваем.
    GuidePrompt.resetSession();
    await _openPrompt(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('«Больше не спрашивать» закрывает навсегда', (tester) async {
    await _pumpHost(tester);
    await _openPrompt(tester);

    await tester.tap(find.text('Больше не спрашивать'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      await SectionHintService.isDismissed(GuidePrompt.hintId),
      isTrue,
    );

    GuidePrompt.resetSession();
    await _openPrompt(tester);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('закрытый попап не возвращается после перезапуска', (
    tester,
  ) async {
    await SectionHintService.dismiss(GuidePrompt.hintId);
    await _pumpHost(tester);
    await _openPrompt(tester);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('«Открыть гайд» ведёт на экран гайда', (tester) async {
    await _pumpHost(tester);
    await _openPrompt(tester);

    await tester.tap(find.text('Открыть гайд'));
    await tester.pumpAndSettle();

    expect(find.byType(GuideScreen), findsOneWidget);
    // Гайд открыт — второй раз за запуск не предлагаем.
    expect(
      await SectionHintService.isDismissed(GuidePrompt.hintId),
      isTrue,
    );
    // Контент реальный: экран не остался на ошибке загрузки.
    expect(find.text('Как устроен маркет'), findsOneWidget);
  });
}
