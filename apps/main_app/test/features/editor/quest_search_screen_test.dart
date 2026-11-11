import 'package:canvas_app/features/editor/screens/quest_search_screen.dart';
import 'package:canvas_app/features/editor/services/quest_search_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Поиск читает диск и переходит к результату; в тесте диск заменён
/// заглушкой, а проверяется поведение экрана: дебаунс, группировка,
/// закрытие поиска перед переходом.
class _FakeSearchService extends QuestSearchService {
  _FakeSearchService(this.hits) : super(questId: 'q1');

  final List<QuestSearchHit> hits;
  final List<String> queries = [];

  @override
  Future<QuestSearchReport> search(String query) async {
    queries.add(query.trim());
    final totals = <QuestSearchKind, int>{};
    for (final hit in hits) {
      totals[hit.kind] = (totals[hit.kind] ?? 0) + 1;
    }
    return QuestSearchReport(
      query: query.trim(),
      hits: hits,
      totals: totals,
      total: hits.length,
      matches: hits.length,
      elapsedMs: 4,
      limitPerKind: QuestSearchService.limitPerKind,
    );
  }
}

void main() {
  testWidgets('результаты группируются по видам, переход закрывает поиск', (
    tester,
  ) async {
    final service = _FakeSearchService(const [
      QuestSearchHit(
        kind: QuestSearchKind.node,
        id: 'n1',
        title: 'Берег',
        context: 'название ноды',
      ),
      QuestSearchHit(
        kind: QuestSearchKind.script,
        id: 'aaa.json',
        title: 'Зажечь маяк',
        context: 'ноды → text',
        snippet: 'зажечь маяк ночью',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        QuestSearchScreen(questId: 'q1', service: service),
                  ),
                ),
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ),
      ),
    );
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'маяк');
    // Дебаунс 160 мс: до него запроса ещё нет.
    await tester.pump(const Duration(milliseconds: 80));
    expect(service.queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    expect(service.queries, ['маяк']);
    expect(find.text('Ноды'), findsOneWidget);
    expect(find.text('Визуальные скрипты'), findsOneWidget);
    expect(find.textContaining('Берег'), findsWidgets);
    expect(find.textContaining('зажечь маяк ночью'), findsOneWidget);

    // Переход: экран поиска уходит со стека. Документ ноды может остаться
    // на загрузке (в тесте нет данных), поэтому settle не ждём.
    await tester.tap(find.textContaining('Берег').first);
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(QuestSearchScreen), findsNothing);
  });

  testWidgets('пустой запрос не ищет и показывает подсказку', (tester) async {
    final service = _FakeSearchService(const []);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: QuestSearchScreen(questId: 'q1', service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Ищу по названиям'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.queries, isEmpty);
  });
}