// Экран гайда: видео, схемы с подсказками и статья. Синтетический контент
// здесь не замена загрузчику (он проверен отдельно), а способ проверить
// сам экран без media_kit и без бандла.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено): не отмечать гайд прочитанным в
// `_finish()` — падает тест про «Понятно»; показывать подпись шага дважды
// (в схеме и под каруселью) — падает тест про один заголовок шага.
//
// Голден: `goldens/guide_screen.png` — широкая раскладка (медиа слева,
// статья справа). Обновляется через `flutter test --update-goldens`.

import 'package:canvas_app/features/guides/models/guide.dart';
import 'package:canvas_app/features/guides/screens/guide_screen.dart';
import 'package:canvas_app/features/guides/services/guide_progress_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _info = GuideInfo(
  id: 'test_guide',
  section: GuideSection.library,
  icon: Icons.menu_book_rounded,
  accent: Color(0xFF2196F3),
);

const _content = GuideContent(
  languageCode: 'ru',
  title: 'Тестовый гайд',
  summary: 'Короткое описание гайда',
  minutes: 2,
  shots: [
    GuideShot(
      kind: GuideShotKind.quests,
      title: 'Первый шаг',
      caption: 'Нажмите «Создать квест»',
    ),
    GuideShot(
      kind: GuideShotKind.library,
      title: 'Второй шаг',
      caption: 'Откройте библиотеку',
    ),
  ],
  article: '# Заголовок статьи\n\nТекст статьи для проверки.',
);

/// Стрелки схем двигаются по кругу. В тестах выключаем движение: иначе
/// `pumpAndSettle` не дождётся покоя, а голден зависел бы от кадра.
Widget _app(Widget home) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: home,
);

Future<void> _pumpScreen(
  WidgetTester tester, {
  GuideInfo info = _info,
  GuideContent? content = _content,
  Size size = const Size(420, 1200),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(_app(GuideScreen(info: info, initialContent: content)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('показывает заголовок, схему, статью и кнопку «Понятно»', (
    tester,
  ) async {
    await _pumpScreen(tester);

    expect(find.text('Тестовый гайд'), findsOneWidget);
    expect(find.text('Короткое описание гайда'), findsOneWidget);
    expect(find.text('Офлайн'), findsOneWidget);
    expect(find.text('Чтение: 2 мин'), findsOneWidget);
    expect(find.text('Схемы с подсказками'), findsOneWidget);
    expect(find.text('Шаг 1 из 2'), findsOneWidget);
    expect(find.text('Первый шаг'), findsOneWidget);
    expect(find.text('Статья'), findsOneWidget);
    expect(
      find.textContaining('Текст статьи', findRichText: true),
      findsWidgets,
    );
    expect(find.text('Понятно'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('карусель шагов переключает подпись', (tester) async {
    await _pumpScreen(tester);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Шаг 2 из 2'), findsOneWidget);
    expect(find.text('Второй шаг'), findsOneWidget);
    expect(find.text('Откройте библиотеку'), findsOneWidget);
    // Заголовок шага живёт только под каруселью — не дублируется внутри
    // фиксированной по высоте схемы (иначе длинная подпись переполняет её).
    expect(find.text('Второй шаг'), findsOneWidget);
  });

  testWidgets('«Понятно» отмечает гайд прочитанным и закрывает экран', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        const GuideScreen(info: _info, initialContent: _content),
                  ),
                ),
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();

    expect(find.byType(GuideScreen), findsNothing);
    expect(await GuideProgressStore.isRead('test_guide'), isTrue);
  });

  testWidgets('прочитанный гайд помечен бейджем', (tester) async {
    SharedPreferences.setMockInitialValues({
      GuideProgressStore.key: ['test_guide'],
    });
    await _pumpScreen(tester);
    expect(find.text('Гайд прочитан'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('гайд без схем не рисует пустую карусель', (tester) async {
    await _pumpScreen(
      tester,
      content: const GuideContent(
        languageCode: 'ru',
        title: 'Только текст',
        summary: 'Без схем',
        minutes: 1,
        shots: [],
        article: '',
      ),
    );

    expect(find.text('Схемы с подсказками'), findsNothing);
    expect(find.text('Статья'), findsNothing);
    expect(find.text('Только текст'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ненайденный гайд показывает ошибку и «Повторить»', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      info: const GuideInfo(
        id: 'no_such_guide',
        section: GuideSection.library,
        icon: Icons.help_outline,
        accent: Color(0xFF000000),
      ),
      content: null,
    );

    expect(find.text('Не удалось загрузить гайд'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);

    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить гайд'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('широкая раскладка не переполняется', (tester) async {
    await _pumpScreen(tester, size: const Size(900, 1400));
    expect(find.text('Тестовый гайд'), findsOneWidget);
    expect(find.text('Схемы с подсказками'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('голден широкой раскладки', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(const GuideScreen(info: _info, initialContent: _content)),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(GuideScreen),
      matchesGoldenFile('goldens/guide_screen.png'),
    );
  });
}
