// Разбор гайда из JSON — единственная граница между файлом в бандле и
// экраном. Ошибка здесь не падает громко: гайд просто не откроется, а
// человек увидит «Не удалось загрузить гайд» без причины.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено): убрать `if (from == null || to == null)
// continue;` — падает тест про битую стрелку; убрать `.clamp(1, 120)` —
// падает тест про минуты; вернуть доверие к `json['kind']` без проверки —
// падает тест про неизвестный тип.

import 'package:canvas_app/features/guides/models/guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _baseJson() => {
  'title': '  Как создать квест ',
  'summary': ' Коротко о гайде ',
  'minutes': 7,
  'shots': [
    {
      'kind': 'editor',
      'title': 'Соберите экран',
      'caption': 'Откройте вкладку «Экран»',
      'focus': [0.30, 0.20, 0.60, 0.70],
      'arrows': [
        {'from': [0.10, 0.20], 'to': [0.50, 0.60], 'label': 'Сюда'},
        {'from': [0.10], 'to': [0.50, 0.60]},
        {'from': ['x', 0.20], 'to': [0.50, 0.60]},
        'мусор',
      ],
      'labels': [
        {'text': 'Создать', 'at': [0.70, 0.80]},
        {'text': '   ', 'at': [0.70, 0.80]},
        {'text': 'Без координат'},
      ],
      'image': 'assets/guides/shot.png',
    },
    {'title': '', 'caption': 'Подпись без заголовка'},
    'не объект',
    {'kind': 'no_such_kind', 'title': 'Второй шаг', 'caption': 'Подпись'},
  ],
};

void main() {
  group('GuideContent.fromJson', () {
    test('читает гайд, обрезает текст и нормализует шаги', () {
      final content = GuideContent.fromJson(
        _baseJson(),
        languageCode: 'ru',
        article: '\n  # Статья\n',
      );

      expect(content, isNotNull);
      expect(content!.title, 'Как создать квест');
      expect(content.summary, 'Коротко о гайде');
      expect(content.minutes, 7);
      expect(content.languageCode, 'ru');
      expect(content.article, '# Статья');
      // Из четырёх записей в массиве выживают две: битая и «не объект»
      // пропускаются по одной, а не прячут весь гайд.
      expect(content.shots, hasLength(2));

      final first = content.shots.first;
      expect(first.kind, GuideShotKind.editor);
      expect(first.focus, const Rect.fromLTWH(0.30, 0.20, 0.60, 0.70));
      expect(first.imageAsset, 'assets/guides/shot.png');
      // Из четырёх стрелок выживает одна: без `to`, без числового `from`
      // и не-объект отбрасываются.
      expect(first.arrows, hasLength(1));
      expect(first.arrows.single.from, const Offset(0.10, 0.20));
      expect(first.arrows.single.to, const Offset(0.50, 0.60));
      expect(first.labels, hasLength(1));
      expect(first.labels.single.text, 'Создать');

      // Неизвестный `kind` — не повод терять шаг: рисуем нейтральную схему.
      expect(content.shots.last.kind, GuideShotKind.quests);
    });

    test('минуты зажимаются в разумный диапазон', () {
      Map<String, dynamic> withMinutes(dynamic minutes) => {
        ..._baseJson(),
        'minutes': minutes,
      };

      expect(
        GuideContent.fromJson(
          withMinutes(0),
          languageCode: 'ru',
          article: '',
        )!.minutes,
        1,
      );
      expect(
        GuideContent.fromJson(
          withMinutes(500),
          languageCode: 'ru',
          article: '',
        )!.minutes,
        120,
      );
      // Не число — не повод ронять гайд: показываем значение по умолчанию.
      expect(
        GuideContent.fromJson(
          withMinutes('7'),
          languageCode: 'ru',
          article: '',
        )!.minutes,
        3,
      );
    });

    test('без заголовка или описания гайд не показываем', () {
      expect(
        GuideContent.fromJson(
          {..._baseJson(), 'title': '   '},
          languageCode: 'ru',
          article: '',
        ),
        isNull,
      );
      expect(
        GuideContent.fromJson(
          {..._baseJson()}..remove('summary'),
          languageCode: 'ru',
          article: '',
        ),
        isNull,
      );
    });

    test('пустой список шагов — валидный гайд без схем', () {
      final content = GuideContent.fromJson(
        {..._baseJson(), 'shots': 'нет'},
        languageCode: 'en',
        article: '',
      );
      expect(content, isNotNull);
      expect(content!.shots, isEmpty);
    });

    test('координаты за пределами 0..1 прижимаются к сетке', () {
      final shot = GuideShot.fromJson({
        'title': 'Т',
        'caption': 'Ц',
        'focus': [-2, 0.5, 5, 2],
        'arrows': [
          {'from': [-1, 2], 'to': [3, -4]},
        ],
      });

      expect(shot, isNotNull);
      expect(shot!.focus, const Rect.fromLTWH(0, 0.5, 1, 1));
      expect(shot.arrows.single.from, const Offset(0, 1));
      expect(shot.arrows.single.to, const Offset(1, 0));
    });
  });
}
