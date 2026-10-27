// «Гайд прочитан» — отдельный прогресс обучения, а не закрытая плашка.
// Сброс подсказок в настройках не должен стирать отметку, иначе человек,
// который вернул подсказки, теряет и историю прочитанного.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено): писать в тот же ключ, что и
// SectionHintService, — падает тест про независимость от подсказок.

import 'package:canvas_app/features/guides/services/guide_progress_store.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('пустое хранилище — ничего не прочитано', () async {
    expect(await GuideProgressStore.read(), isEmpty);
    expect(await GuideProgressStore.isRead('create_quest'), isFalse);
  });

  test('отметка переживает перезапуск', () async {
    await GuideProgressStore.markRead('create_quest');
    expect(await GuideProgressStore.isRead('create_quest'), isTrue);

    // Новый «запуск»: ровно то, что лежало в хранилище.
    SharedPreferences.setMockInitialValues({
      GuideProgressStore.key: ['create_quest'],
    });
    expect(await GuideProgressStore.read(), {'create_quest'});
    expect(await GuideProgressStore.isRead('create_quest'), isTrue);
  });

  test('повторная отметка не плодит дублей', () async {
    await GuideProgressStore.markRead('market');
    await GuideProgressStore.markRead('market');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(GuideProgressStore.key), ['market']);
  });

  test('отметки гайдов и подсказок не смешиваются', () async {
    await GuideProgressStore.markRead('create_quest');
    await SectionHintService.dismiss('library_hint');

    expect(await SectionHintService.isDismissed('create_quest'), isFalse);
    expect(await GuideProgressStore.isRead('library_hint'), isFalse);

    await SectionHintService.reset();
    expect(await GuideProgressStore.isRead('create_quest'), isTrue);
  });
}
