// Тело карточки ноды: что из контента видно без открытия ноды.
//
// Раньше на карточке были две строки первой top-level реплики, а остальное
// место пустовало: текст во вложенных row/column не находился вовсе, чат не
// читался. Теперь тело показывает реплики, подписи веток и сводку, а сколько
// именно влезает — решает `NodeBodyLayout` по высоте карточки.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canvas_app/models/canvas_models.dart';

Node node({
  Map<String, dynamic>? content,
  String description = '',
  String? scriptAssetId,
  Size size = const Size(150, 150),
}) {
  return Node(
    id: 'n1',
    position: Offset.zero,
    size: size,
    color: const Color(0xFF26C6DA),
    label: 'Нода',
    description: description,
    content: content,
    scriptAssetId: scriptAssetId,
  );
}

void main() {
  group('состав карточки', () {
    test('реплики собираются из вложенных row/column', () {
      final n = node(
        content: {
          'items': [
            {
              'type': 'row',
              'children': [
                {'type': 'text', 'text': 'Первая\nВторая'},
                {'type': 'chat', 'senderName': 'Голос', 'text': 'Третья'},
              ],
            },
            {
              'type': 'column',
              'children': [
                {'type': 'input', 'text': 'Назови имя'},
              ],
            },
          ],
        },
      );

      expect(n.textLines, ['Первая', 'Вторая', 'Голос: Третья', 'Назови имя']);
      expect(n.replyCount, 3);
    });

    test('кнопки дают подписи веток, скрипты — свой счётчик', () {
      final n = node(
        scriptAssetId: 'scripts/x.json',
        content: {
          'items': [
            {'type': 'text', 'text': 'Иди'},
            {'type': 'button', 'text': 'Во двор'},
            {'type': 'button', 'text': 'Домой'},
            {'type': 'script'},
          ],
        },
      );

      expect(n.branchLabels, ['Во двор', 'Домой']);
      expect(n.scriptCount, 2);
      expect(n.countersLabel, '1 реплика · 2 ветки');
    });

    test('правка контента пересобирает карточку', () {
      final n = node(
        content: {
          'items': [
            {'type': 'text', 'text': 'Было'},
          ],
        },
      );
      expect(n.textLines, ['Было']);

      n.content = {
        'items': [
          {'type': 'text', 'text': 'Стало\nЕщё строка'},
        ],
      };
      n.invalidateTextCache();

      expect(n.textLines, ['Стало', 'Ещё строка']);
      expect(n.bodyPainters(120, 3, color: Colors.white), hasLength(2));
    });

    test('без реплик показывается описание ноды', () {
      final n = node(description: 'Заметки автора');
      expect(n.textLines, ['Заметки автора']);
      expect(n.replyCount, 0);
    });

    test('фон выигрывает у картинки контента, иначе берётся первая картинка', () {
      final withBackground = Node(
        id: 'a',
        position: Offset.zero,
        color: const Color(0xFF26C6DA),
        label: 'A',
        description: '',
        backgroundAssetId: 'bg.png',
        content: {
          'items': [
            {'type': 'image', 'resourcePath': 'res/images/item.jpg'},
          ],
        },
      );
      expect(NodeRenderer.thumbnailSource(withBackground), 'bg.png');

      final withImage = node(
        content: {
          'items': [
            {'type': 'text', 'text': 'Текст'},
            {'type': 'image', 'resourcePath': 'res/images/item.jpg'},
          ],
        },
      );
      expect(NodeRenderer.thumbnailSource(withImage), 'res/images/item.jpg');
      expect(NodeRenderer.thumbnailSource(node()), isNull);
    });
  });

  group('раскладка тела', () {
    NodeBodyLayout fit({
      required int lines,
      required int branches,
      required bool counters,
      Size size = const Size(150, 150),
    }) {
      return NodeBodyLayout.fit(
        height: size.height,
        lineCount: lines,
        branchCount: branches,
        hasCounters: counters,
      );
    }

    test('на 150×150 текст и две ветки делят тело', () {
      final layout = fit(lines: 10, branches: 2, counters: true);
      expect(layout.lines, 3);
      expect(layout.chips, 2);
      expect(layout.counters, isFalse);
    });

    test('короткий текст не отнимает место у веток', () {
      final layout = fit(lines: 3, branches: 2, counters: true);
      expect(layout.lines, 3);
      expect(layout.chips, 2);
    });

    test('без веток текст занимает тело целиком', () {
      final layout = fit(lines: 10, branches: 0, counters: true);
      expect(layout.lines, 5);
      expect(layout.chips, 0);
      expect(layout.counters, isFalse);
    });

    test('сводка остаётся, если не отнимает реплику', () {
      final layout = fit(lines: 3, branches: 0, counters: true);
      expect(layout.lines, 3);
      expect(layout.counters, isTrue);
    });

    test('высокая карточка показывает больше строк и сводку', () {
      final layout = fit(
        lines: 10,
        branches: 2,
        counters: true,
        size: const Size(150, 300),
      );
      expect(layout.lines, 6);
      expect(layout.chips, 2);
      expect(layout.counters, isTrue);
    });

    test('нода без текста отдаёт тело веткам', () {
      final layout = fit(lines: 0, branches: 3, counters: true);
      expect(layout.lines, 0);
      expect(layout.chips, 3);
      expect(layout.counters, isTrue);
    });

    test('меню из пяти веток показывает четыре и не дублирует сводку', () {
      final layout = fit(lines: 0, branches: 5, counters: true);
      expect(layout.chips, 4);
      expect(layout.counters, isFalse);
    });
  });
}
