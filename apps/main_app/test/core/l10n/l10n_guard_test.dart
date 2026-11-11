import 'dart:io';

import 'package:canvas_app/core/l10n/app_language.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/core/utils/playtime_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Гард перевода по исходникам `lib/`.
///
/// Механизм (`L10n`) уже покрыт `l10n_core_test.dart`; этот файл сторожит не
/// механизм, а данные: словарь английского обязан поспевать за строками
/// интерфейса, а сами строки — оставаться в форме, которую механизм видит.
/// Правила выросли из ошибок кампании перевода, поэтому каждое объяснено
/// рядом с проверкой.
///
/// Все проверки — чистые функции от текста файла, поэтому негативные
/// контроли гоняются на синтетических исходниках в этом же файле: никакого
/// мутационного редактирования `lib/`, чтобы убедиться, что проверка не
/// пустая. Плюс «пол» в проверке покрытия: сломанный сканер, который не
/// находит ни одного ключа, проваливает тест сам, а не молча «всё перевод».
void main() {
  final sources = _libSources();

  group('гард по lib/', () {
    test('файлов много, сканер не ослеп', () {
      expect(sources.length, greaterThan(300));
    });

    test('каждая строка tr()/trf() есть в словаре английского', () {
      final dictionary = L10n.byCode('en').dictionary;
      final missing = <String>[];
      var total = 0;
      final seen = <String>{};
      for (final entry in sources.entries) {
        final scan = _scan(entry);
        for (final key in scan.keys) {
          total++;
          seen.add(key);
          if (!dictionary.containsKey(key)) {
            missing.add('${entry.key}:${scan.lineOfKey(key)}  «$key»');
          }
        }
      }
      // Пол: ключей реально тысячи. Сломанный сканер, который ничего не
      // нашёл бы, проваливает тест сам, а не молча «всё переведено».
      expect(total, greaterThan(2000), reason: 'сканер нашёл подозрительно мало ключей');
      expect(seen.length, greaterThan(1800));
      expect(missing, isEmpty, reason: 'без перевода английский покажет русский');
    });

    test('каждая форма числа из trp() есть в словаре форм', () {
      final plurals = L10n.byCode('en').plurals;
      final seen = <String>{};
      final missing = <String>[];
      for (final entry in sources.entries) {
        final scan = _scan(entry);
        for (final lemma in scan.trpLemmaAt.keys) {
          if (seen.add(lemma) && !plurals.containsKey(lemma)) {
            missing.add('${scan.trpLemmaAt[lemma]}  «$lemma»');
          }
        }
      }
      // Без записи trp() посреди английского предложения молча вернёт русскую
      // форму: «5 дней» станет «5 дней» вместо «5 days».
      expect(missing..sort(), isEmpty, reason: 'английский покажет русскую форму числа');
    });

    test('в словаре нет строк, которых больше нет в коде', () {
      final dictionary = L10n.byCode('en').dictionary;
      final plurals = L10n.byCode('en').plurals;
      final used = <String>{};
      final lemmas = <String>{};
      for (final source in sources.entries) {
        final scan = _scan(source);
        used.addAll(scan.keys);
        lemmas.addAll(scan.lemmas);
      }
      // Мёртвая запись безвредна на экране, но врёт в отчёте о покрытии и
      // раздувает словарь: такие строки вычищаем.
      expect(
        dictionary.keys.where((k) => !used.contains(k)).toList()..sort(),
        isEmpty,
        reason: 'этих строк нет в lib/ — словарь устарел',
      );
      expect(
        plurals.keys.where((k) => !lemmas.contains(k)).toList()..sort(),
        isEmpty,
        reason: 'форма числа, которую никто не запрашивает',
      );
    });

    test('в переводе нет плейсхолдеров, которых нет в русской строке', () {
      final dictionary = L10n.byCode('en').dictionary;
      final bad = <String>[];
      for (final source in sources.entries) {
        for (final key in _scan(source).keys.toSet()) {
          final value = dictionary[key];
          if (value == null) continue;
          final extra = _placeholders(value).difference(_placeholders(key));
          if (extra.isNotEmpty) {
            bad.add('${source.key}  «$key» -> лишний {${extra.join(', ')}}');
          }
        }
      }
      // `{n}` в переводе без `{n}` в ключе_trf() не подставит ничего, и
      // человек увидит фигурные скобки на экране.
      expect(bad, isEmpty);
    });

    test('ключ перевода — один литерал без интерполяций и без tr(tr())', () {
      final bad = <String>[];
      for (final entry in sources.entries) {
        final scan = _scan(entry);
        bad
          ..addAll(scan.joined)
          ..addAll(scan.interpolated)
          ..addAll(scan.dynamicKey)
          ..addAll(scan.nested);
      }
      // Склейка `'а' 'б'` и `tr('a$name')` дают ключ, которого в словаре нет:
      // lookup промахивается, и в английском остаётся русский.
      expect(bad, isEmpty);
    });

    test('таблицы отображения не застывают: tr() только в геттерах', () {
      final frozen = <String>[];
      for (final entry in sources.entries) {
        frozen.addAll(_scan(entry).frozen);
      }
      // `static final`/верхнеуровневый `final` инициализируется один раз:
      // смена языка такие подписи не перекрашивает до перезапуска.
      expect(frozen, isEmpty);
    });

    test('виджет с tr() не создают const-экземпляром', () {
      // Первый проход собирает классы, в коде которых есть tr(): их подписи
      // зависят от активного языка.
      final translating = <String, Set<String>>{};
      final scans = <_FileScan>[];
      for (final entry in sources.entries) {
        final scan = _scan(entry);
        for (final name in scan.translatingWidgets) {
          (translating[name] ??= <String>{}).add(scan.file);
        }
        scans.add(scan);
      }
      // Второй проход ищет `const Имя(` этих классов: Flutter не перестраивает
      // элемент, если родитель вернул тот же экземпляр, а `const`-инстанс
      // именно такой — экран переживёт смену языка старыми строками.
      final frozen = <String>[];
      for (final scan in scans) {
        scan.flagConstWidgets(translating);
        frozen.addAll(scan.constWidgets);
      }
      expect(translating, isNotEmpty, reason: 'сканер не нашёл ни одного языкового виджета');
      expect(
        frozen..sort(),
        isEmpty,
        reason: 'эти виджеты переживут смену языка старыми строками:\n${frozen.join('\n')}',
      );
    });

    test('кириллица в позиции отображения завёрнута в tr()', () {
      final unwrapped = <String>[];
      for (final entry in sources.entries) {
        unwrapped.addAll(_scan(entry).display);
      }
      expect(unwrapped, isEmpty, reason: 'эти подписи останутся русскими в EN');
    });

    test('дыр вне витрины нет: фолбэки, ветки, возвраты, склейки и витринные '
        'аргументы завёрнуты', () {
      final holes = <String>[];
      for (final entry in sources.entries) {
        holes.addAll(_scan(entry).holes);
      }
      // `Text('текст')` — только один способ попасть на экран. Так же ведут
      // себя `title ?? 'Без названия'`, `ok ? 'Да' : 'Нет'`, `return 'Готово'`,
      // `'Всего: ' + n` и `_showSuccess('Сохранено')`: гард по заголовку строки
      // их не видел, и в английском режиме оставался русский.
      expect(
        holes..sort(),
        isEmpty,
        reason: 'без tr() эти строки останутся русскими:\n${holes.join('\n')}',
      );
    });
  });

  group('негативные контроли сканера', () {
    test('литерал вне tr() в витринной позиции — находка, в чистой — нет', () {
      final dirty = _FileScan(
        'dirty.dart',
        r'''
class Screen {
  Widget build() {
    return Column(children: [
      Text('Нажми'),
      Text(tr('Нажми')),
    ]);
  }
}
''',
      );
      expect(dirty.display, hasLength(1));
      expect(dirty.keys, [
        'Нажми',
      ]);

      final clean = _FileScan(
        'clean.dart',
        r'''
class Screen {
  Widget build() {
    return Column(children: [
      Text(tr('Нажми')),
      const SizedBox(height: 4),
      if (kind == 'ошибка') Icon(Icons.close),
    ]);
  }
}
''',
      );
      expect(clean.display, isEmpty);
      expect(clean.keys, [
        'Нажми',
      ]);
    });

    test('дыра вне витрины ловится в каждом классе позиции', () {
      final dirty = _FileScan(
        'dirty.dart',
        r'''
class Screen {
  String done() {
    return 'Готово';
  }

  Widget build(int count) {
    final title = node.title ?? 'Без названия';
    final hint = count > 0 ? 'Есть' : 'Пусто';
    final suffix = count + ' строк';
    final name = switch (count) {
      0 => 'Ноль',
      _ => 'Много',
    };
    _showSuccess('Сохранено');
    emit(0.02, 'Подготовка очистки');
    trf('Всего {p0}', {'p0': 'много'});
    debugPrint(
      'Первая часть '
      'вторая часть',
    );
    return Text(title);
  }
}
''',
      );
      // Двенадцать подписей — двенадцать дыр: по одной на каждую ветку
      // тернарника и на каждую руку switch. `'а' 'б'` считает и левую
      // половину: правую видит класс склейки, левую добивает тело `build()`.
      expect(dirty.holes, hasLength(12));
      expect(
        dirty.holes.map((h) => h.split('  ')[1]).toSet(),
        containsAll(<String>[
          'фолбэк ??',
          'ветка тернарника',
          'ветка =>',
          'возврат',
          'склейка +',
          'склейка литералов',
          'подстановка trf',
          'аргумент _showSuccess(',
          'аргумент emit(',
          'тело build()',
        ]),
      );

      final fixed = _FileScan(
        'fixed.dart',
        r'''
class Screen {
  String done() {
    return tr('Готово');
  }

  Widget build(int count) {
    final title = node.title ?? tr('Без названия');
    final hint = count > 0 ? tr('Есть') : tr('Пусто');
    final suffix = trf('{p0} строк', {'p0': count});
    final name = switch (count) {
      0 => tr('Ноль'),
      _ => tr('Много'),
    };
    _showSuccess(tr('Сохранено'));
    emit(0.02, tr('Подготовка очистки'));
    trf('Всего {p0}', {'p0': tr('много')});
    debugPrint(tr('Первая часть вторая часть'));
    return Text(title);
  }
}
''',
      );
      expect(fixed.holes, isEmpty);
      expect(fixed.display, isEmpty);
    });

    test('литерал в теле build() без явной позиции — всё равно дыра', () {
      // Класс #324: `_displayHeadRe` смотрит на заголовок строки, поэтому
      // `if (...) 'Подпись',` в списке и `' · '` перед `.join()` он не видит,
      // а на экран они уходят. Уберите `_inBuild` из `_positionKind` — находки
      // не станет, и проверка ниже провалится.
      final dirty = _FileScan(
        'dirty.dart',
        r'''
class Screen {
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (flag) 'Подпись',
        Text(['Аудио', kind == 'ошибка' ? '' : ''].join(' · ')),
      ],
    );
  }
}
''',
      );
      expect(dirty.holes, hasLength(2));
      expect(dirty.holes.every((h) => h.contains('тело build()')), isTrue);

      final fixed = _FileScan(
        'fixed.dart',
        r'''
class Screen {
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (flag) tr('Подпись'),
        Text([tr('Аудио'), kind == 'ошибка' ? '' : ''].join(' · ')),
      ],
    );
  }
}
''',
      );
      // Сравнение (`kind == 'ошибка'`) — данные: `_isCompare` обязана держать
      // его вне находки и после завёртки соседей.
      expect(fixed.holes, isEmpty);
      expect(fixed.display, isEmpty);
    });

    test('литерал в конструкторе исключения — дыра, tr() её закрывает', () {
      // Контроль класса #323: `friendlyError(e)` берёт первую строку
      // `e.toString()`, поэтому текст внутри `Exception(...)` — то же самое,
      // что текст в `_showError(...)`. Уберём конструкторы из `_displaySinks` —
      // и грязный образец станет чистым, то есть контроль не бутафорский.
      final dirty = _FileScan(
        'dirty_service.dart',
        r'''
class Service {
  void run(String path) {
    if (path.isEmpty) throw Exception('Файл не выбран');
    throw CloudSyncException('Не авторизованы', status: 401);
  }
}
''',
      );
      expect(dirty.holes, hasLength(2));
      expect(
        dirty.holes.map((h) => h.split('  ')[1]).toSet(),
        containsAll(<String>[
          'аргумент Exception(',
          'аргумент CloudSyncException(',
        ]),
      );

      final fixed = _FileScan(
        'fixed_service.dart',
        r'''
class Service {
  void run(String path) {
    if (path.isEmpty) throw Exception(tr('Файл не выбран'));
    throw CloudSyncException(tr('Не авторизованы'), status: 401);
  }
}
''',
      );
      expect(fixed.holes, isEmpty);
    });

    test('исключение, которое только в логе, остаётся исключением из дыр', () {
      // `import_service.dart` бросает строку, чтобы тут же поймать её и
      // написать в stdout; `block_models.dart` ловит своё же FormatException и
      // прячет блок как UnknownBlock. Обоим нужен не перевод, а сноска.
      final logged = _FileScan(
        'import_service.dart',
        "throw Exception('Пропуск расшифровки для MND_ZIP_ файла.');",
      );
      expect(logged.holes, isEmpty);

      final elsewhere = _FileScan(
        'other_service.dart',
        "throw Exception('Пропуск расшифровки для MND_ZIP_ файла.');",
      );
      expect(elsewhere.holes, hasLength(1));
    });

    test('литерал, который остаётся данными, не считается дырой', () {
      // Тот же `??`-фолбэк, но строка — значение модели: её снимает перевод на
      // витрине, поэтому сноска в `_dataHold` обязана её пропускать. Без
      // сноски гард требовал бы tr() там, где он ломает данные.
      final guarded = _FileScan(
        'block_models.dart',
        "final placeholder = json['title'] ?? 'Не выбрана';",
      );
      expect(guarded.holes, isEmpty);

      final notExempt = _FileScan(
        'other_screen.dart',
        "final placeholder = json['title'] ?? 'Не выбрана';",
      );
      expect(notExempt.holes, hasLength(1));
    });

    test('ключ из двух склеенных литералов ловится', () {
      final scan = _FileScan(
        'joined.dart',
        r'''
final label = Text(tr('Долгая '
    'подпись'));
''',
      );
      expect(scan.joined, hasLength(1));
      // Один литерал — тот же смысл, но уже без нарушения.
      final fixed = _FileScan(
        'fixed.dart',
        r'''
final label = Text(tr('Долгая подпись'));
''',
      );
      expect(fixed.joined, isEmpty);
      expect(fixed.display, isEmpty);
      expect(fixed.keys, [
        'Долгая подпись',
      ]);
    });

    test('интерполяция внутри ключа ловится', () {
      final scan = _FileScan(
        'interp.dart',
        r'''
String greet(String name) => tr('Привет, $name');
''',
      );
      expect(scan.interpolated, hasLength(1));
      final fixed = _FileScan(
        'fixed.dart',
        r'''
String greet(String name) => trf('Привет, {name}', {'name': name});
''',
      );
      expect(fixed.interpolated, isEmpty);
      expect(fixed.keys, [
        'Привет, {name}',
      ]);
    });

    test('tr() со значением переменной ловится', () {
      final scan = _FileScan(
        'dyn.dart',
        r'''
String render(String raw) => tr(raw);
''',
      );
      expect(scan.dynamicKey, hasLength(1));
      expect(scan.keys, isEmpty);
    });

    test('вложенный tr(tr()) ловится', () {
      final scan = _FileScan(
        'nest.dart',
        r'''
String twice() => tr(tr('Готово'));
''',
      );
      expect(scan.nested, hasLength(1));
    });

    test('застывшая таблица ловится и в нулевой колонке, и в static', () {
      final topLevel = _FileScan(
        'top.dart',
        r'''
const presets = [
  Named('Бежевый'),
  'Лесной',
];

final labels = [
  tr('Сохранить'),
  'Отмена',
];
''',
      );
      expect(topLevel.frozen, hasLength(1));

      final staticTable = _FileScan(
        'member.dart',
        r'''
class Registry {
  static final builtIn = [
    Preset(name: tr('Бежевый')),
  ];

  static List<Preset> get fresh => [
    Preset(name: tr('Бежевый')),
  ];

  Widget build() {
    final local = [
      tr('Локально'),
    ];
    return Text(local.first);
  }
}
''',
      );
      // Геттер и локальная переменная — норма: они строятся заново.
      expect(staticTable.frozen, hasLength(1));
      expect(staticTable.frozen.single, contains('static final builtIn'));
    });

    test('формы числа: trp() даёт лемму, словарь лемм пополняется', () {
      final scan = _FileScan(
        'plural.dart',
        r'''
int n = 3;
String a() => trp(['минута', 'минуты', 'минут'], n);
String b() => _count(7, ['игрок', 'игрока', 'игроков']);
String c() => tr('Привет');
''',
      );
      expect(scan.lemmas, containsAll(['минута', 'игрок']));
      // Формы числа — не ключи tr(): они живут в словаре форм.
      expect(scan.keys, ['Привет']);
      expect(scan.display, isEmpty);
      // В обязательный словарь форм попадают только леммы из trp(): список,
      // переданный помощнику, — ещё не заявка на форму числа.
      expect(scan.trpLemmaAt.keys, ['минута']);
      expect(scan.trpLemmaAt['минута'], 'plural.dart:2');
    });

    test('const напротив языкового виджета ловится, геттер — нет', () {
      _FileScan scanOf(String name, String source) {
        final scan = _FileScan(name, source);
        scan.flagConstWidgets({
          for (final widget in scan.translatingWidgets) widget: {scan.file},
        });
        return scan;
      }

      const declaring = r'''
class HintCard extends StatelessWidget {
  const HintCard({super.key});

  Widget build(BuildContext context) => Text(tr('подсказка'));
}
''';

      final dirty = scanOf(
        'dirty.dart',
        declaring +
            r'''
class Screen extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
    const HintCard(),
    const Row(children: [HintCard()]),
  ]);
}
''',
      );
      // И явный const на месте виджета, и молча канонизированный дочерний
      // внутри чужого const-блока: оба не перерисовываются.
      expect(dirty.constWidgets, hasLength(2));
      expect(dirty.constWidgets.first, contains('const HintCard(...)'));
      expect(
        dirty.constWidgets.last,
        contains('HintCard(...) внутри const Row'),
      );

      // Объявление `const HintCard({super.key})` — не создание виджета.
      expect(scanOf('clean.dart', declaring).constWidgets, isEmpty);
      expect(
        scanOf(
          'getter.dart',
          declaring +
              r'''
class Screen extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
    HintCard(),
    const SizedBox(height: 8, child: Text('а')),
    const EdgeInsets.only(top: 4).hashCode,
  ]);
}
''',
        ).constWidgets,
        isEmpty,
      );
    });

    test('ключ из тройных кавычек читается как рантайм-строка', () {
      final scan = _FileScan(
        'multi.dart',
        "String help() => trf('''\ncore.get_var('x')\n''', {});\n",
      );
      expect(scan.keys, ["\ncore.get_var('x')\n"]);
      expect(scan.keys.single.contains(r'\n'), isFalse);
    });

    test('комментарии и строки-данные не считаются ключами', () {
      final scan = _FileScan(
        'quiet.dart',
        r'''
// tr('в комментарии')
/* tr('в блоке') */
class C {
  static const path = 'core/l10n/';
  final map = {'ключ': 'значение'};
}
''',
      );
      expect(scan.keys, isEmpty);
      expect(scan.frozen, isEmpty);
      expect(scan.display, isEmpty);
    });
  });

  group('хелперы следуют активному языку', () {
    tearDown(() => L10n.setCurrent(L10n.byCode(kSourceLanguageCode)));

    test('месяц сокращения и игровое время переводятся', () {
      expect(monthShort(1), 'янв');
      expect(PlaytimeFormatter.format(0), '0 мин.');
      expect(PlaytimeFormatter.format(125), '2 мин.');

      L10n.setCurrent(L10n.byCode('en'));
      expect(monthShort(5), 'May');
      expect(PlaytimeFormatter.format(0), '0 min.');
      expect(PlaytimeFormatter.format(45), '< 1 min.');
      expect(PlaytimeFormatter.format(125), '2 min.');
      expect(PlaytimeFormatter.format(3600), '1 h');
      expect(PlaytimeFormatter.format(3725), '1 h 2 min');
    });

    test('формы числа английского языка — всегда одна и много', () {
      final plurals = L10n.byCode('en').plurals;
      expect(plurals.values, everyElement(hasLength(2)));
      L10n.setCurrent(L10n.byCode('en'));
      expect(trp(['лайк', 'лайка', 'лайков'], 1), 'like');
      expect(trp(['лайк', 'лайка', 'лайков'], 21), 'likes');
    });
  });
}

/// Подписи, которые мы держим незавернутыми осознанно: тот же текст служит
/// значением (`parser.dart` и `quest_script_events.dart` сравнивают его,
/// HTML-рантайм ищет по нему ветку), поэтому tr() разорвал бы разбор в
/// английском режиме.
const Set<String> _displayHold = {'Функция'};

/// Функции и конструкторы, чей строковый аргумент уходит на экран: снапбары,
/// подсказки полей, прогресс импорта и чистки, сообщения результатов. Список
/// вырос из разбора `lib/`; новое имя добавляем вместе с первым использованием.
///
/// Конструкторы ошибок — в том же списке: `friendlyError(e)` берёт первую
/// строку `e.toString()` и показывает её человеку (`my_quests_screen.dart:275`
/// и десятки таких же catch'ей), поэтому `throw Exception('Квест не найден')`
/// — та же дыра, что `_showError('Квест не найден')`.
///
/// `block` из списка нет: `NetworkUrlDecision.block(reason)` — единственный
/// витринный кандидат по имени, но `reason` никто не читает, плеер смотрит
/// только `allowed`. Держать его в списке — значит требовать перевода для
/// строк, которые человек не увидит никогда.
const Set<String> _displaySinks = {
  '_showSuccess',
  '_showError',
  '_snackWithUndo',
  '_decoration',
  '_buildFolderBreadcrumb',
  'call',
  'emit',
  'error',
  'ArgumentError',
  'CloudSyncException',
  'Exception',
  'FormatException',
  'StateError',
  'TimeoutException',
};

/// Литералы вне витрины, которые остаются данными: имя файла, ключ старого
/// формата, значение-заглушка модели (её снимает перевод на витрине —
/// `displayFieldSentinel`), текст лога. Ключ — `имя файла|текст`, чтобы сноска
/// не скрывала ту же строку в другом файле.
///
/// Разбор по доводам (второй проход, #320):
/// * заглушки полей блока и «Нода не найдена» — значения, которые оседают в
///   файле квеста; старый файл обязан остаться читаемым, поэтому переводит
///   витрина (`displayFieldSentinel`, `_displayDefaultNodeName`);
/// * «Кнопка» при импорте .qst — текст контента, который придумывает
///   автор квеста; контент не переведём никогда;
/// * «таблица»/«Таблица» — имена файла и листа XLSX на диске;
/// * строки `bootstrap.dart` — debugPrint и crash-лог, их читает разработчик;
/// * исключения-невидимки: `import_service.dart` бросает свою строку, чтобы
///   тут же поймать её и написать в stdout (проба расшифровки), а
///   `block_models.dart` ловит собственное FormatException и прячет блок как
///   `UnknownBlock` — оба текста человек не видит ни в одном режиме.
const Set<String> _dataHold = {
  // Значения-заглушки модели: их снимает перевод на витрине.
  'block_models.dart|Не выбрана',
  'block_models.dart|Не выбран',
  'block_models.dart|имя_переменной',
  'block_models.dart|Выберите объект',
  'block_models.dart|Выберите ноду',
  'block_models.dart|Выберите скрипт',
  'block_models.dart|Выберите функцию',
  'block_models.dart|Выберите .lua',
  'block_models.dart|Выберите аудио',
  'block_models.dart|Все звуки',
  'block_models.dart|Выберите музыку',
  'go_to_node_block_widget.dart|Нода',
  'node_content_screen.dart|Нода не найдена',
  'node_settings_screen.dart|Нода не найдена',
  // Текст контента квеста, а не интерфейса.
  'qst_converter.dart|Кнопка',
  'qst_parser.dart|Кнопка',
  // Имена файлов и листов.
  'table_export_service.dart|таблица',
  'table_export_service.dart|Таблица',
  // Лог разработчика.
  'bootstrap.dart|Соберите библиотеку: {buildHint}. Ошибка: {e}',
  'bootstrap.dart|(нет стека)',
  'import_service.dart|Пропуск расшифровки для MND_ZIP_ файла.',
  r"block_models.dart|неизвестная операция таблицы: ${json['operation']}",
  // Тот же класс, но внутри `build(...)`: значение пишется в модель блока, а
  // витрина переводит его при показе.
  'call_lua_block_widget.dart|Выберите .lua',
  'stop_sound_block_widget.dart|Все звуки',
  // Форма числа уходят в `_count(...)` → `trp`/`trpMany`: словарь форм
  // берёт их по лемме, а `tr()` по полной строке их бы только сломал.
  'author_analytics_screen.dart|просмотр',
  'author_analytics_screen.dart|просмотра',
  'author_analytics_screen.dart|просмотров',
  'author_analytics_screen.dart|скачивание',
  'author_analytics_screen.dart|скачивания',
  'author_analytics_screen.dart|скачиваний',
  'author_analytics_screen.dart|игрок',
  'author_analytics_screen.dart|игрока',
  'author_analytics_screen.dart|игроков',
  'author_analytics_screen.dart|лайк',
  'author_analytics_screen.dart|лайка',
  'author_analytics_screen.dart|лайков',
  // Образец ссылки вида `{таблица["колонка"][1]}`: это синтаксис пути,
  // а не проза — внутри машинного токена слово не переводят.
  'table_path_picker.dart|колонка',
};

String _basename(String file) => file.split('/').last;

Map<String, String> _libSources() {
  final root = Directory('lib');
  if (!root.existsSync()) {
    throw StateError(
      'гард запускается из apps/main_app: каталог lib/ не найден '
      '(${Directory.current.path})',
    );
  }
  final out = <String, String>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final rel = entity.path.replaceAll(r'\', '/');
    // Ядро перевода: его литералы — это сам словарь и названия языков.
    if (rel.contains('/l10n/')) continue;
    out[rel] = entity.readAsStringSync();
  }
  return out;
}

/// Файл глазами гарда: ищем и ключи, и нарушения.
_FileScan _scan(MapEntry<String, String> entry) =>
    _FileScan(entry.key, entry.value);

final RegExp _callRe = RegExp(
  r'(?<![A-Za-z0-9_$])(tr|trf|trp|trpMany)\(',
);
final RegExp _nestedRe = RegExp(
  r'(?<![A-Za-z0-9_$])tr[frp]?\(\s*tr[frp]?\(',
);
final RegExp _placeholderRe = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');

/// Метод `build(` — тело, где виджет собирает строки на экран.
final RegExp _buildRe = RegExp(r'(?<![A-Za-z0-9_$])build\s*\(');

/// Объявления-таблицы: в нулевой колонке (верхний уровень файла) и `static`
/// члены класса. Локальные `final` внутри методов отформатированы с отступом
/// и без `static`, а значит пересоздаются на каждый вызов — они не застывают.
final RegExp _frozenRe = RegExp(
  r'^(?:const|final|late final)[ \t]|^[ \t]+static (?:late )?(?:const|final)[ \t]',
  multiLine: true,
);
final RegExp _displayHeadRe = RegExp(
  r'(?:\b(?:Text|Tooltip|RichText|SelectableText|SnackBar|Snackbar|MenuItemButton)'
  r'\s*\(\s*(?:key:[^,]+,\s*)?|[ \t]*(?:label|labelText|hintText|helperText|tooltip'
  r'|message|title|titleText|subtitle|semanticsLabel|placeholder|description'
  r'|errorText|body|heading)\s*:)\s*$',
);

Set<String> _placeholders(String text) => {
  for (final match in _placeholderRe.allMatches(text)) match.group(1)!,
};

/// Объявления классов верхнего уровня (класс в Dart не может быть локальным).
final RegExp _classRe = RegExp(
  r'^(?:abstract |sealed |base |final |interface )*class\s+([A-Za-z_$][A-Za-z0-9_$]*)',
  multiLine: true,
);

/// `State<X>`/`ConsumerState<X>` — рисует `X`, его и проверяем на `const`.
final RegExp _stateRe = RegExp(r'State<\s*([A-Za-z_$][A-Za-z0-9_$]*)');
/// Любой `const`-контекст: вызов виджета или литерал коллекции — `const Row(`,
/// `const <Widget>[`. Группа 1 — имя (пусто у литерала), группа 2 — скобка.
final RegExp _constRe = RegExp(
  r'(?<![A-Za-z0-9_$])const\s+(?:<[^<>\n]*>)?([A-Za-z_$][A-Za-z0-9_$]*)?'
  r'(?:<[^<>\n]*>)?\s*([([{])',
);
final RegExp _callNameRe = RegExp(
  r'(?<![A-Za-z0-9_$])([A-Za-z_$][A-Za-z0-9_$]*)\s*\(',
);

const String _openBrace = '{';
const String _closeBrace = '}';

/// Строковый литерал Dart: позиция, конец, тело, флаг сырого и флаг
/// интерполяции.
class _Str {
  _Str(this.start, this.end, this.body, {required this.raw, required this.interp});

  final int start;
  final int end;
  final String body;
  final bool raw;
  final bool interp;
}

class _Src {
  _Src(this.src) {
    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == '/' && i + 1 < src.length) {
        if (src[i + 1] == '/') {
          final j = src.indexOf('\n', i);
          comments.add(_Range(i, j < 0 ? src.length : j));
          i = j < 0 ? src.length : j;
          continue;
        }
        if (src[i + 1] == '*') {
          final j = src.indexOf('*/', i + 2);
          comments.add(_Range(i, j < 0 ? src.length : j + 2));
          i = j < 0 ? src.length : j + 2;
          continue;
        }
      }
      final raw =
          (c == 'r' || c == 'R') &&
          i + 1 < src.length &&
          (src[i + 1] == '"' || src[i + 1] == "'") &&
          !(i > 0 && _isIdent(src[i - 1]));
      final quote = raw ? i + 1 : i;
      if (src[quote] != '"' && src[quote] != "'") {
        i++;
        continue;
      }
      final token = _read(quote, raw: raw, collect: true);
      if (token == null) {
        i++;
        continue;
      }
      tokens.add(token);
      byStart[token.start] = token;
      // Ключ — последний символ литерала: `prevNonSpace` возвращает индекс
      // символа, а не границу за ним.
      byEnd[token.end - 1] = token;
      i = token.end;
    }
    regions = [...tokens.map((t) => _Range(t.start, t.end)), ...comments]
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  final String src;
  final List<_Str> tokens = [];
  final List<_Range> comments = [];
  final Map<int, _Str> byStart = {};
  final Map<int, _Str> byEnd = {};

  /// Участки `${...}` внутри литералов: это код, а не текст строки.
  final List<_Range> interpolations = [];
  late final List<_Range> regions;
  List<int>? _lineStarts;

  _Str? readAt(int pos) {
    if (pos >= src.length) return null;
    final c = src[pos];
    if (c != '"' && c != "'") return null;
    return _read(pos, raw: false);
  }

  /// Есть ли литерал, начинающийся в окне после `from` (пропуская пробелы и
  /// переносы), — то же, что делает `tr('...')` в сканере ключей.
  _Str? literalAfter(int from) {
    var i = from;
    while (i < src.length && (src[i] == ' ' || src[i] == '\n' || src[i] == '\t')) {
      i++;
    }
    if (i >= src.length) return null;
    var raw = false;
    var quote = i;
    if ((src[i] == 'r' || src[i] == 'R') &&
        i + 1 < src.length &&
        (src[i + 1] == '"' || src[i + 1] == "'")) {
      raw = true;
      quote = i + 1;
    }
    if (src[quote] != '"' && src[quote] != "'") return null;
    return _read(quote, raw: raw);
  }

  /// Ближайший знаковый символ до `from`, сквозь пробелы и комментарии, или
  /// `null`, если до начала файла только пробелы и комментарии.
  int? prevNonSpace(int from) {
    var i = from;
    while (i >= 0) {
      final at = _commentAt(i);
      if (at >= 0) {
        i = comments[at].start - 1;
        continue;
      }
      if (!_isSpace(src[i])) return i;
      i--;
    }
    return null;
  }

  /// Ближайший знаковый символ начиная с `from`.
  int? nextNonSpace(int from) {
    var i = from;
    while (i < src.length) {
      final at = _commentAt(i);
      if (at >= 0) {
        i = comments[at].end;
        continue;
      }
      if (!_isSpace(src[i])) return i;
      i++;
    }
    return null;
  }

  /// Комментарий, на который указывает `pos` (-1 если его нет). Список
  /// комментариев отсортирован: файл сканируется слева направо.
  int _commentAt(int pos) {
    var low = 0, high = comments.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final range = comments[mid];
      if (pos < range.start) {
        high = mid - 1;
      } else if (pos >= range.end) {
        low = mid + 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  /// Имя вызова, чьи скобки открыты в `at`: `foo(` -> `foo`,
  /// `onProgress?.call(` -> `call`. Тип в угловых скобках перед именем не
  /// мешает: `const ForumCreateResult.error(` даёт `error`.
  String? calleeAt(int at) {
    var i = prevNonSpace(at - 1);
    if (i == null) return null;
    if (src[i] == '>') {
      // `Foo<Bar>.method(` — прыгаем через закрывающую `>` к имени.
      var depth = 0;
      var j = i;
      while (j >= 0) {
        final c = src[j];
        if (c == '>') depth++;
        if (c == '<') {
          depth--;
          if (depth == 0) break;
        }
        j--;
      }
      i = prevNonSpace(j - 1);
      if (i == null) return null;
    }
    if (!_isIdent(src[i])) return null;
    var start = i;
    while (start > 0 && _isIdent(src[start - 1])) start--;
    return src.substring(start, i + 1);
  }

  bool isCode(int pos) {
    var low = 0, high = interpolations.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final range = interpolations[mid];
      if (pos < range.start) {
        high = mid - 1;
      } else if (pos >= range.end) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    low = 0;
    high = regions.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final region = regions[mid];
      if (pos < region.start) {
        high = mid - 1;
      } else if (pos >= region.end) {
        low = mid + 1;
      } else {
        return false;
      }
    }
    return true;
  }

  int lineOf(int pos) {
    final starts = _lineStarts ??= _computeLineStarts();
    var low = 0, high = starts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (starts[mid] <= pos) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }

  List<int> _computeLineStarts() {
    final starts = <int>[0];
    for (var i = 0; i < src.length; i++) {
      if (src[i] == '\n') starts.add(i + 1);
    }
    return starts;
  }

  _Str? _read(int at, {required bool raw, bool collect = false}) {
    final q = src[at];
    final triple = at + 2 < src.length && src[at + 1] == q && src[at + 2] == q;
    var j = at + (triple ? 3 : 1);
    final bodyStart = j;
    var interp = false;
    while (j < src.length) {
      final c = src[j];
      if (!raw && c == _backslash) {
        j += 2;
        continue;
      }
      if (!raw && c == r'$') {
        final next = j + 1 < src.length ? src[j + 1] : '';
        if (next == '{') {
          interp = true;
          final end = _braceEnd(j + 1);
          if (end == null) return null;
          // Внутри `${...}` снова идёт код: `'$n ${trp(['день', 'дня'], n)}'`
          // — типичный случай, и гард обязан видеть такой вызов.
          if (collect) interpolations.add(_Range(j + 2, end - 1));
          j = end;
          continue;
        }
        if (_isIdentStart(next)) {
          interp = true;
          var k = j + 1;
          while (k < src.length && _isIdent(src[k])) { k++; }
          j = k;
          continue;
        }
      }
      if (triple) {
        if (c == q && j + 2 < src.length && src[j + 1] == q && src[j + 2] == q) {
          return _Str(
            at,
            j + 3,
            src.substring(bodyStart, j),
            raw: raw,
            interp: interp,
          );
        }
        j++;
        continue;
      }
      if (c == q) {
        return _Str(at, j + 1, src.substring(bodyStart, j), raw: raw, interp: interp);
      }
      if (c == '\n') return null;
      j++;
    }
    return null;
  }

  int? _braceEnd(int open) {
    var depth = 0;
    for (var j = open; j < src.length; j++) {
      final c = src[j];
      if (_openers.contains(c)) {
        depth++;
      } else if (_closers.contains(c)) {
        depth--;
        if (depth == 0) return j + 1;
      } else if (c == _backslash) {
        j++;
      }
    }
    return null;
  }
}

const String _backslash = '\\';
const String _openers = '([{';
const String _closers = ')]}';

bool _isIdentStart(String c) {
  if (c.isEmpty) return false;
  if (c == '_') return true;
  final code = c.codeUnitAt(0);
  return code >= 0x41 && code <= 0x5a || code >= 0x61 && code <= 0x7a;
}

bool _isIdent(String c) => c == r'$' || _isIdentStart(c);

class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int end;
}

/// Один файл глазами гарда: ключи, леммы форм числа и нарушения формата
/// ключей/таблиц/витрин.
class _FileScan {
  _FileScan(this.file, this.src, {this.strict = true}) {
    lex = _Src(src);
    _calls();
    _formLists();
    _classes();
    _nests();
    _buildBodies();
    _frozen();
    _display();
    _positions();
  }

  final String file;
  final String src;
  late final _Src lex;

  /// Ключи tr()/trf() — то, что обязано быть в словаре строк.
  final List<String> keys = [];

  /// Первые формы списков `[одна, мало, много]` — ключи словаря форм числа.
  final Set<String> lemmas = {};

  /// Леммы, которые реально просят через `trp([...], n)`: `lemma -> файл:строка`
  /// первого вхождения. Для них запись в словаре форм обязательна.
  final Map<String, String> trpLemmaAt = {};

  /// Позиции литералов, которые гард считает переводимыми (обёрнутыми).
  final Set<int> wrapped = {};

  /// Классы-виджеты этого файла, чей `build()` рисует tr(): их подписи живут
  /// от активного языка.
  final Set<String> translatingWidgets = {};

  /// `const` на месте такого виджета — залитый язык (см. `flagConstWidgets`).
  final List<String> constWidgets = [];

  final List<String> joined = [];
  final List<String> interpolated = [];
  final List<String> dynamicKey = [];
  final List<String> nested = [];
  final List<String> frozen = [];
  final List<String> display = [];

  /// Незавернутые строки вне витрины: `??`, ветка тернарника, `return`/`=>`,
  /// подстановка внутри `trf`, склейка через `+`, аргумент витринной функции.
  final List<String> holes = [];

  /// Интервалы вторых аргументов `trf(...)` — словарей подстановок.
  final List<_Range> _trfMaps = [];

  /// Без `strict` файл отдаёт свои ключи, но не нарушения — так смотрят
  /// на чужой WIP.
  final bool strict;

  void _report(List<String> bucket, String message) {
    if (strict) bucket.add(message);
  }

  int lineOfKey(String key) {
    final index = keys.indexOf(key);
    return index < 0 ? 0 : _lines[index];
  }

  final List<int> _lines = [];

  void _calls() {
    for (final match in _callRe.allMatches(src)) {
      if (!lex.isCode(match.start)) continue;
      final name = match.group(1)!;
      final after = match.end;
      if (name == 'trp' || name == 'trpMany') {
        _pluralList(after, fromTrp: true);
        continue;
      }
      final token = lex.literalAfter(after);
      if (token == null) {
        if (_looksLikeCode(after)) {
          _report(dynamicKey, '$file:${_line(match.start)}  $name(не литерал)');
        }
        continue;
      }
      wrapped.add(token.start);
      final key = _runtime(token);
      keys.add(key);
      _lines.add(_line(match.start));
      if (token.interp) {
        _report(interpolated, '$file:${_line(match.start)}  «$key»');
      }
      // Склейка `'а' 'б'`: lookup идёт по всей склейке, сканер — по первому
      // литералу, поэтому словарь обязан содержать и то, и другое.
      var next = token.end;
      while (next < src.length &&
          (src[next] == ' ' || src[next] == '\n' || src[next] == '\t')) {
        next++;
      }
      if (next < src.length && (src[next] == '"' || src[next] == "'")) {
        _report(joined, '$file:${_line(match.start)}  «$key» +…');
      }
      if (name == 'trf') _trfMapAfter(next);
    }
  }

  /// Записать словарь подстановок `trf('…', {...})`: литерал-значение внутри
  /// него — строка на экране, и её обязан увидеть `tr()`.
  void _trfMapAfter(int at) {
    var i = at;
    while (i < src.length && _isSpace(src[i])) { i++; }
    if (i >= src.length || src[i] != ',') return;
    i++;
    while (i < src.length && _isSpace(src[i])) { i++; }
    if (i >= src.length || src[i] != '{') return;
    final map = _span(i, '{', _closeBrace);
    if (map != null) _trfMaps.add(map);
  }

  /// Проход по всем списковым литералам: формы числа попадают в словари
  /// `plurals` по первой форме, и получить их можно только из кода.
  void _formLists() {
    for (var i = 0; i < src.length; i++) {
      if (src[i] != '[') continue;
      if (!lex.isCode(i)) continue;
      _pluralList(i, fromTrp: false);
    }
  }

  /// `[одна, мало, много]` — от 2 до 4 строковых литералов. Леммы собираем из
  /// любых таких списков: формы передают и напрямую в `trp([...])`, и через
  /// помощников вроде `_count(n, forms)`, иначе словарь форм выглядел бы
  /// мёртвым. Литералы считаются завёрнутыми только для `trp()`: список
  /// форм сам по себе ещё не переводимая строка.
  void _pluralList(int at, {required bool fromTrp}) {
    var i = at;
    while (i < src.length && _isSpace(src[i])) { i++; }
    if (i >= src.length || src[i] != '[') return;
    i++;
    final items = <_Str>[];
    while (i < src.length) {
      final token = lex.literalAfter(i);
      if (token == null) break;
      items.add(token);
      i = token.end;
      while (i < src.length && _isSpace(src[i])) { i++; }
      if (i < src.length && src[i] == ',') {
        i++;
        continue;
      }
      break;
    }
    if (i >= src.length || src[i] != ']' || items.isEmpty || items.length > 4) {
      return;
    }
    lemmas.add(_runtime(items.first));
    if (fromTrp) {
      trpLemmaAt.putIfAbsent(
        _runtime(items.first),
        () => '$file:${_line(at)}',
      );
      for (final token in items) {
        wrapped.add(token.start);
      }
    }
  }

  void _nests() {
    for (final match in _nestedRe.allMatches(src)) {
      if (!lex.isCode(match.start)) continue;
      _report(nested, '$file:${_line(match.start)}  ${match.group(0)}');
    }
  }

  void _frozen() {
    for (final match in _frozenRe.allMatches(src)) {
      if (!lex.isCode(match.start)) continue;
      final span = _initializer(match.start);
      if (span == null) continue;
      for (final call in _callRe.allMatches(src.substring(span.start, span.end))) {
        final abs = span.start + call.start;
        if (!lex.isCode(abs)) continue;
        if (call.group(1) == 'trpMany') continue;
        _report(
          frozen,
          '$file:${_line(match.start)}  '
          '${src.substring(match.start, src.indexOf('\n', match.start)).trim()}',
        );
        return;
      }
    }
  }

  /// Классы виджетов, в коде которых есть tr(). У `StatefulWidget` тело рисует
  /// `State`, поэтому цель — виджет из `State<X>`, его и создают. Считаем всё
  /// тело класса, а не один `build()`: подпись, собранная в хелпере, застывает
  /// ровно так же, как собранная в `build()`.
  void _classes() {
    for (final match in _classRe.allMatches(src)) {
      if (!lex.isCode(match.start)) continue;
      final brace = src.indexOf('{', match.end);
      if (brace < 0) continue;
      final header = src.substring(match.end, brace);
      final body = _span(brace, _openBrace, _closeBrace);
      if (body == null) continue;
      final stateOwner = _stateRe.firstMatch(header);
      final target = header.contains('Widget')
          ? match.group(1)!
          : stateOwner?.group(1);
      if (target == null) continue;
      if (!_rendersLanguage(body)) continue;
      translatingWidgets.add(target);
    }
  }

  /// Есть ли tr() в коде этого класса.
  bool _rendersLanguage(_Range body) {
    for (final call in _callRe
        .allMatches(src.substring(body.start, body.end))) {
      if (lex.isCode(body.start + call.start)) return true;
    }
    return false;
  }

  /// Сбалансированный блок `at..close`, прыгающий через строки и комментарии.
  _Range? _span(int at, String opener, String closer) {
    if (at >= src.length || src[at] != opener) return null;
    var depth = 0;
    var cursor = 0;
    var j = at;
    while (j < src.length) {
      final region = cursor < lex.regions.length ? lex.regions[cursor] : null;
      if (region != null && j >= region.start && j < region.end) {
        j = region.end;
        cursor++;
        continue;
      }
      if (region != null && j >= region.end) cursor++;
      final c = src[j];
      if (c == opener) {
        depth++;
      } else if (c == closer) {
        depth--;
        if (depth == 0) return _Range(at, j + 1);
      }
      j++;
    }
    return null;
  }

  /// `const HintCard()`, `const Row(children: [HintCard()])` и
  /// `const [HintCard()]` для виджета, который рисует tr(). Flutter не
  /// перестраивает элемент, когда родитель вернул тот же экземпляр, а
  /// `const`-инстанс именно такой: экран переживает смену языка старым.
  /// Канонизируется весь const-блок, поэтому проверяем содержимое любого
  /// `const`-контекста, а не только блоков самих языковых виджетов: чинится
  /// снятием `const` с блока-обёртки. Приватное имя ищем только в
  /// файле-объявителе — приватность в Dart файловая, одно и то же `_Header`
  /// в разных файлах ничего не знает друг о друге.
  void flagConstWidgets(Map<String, Set<String>> translating) {
    final found = <int, String>{};
    for (final match in _constRe.allMatches(src)) {
      if (!lex.isCode(match.start)) continue;
      final opener = match.group(2)!;
      final block = _span(
        match.end - 1,
        opener,
        _closers[_openers.indexOf(opener)],
      );
      if (block == null) continue;
      var after = block.end;
      while (after < src.length && _isSpace(src[after])) { after++; }
      // `const HintCard({super.key});` — объявление конструктора, не создание.
      if (after < src.length && (src[after] == ';' || src[after] == ':')) {
        continue;
      }
      final name = match.group(1);
      final owners = name == null ? null : translating[name];
      if (owners != null && (!name!.startsWith('_') || owners.contains(file))) {
        found[match.start] = '$file:${_line(match.start)}  const $name(...)';
      }
      for (final child in _callNameRe.allMatches(
        src.substring(block.start + 1, block.end - 1),
      )) {
        final abs = block.start + 1 + child.start;
        final childName = child.group(1)!;
        final childOwners = translating[childName];
        if (childOwners == null || !lex.isCode(abs)) continue;
        if (childName.startsWith('_') && !childOwners.contains(file)) continue;
        found[abs] ??= '$file:${_line(abs)}  $childName(...) внутри const '
            '${name ?? 'коллекции'}';
      }
    }
    for (final position in found.keys.toList()..sort()) {
      _report(constWidgets, found[position]!);
    }
  }

  void _display() {
    for (final token in lex.tokens) {
      if (wrapped.contains(token.start)) continue;
      if (!_hasCyrillic(_ownText(token))) continue;
      final text = _runtime(token);
      var lineStart = src.lastIndexOf('\n', token.start - 1) + 1;
      if (lineStart > token.start) lineStart = 0;
      final head = src.substring(lineStart, token.start);
      if (!_displayHeadRe.hasMatch(head)) continue;
      if (_displayHold.contains(text)) continue;
      _report(display, '$file:${_line(token.start)}  «$text»');
    }
  }

  /// Дыры вне витрины: `_displayHeadRe` смотрит только на заголовок строки, а
  /// строка на экран попадает и из `??`-фолбэка, из ветки тернарника, из
  /// `return`/`=>`, из склейки `'а' + 'б'`, из словаря подстановок `trf` и из
  /// аргумента витринной функции (`_showSuccess('Сохранено')`).
  void _positions() {
    for (final token in lex.tokens) {
      if (wrapped.contains(token.start)) continue;
      if (!_hasCyrillic(_ownText(token))) continue;
      final text = _runtime(token);
      var lineStart = src.lastIndexOf('\n', token.start - 1) + 1;
      if (lineStart > token.start) lineStart = 0;
      // Витрину уже посчитал `_display()` — дважды не считаем.
      if (_displayHeadRe.hasMatch(src.substring(lineStart, token.start))) {
        continue;
      }
      final kind = _positionKind(token);
      if (kind == null) continue;
      if (_dataHold.contains('${_basename(file)}|$text')) continue;
      _report(holes, '$file:${_line(token.start)}  $kind  «$text»');
    }
  }

  /// Класс позиции или `null`: ключ разбора, имя файла, довод логгера — это
  /// данные, их переводить нельзя, `tr()` сломал бы сравнение.
  String? _positionKind(_Str token) {
    // Сравнение — данные, его не спасает и витрина, и тело build().
    if (_isCompare(token)) return null;
    final kind = _explicitKind(token);
    if (kind != null) return kind;
    // Класс позиции молчит, но литерал живёт внутри `build(...)`: наружу он
    // всё равно уходит текстом на экране.
    return _inBuild(token.start) ? 'тело build()' : null;
  }

  String? _explicitKind(_Str token) {
    final before = lex.prevNonSpace(token.start - 1);
    if (before != null) {
      final c = src[before];
      if (c == '?') {
        final prev = lex.prevNonSpace(before - 1);
        if (prev != null && src[prev] == '?') return 'фолбэк ??';
        return 'ветка тернарника';
      }
      if (c == ':') {
        final keyEnd = lex.prevNonSpace(before - 1);
        if (keyEnd == null) return null;
        final key = lex.byEnd[keyEnd];
        // `label: 'текст'` — именованный аргумент, его видно `_display()`.
        if (key == null) return null;
        final sep = lex.prevNonSpace(key.start - 1);
        final isMapEntry = sep != null && '{,;'.contains(src[sep]);
        if (!isMapEntry) return 'ветка тернарника';
        // Значение map'а переводится только внутри `trf`: там оно уходит в
        // подстановку `{ключ}`. В остальном это данные.
        return _inTrfMap(token.start) ? 'подстановка trf' : null;
      }
      if (c == '(') {
        // `before` — сама скобка: `calleeAt` смотрит на символ перед точкой,
        // поэтому передаём индекс скобки, иначе имя вызова не прочитать.
        final callee = lex.calleeAt(before);
        if (callee != null && _displaySinks.contains(callee)) {
          return 'аргумент $callee(';
        }
        return null;
      }
      if (c == ',') {
        // Не только первый аргумент: `emit(0.48, 'Анализ скриптов')` уходит
        // в прогресс-бар, и это та же дыра, что `emit('Анализ скриптов')`.
        final open = _openParenBeforeComma(before);
        if (open == null) return null;
        final callee = lex.calleeAt(open);
        if (callee != null && _displaySinks.contains(callee)) {
          return 'аргумент $callee(';
        }
        return null;
      }
      if (c == '>') {
        final eq = lex.prevNonSpace(before - 1);
        return (eq != null && src[eq] == '=') ? 'ветка =>' : null;
      }
      if (c == '+') {
        final left = lex.prevNonSpace(before - 1);
        // `'текст' + 'ещё'` считает левая половина, ниже по `+` справа.
        return (left != null && lex.byEnd[left] == null) ? 'склейка +' : null;
      }
      if (c == '"' || c == "'") {
        return lex.byEnd[before] != null ? 'склейка литералов' : null;
      }
      if (_isIdent(c)) return _wordBefore(before) == 'return' ? 'возврат' : null;
      return null;
    }
    final after = lex.nextNonSpace(token.end);
    if (after != null && src[after] == '+') return 'склейка +';
    return null;
  }

  /// `'текст' == x`, `x != 'текст'`: здесь строка участвует в проверке, а не
  /// на экране. `tr()` её не найдёт в словаре и сломает сравнение.
  bool _isCompare(_Str token) {
    final before = lex.prevNonSpace(token.start - 1);
    if (before != null) {
      final c = src[before];
      if (c == '!') {
        final next = lex.nextNonSpace(before + 1);
        if (next != null && src[next] == '=') return true;
      } else if (c == '=') {
        final prev = lex.prevNonSpace(before - 1);
        if (prev != null && (src[prev] == '=' || src[prev] == '!')) return true;
      }
    }
    final after = lex.nextNonSpace(token.end);
    if (after != null && src[after] == '=') {
      final next = lex.nextNonSpace(after + 1);
      if (next != null && src[next] == '=') return true;
    }
    return false;
  }

  final List<_Range> _builds = [];

  /// Тела `build(...)`. Литерал в середине дерева (`if`-ветка списка,
  /// элемент `children`, `.join()`) не попадает ни в один явный класс
  /// позиции, но рисуется на экран.
  void _buildBodies() {
    for (final match in _buildRe.allMatches(src)) {
      if (!lex.isCode(match.start)) continue;
      final params = _span(match.end - 1, '(', ')');
      if (params == null) continue;
      final brace = lex.nextNonSpace(params.end);
      if (brace == null || src[brace] != _openBrace) continue;
      final body = _span(brace, _openBrace, _closeBrace);
      if (body != null) _builds.add(body);
    }
  }

  bool _inBuild(int at) =>
      _builds.any((range) => at >= range.start && at < range.end);

  /// Идентификатор, кончающийся в `at`.
  String _wordBefore(int at) {
    var start = at;
    while (start > 0 && _isIdent(src[start - 1])) start--;
    return src.substring(start, at + 1);
  }

  /// Открывающая скобка вызова, аргументом которого является запятая в
  /// `commaAt`: идём назад с балансом скобок. Строки и комментарии лексер
  /// уже пометил как не-код, а `;`, `{`, `}` и `]` означают, что мы вылезли
  /// за пределы аргументов.
  int? _openParenBeforeComma(int commaAt) {
    var depth = 0;
    for (var i = commaAt - 1; i >= 0; i--) {
      if (!lex.isCode(i)) continue;
      final c = src[i];
      if (c == ')') {
        depth++;
      } else if (c == '(') {
        if (depth == 0) return i;
        depth--;
      } else if (c == ';' || c == '{' || c == '}' || c == ']') {
        return null;
      }
    }
    return null;
  }

  bool _inTrfMap(int pos) =>
      _trfMaps.any((map) => map.start <= pos && pos < map.end);

  /// Границы инициализатора объявления: сбалансированная коллекция до
  /// закрывающей скобки, иначе — скаляр до `;`.
  _Range? _initializer(int declStart) {
    final eq = src.indexOf('=', declStart);
    if (eq < 0) return null;
    var i = eq + 1;
    while (i < src.length && _isSpace(src[i])) { i++; }
    if (i >= src.length) return null;
    if (!_openers.contains(src[i])) {
      var j = i;
      while (j < src.length && src[j] != ';' && src[j] != '\n') { j++; }
      return _Range(i, j);
    }
    var depth = 0;
    var cursor = 0;
    var j = i;
    while (j < src.length) {
      final region = cursor < lex.regions.length ? lex.regions[cursor] : null;
      if (region != null && j >= region.start && j < region.end) {
        j = region.end;
        cursor++;
        continue;
      }
      if (region != null && j >= region.end) cursor++;
      final c = src[j];
      if (_openers.contains(c)) {
        depth++;
      } else if (_closers.contains(c)) {
        depth--;
        if (depth == 0) return _Range(i, j + 1);
      }
      j++;
    }
    return null;
  }

  bool _looksLikeCode(int at) {
    var i = at;
    while (i < src.length && _isSpace(src[i])) { i++; }
    return i < src.length && _isIdentStart(src[i]) && !src.startsWith('tr', i);
  }

  int _line(int pos) => lex.lineOf(pos);
}

/// Литерал -> рантайм-строка: экранированные переводы строк становятся
/// настоящими, `$name` — `{name}` (ключ с интерполяцией всё равно нарушение,
/// но сравнение покрытия должно видеть то, что ищет словарь).
String _runtime(_Str token) {
  if (token.raw) return token.body;
  final body = token.body;
  final out = StringBuffer();
  var i = 0;
  while (i < body.length) {
    final c = body[i];
    if (c == _backslash && i + 1 < body.length) {
      final next = body[i + 1];
      out.write(_escapes[next] ?? next);
      i += 2;
      continue;
    }
    if (c == r'$') {
      final next = i + 1 < body.length ? body[i + 1] : '';
      if (next == '{') {
        final close = _braceIn(body, i + 1);
        out.write(body.substring(i, close + 1));
        i = close + 1;
        continue;
      }
      if (_isIdentStart(next)) {
        var k = i + 1;
        while (k < body.length && _isIdent(body[k])) { k++; }
        out.write('{${body.substring(i + 1, k)}}');
        i = k;
        continue;
      }
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// Собственный текст литерала — без вставок `$x` и `${...}`. Их содержимое
/// сканер видит отдельными вызовами: в `'{n} ${trp([‘день’…], n)}'` русские
/// формы уже завёрнуты в `trp()`, и считать всю строку дырой — ложняк.
String _ownText(_Str token) {
  if (token.raw) return token.body;
  final body = token.body;
  final out = StringBuffer();
  var i = 0;
  while (i < body.length) {
    final c = body[i];
    if (c == _backslash && i + 1 < body.length) {
      i += 2;
      continue;
    }
    if (c == r'$') {
      final next = i + 1 < body.length ? body[i + 1] : '';
      if (next == _openBrace) {
        i = _braceIn(body, i + 1) + 1;
        continue;
      }
      if (_isIdentStart(next)) {
        var k = i + 1;
        while (k < body.length && _isIdent(body[k])) { k++; }
        i = k;
        continue;
      }
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

int _braceIn(String text, int open) {
  var depth = 0;
  for (var j = open; j < text.length; j++) {
    final c = text[j];
    if (_openers.contains(c)) {
      depth++;
    } else if (_closers.contains(c)) {
      depth--;
      if (depth == 0) return j;
    } else if (c == _backslash) {
      j++;
    }
  }
  return text.length - 1;
}

const Map<String, String> _escapes = {
  'n': '\n',
  't': '\t',
  'r': '\r',
  'a': '\u0007',
  'b': '\b',
  'f': '\f',
  'v': '\u000B',
  '0': '\u0000',
  'e': '\u001B',
  _backslash: _backslash,
  "'": "'",
  '"': '"',
  r'$': r'$',
  '`': '`',
};

bool _isSpace(String c) => c == ' ' || c == '\n' || c == '\t' || c == '\r';

bool _hasCyrillic(String text) {
  for (final unit in text.codeUnits) {
    if (unit >= 0x0400 && unit <= 0x04FF) return true;
  }
  return false;
}
