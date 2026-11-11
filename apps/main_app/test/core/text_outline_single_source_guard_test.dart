// Гард на «единый центр» для обводки текста и ширины колонки контента.
//
// Правило, которое проверяем: решение о внешнем виде принимает ядро
// (`packages/mnd_core`), а клиенты — плеер, редактор, web-плеер и экспорт —
// только рисуют то, что решило ядро. Обводка исторически была исключением:
// четыре поверхности считали толщину и геометрию контура каждая по-своему, и
// автор видел разный контур в редакторе, игре и на выложенной странице.
//
// Сканер статический, по исходникам: ему не нужен ни запущенный рендер, ни
// скриншоты, и он ловит именно возврат копий, а не их последствия.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Корень репозитория относительно `apps/main_app` (оттуда идёт `flutter test`).
Directory get _repoRoot {
  var dir = Directory.current;
  while (dir.path != dir.parent.path) {
    if (Directory('${dir.path}/packages/mnd_core').existsSync() &&
        Directory('${dir.path}/apps/main_app').existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  fail('не найден корень репозитория от ${Directory.current.path}');
}

final String _outlineModule = 'packages/mnd_core/lib/models/text_outline.dart';

Map<String, String> _sources() {
  final root = _repoRoot;
  final result = <String, String>{};
  for (final relative in [
    'packages/mnd_core/lib',
    'packages/mnd_player/lib',
    'apps/main_app/lib',
    'apps/web_player/lib',
  ]) {
    final dir = Directory('${root.path}/$relative');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.substring(root.path.length + 1);
      result[path] = entity.readAsStringSync();
    }
  }
  return result;
}

/// Все нарушения правила в наборе исходников. Вынесено отдельно, чтобы тест
/// мог проверить сам сканер на синтетических файлах.
List<String> findViolations(Map<String, String> sources) {
  final violations = <String>[];
  final widthDeclaration = RegExp(
    r'const\s+double\s+kTextOutlineWidth(?:Default|Min|Max)\b',
  );
  // Кольцо из восьми копий глифа, которое раньше считала каждая поверхность.
  final legacyRing = RegExp(r'Offset\(\s*-?0\.7\s*,\s*-?0\.7\s*\)');
  final legacyName = RegExp(r'\boutlineShadows\b');
  // Ширина колонки контента: 720 px в четырёх местах — ровно тот же класс
  // расхождения, что и с обводкой.
  final columnCapHardcode = RegExp(
    r'(?:columnCap|_columnCap|columnWidthCap)\s*=\s*720(?:\.0)?\b',
  );

  sources.forEach((path, source) {
    if (path != _outlineModule) {
      if (widthDeclaration.hasMatch(source)) {
        violations.add('$path: своя константа толщины обводки');
      }
      if (legacyRing.hasMatch(source)) {
        violations.add('$path: своё кольцо теней обводки');
      }
      if (legacyName.hasMatch(source)) {
        violations.add('$path: свой рендер обводки тенями');
      }
      if (columnCapHardcode.hasMatch(source)) {
        violations.add('$path: своя ширина колонки контента вместо ядра');
      }
    }
  });
  return violations;
}

void main() {
  test('клиенты не решают внешний вид обводки и ширину колонки сами', () {
    final violations = findViolations(_sources());
    expect(
      violations,
      isEmpty,
      reason:
          'решение должно жить в $_outlineModule и mnd_core:\n'
          '${violations.join('\n')}',
    );
  });

  group('негативные контроли сканера', () {
    test('своя константа толщины находится', () {
      expect(
        findViolations({
          'apps/main_app/lib/x.dart': 'const double kTextOutlineWidthMax = 9;',
        }),
        hasLength(1),
      );
    });

    test('своё кольцо теней находится', () {
      expect(
        findViolations({
          'apps/web_player/lib/x.dart':
              'Shadow(color: c, offset: Offset(-0.7, -0.7))',
        }),
        hasLength(1),
      );
    });

    test('своя ширина колонки находится', () {
      expect(
        findViolations({
          'packages/mnd_player/lib/x.dart': 'const columnCap = 720.0;',
        }),
        hasLength(1),
      );
    });

    test('ядро — не нарушение: там решение и живёт', () {
      expect(
        findViolations({
          _outlineModule: 'const double kTextOutlineWidthMax = 12;',
        }),
        isEmpty,
      );
    });
  });
}
