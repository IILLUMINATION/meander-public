// Правила поиска ресурса по «источнику»: путь / имя из библиотеки / uuid.
// Ключевые semantics: путь не трогаем, неоднозначное имя не угадываем.

import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/engine/quest_resource_index.dart';

void main() {
  Map<String, dynamic> metadata() => {
    '0c958f72-92ca-4c96-a65a-c678e1548df2.jpg': {
      'name': 'Закат',
      'folder': '/картинки',
      'resourceId': 'res-42',
    },
    '11111111-1111-1111-1111-111111111111.png': {
      'name': 'Утро',
      'folder': '/картинки',
    },
    '22222222-2222-2222-2222-222222222222.mp3': {
      'name': 'Тема',
      'folder': '/звук',
    },
    // Легаси-запись: значение — просто строка (имя).
    '33333333-3333-3333-3333-333333333333.png': 'Легаси',
    '__folders__': ['/картинки', '/звук'],
  };

  final index = QuestResourceIndex.fromMetadata(metadata());

  group('directResourceCandidates — без метаданных', () {
    test('путь остаётся путём', () {
      expect(directResourceCandidates('res/images/a.png'), [
        'res/images/a.png',
      ]);
    });

    test('голое имя файла с известным расширением кладём в нужный каталог', () {
      expect(directResourceCandidates('0c958f72.jpg'), [
        'res/images/0c958f72.jpg',
      ]);
      expect(directResourceCandidates('theme.mp3'), ['res/audio/theme.mp3']);
      expect(directResourceCandidates('clip.mp4'), ['res/videos/clip.mp4']);
      expect(directResourceCandidates('bold.ttf'), ['res/fonts/bold.ttf']);
    });

    test('расширение не в нижнем регистре и с пробелами — ок', () {
      expect(directResourceCandidates('  A.PNG '), ['res/images/A.PNG']);
    });

    test('без расширения и с неизвестным — кандидатов нет', () {
      expect(directResourceCandidates('закат'), isEmpty);
      expect(directResourceCandidates('script.lua'), isEmpty);
      expect(directResourceCandidates(''), isEmpty);
      expect(directResourceCandidates('   '), isEmpty);
    });
  });

  group('QuestResourceIndex.pathCandidates', () {
    test('приоритет у пути: метаданные не читаются', () {
      expect(index.pathCandidates('res/images/custom.png'), [
        'res/images/custom.png',
      ]);
    });

    test('дружественное имя — путь файла с его расширением', () {
      expect(index.pathCandidates('Закат'), [
        'res/images/0c958f72-92ca-4c96-a65a-c678e1548df2.jpg',
      ]);
    });

    test('имя без учёта регистра и пробелов', () {
      expect(index.pathCandidates('  закат '), [
        'res/images/0c958f72-92ca-4c96-a65a-c678e1548df2.jpg',
      ]);
    });

    test('легаси-строка в метаданных работает как имя', () {
      expect(index.pathCandidates('Легаси'), [
        'res/images/33333333-3333-3333-3333-333333333333.png',
      ]);
    });

    test('resourceId', () {
      expect(index.pathCandidates('res-42'), [
        'res/images/0c958f72-92ca-4c96-a65a-c678e1548df2.jpg',
      ]);
    });

    test('uuid без расширения — по имени файла', () {
      expect(index.pathCandidates('22222222-2222-2222-2222-222222222222'), [
        'res/audio/22222222-2222-2222-2222-222222222222.mp3',
      ]);
    });

    test('неизвестный источник — пусто', () {
      expect(index.pathCandidates('нет-такого'), isEmpty);
    });

    test('служебный ключ __folders__ не участвует в поиске', () {
      expect(index.pathCandidates('__folders__'), isEmpty);
    });

    test('одно имя на несколько файлов — не угадываем', () {
      final ambiguous = QuestResourceIndex.fromMetadata({
        'a1.png': {'name': 'Фон'},
        'a2.png': {'name': 'фон'},
      });
      expect(ambiguous.pathCandidates('Фон'), isEmpty);
    });

    test('пустой индекс и пустой источник', () {
      expect(QuestResourceIndex.empty().pathCandidates('закат'), isEmpty);
      expect(QuestResourceIndex.empty().pathCandidates('a.png'), [
        'res/images/a.png',
      ]);
      expect(index.pathCandidates('  '), isEmpty);
    });

    test('файл с неизвестным расширением не даёт пути', () {
      final weird = QuestResourceIndex.fromMetadata({
        'note.txt': {'name': 'Записка'},
      });
      expect(weird.pathCandidates('Записка'), isEmpty);
    });

    // Реальный квест: картинку импортировали из источника без расширения,
    // файл лёг в res/images/<uuid>, в backgroundAssetId — то же имя. Раньше
    // каталог выбирался только по расширению, кандидатов не было вовсе, и фон
    // ноды/главы молча не показывался.
    test('файл без расширения — кандидаты во всех каталогах ресурсов', () {
      const name = 'aa31e0fa-c801-4861-8ad8-2cd5553228ef';
      final index = QuestResourceIndex.fromMetadata({
        name: {'name': 'jpg(2)', 'folder': '/'},
      });
      final candidates = index.pathCandidates(name);
      expect(candidates, contains('res/images/$name'));
      expect(candidates, contains('res/audio/$name'));
      expect(candidates, contains('res/videos/$name'));
      expect(candidates, contains('res/fonts/$name'));
    });
  });

  group('resourceReference — что вставляет пикер и «Копировать id»', () {
    test('картинка: короткое имя вместо пути', () {
      expect(
        resourceReference(fileName: 'cat.png', path: 'res/images/0c958f72.jpg'),
        'cat.png',
      );
    });

    test('скрипт: только путь, по имени файла он не ищется', () {
      expect(
        resourceReference(fileName: 'door.lua', path: 'scripts/door.lua'),
        'scripts/door.lua',
      );
    });

    test('то, что мы вставили, резолвер принимает без угадывания', () {
      for (final reference in [
        resourceReference(fileName: 'a.png', path: 'res/images/uuid.png'),
        resourceReference(fileName: 'b.mp3', path: 'res/audio/uuid.mp3'),
        resourceReference(fileName: 'c.ttf', path: 'res/fonts/uuid.ttf'),
      ]) {
        expect(directResourceCandidates(reference), isNotEmpty);
      }
    });
  });
}
