import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Одна версия инструментов на все сборки, проверки и документацию.
///
/// Зачем: iOS нельзя собрать на Linux, поэтому расхождение видно только на
/// Маке или уже в TestFlight. Реальный случай: в `build_*.yml` стоял
/// `FLUTTER_VERSION: 3.47.x`, а в `ci-ios.yml` — `channel: stable`. Один и тот
/// же коммит собирался разными движками, Swift-код (`FlutterSceneDelegate`,
/// `FlutterImplicitEngineDelegate`) и плагин-регистранты расходились, сборка
/// проходила, а приложение падало на устройстве. Тест читает файлы как текст:
/// YAML-парсера в зависимостях нет, а проверяется ровно то, что уйдёт в CI.
void main() {
  // apps/main_app → apps → корень репозитория.
  final workflowsDir = Directory('../../.github/workflows');
  if (!Directory('ios').existsSync() || !workflowsDir.existsSync()) {
    throw StateError('Запустите тест из apps/main_app: flutter test test/ios');
  }

  final workflows = workflowsDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  String nameOf(File f) => f.uri.pathSegments.last;

  Map<File, String> texts = {
    for (final f in workflows) f: f.readAsStringSync(),
  };

  /// Версия из `env: FLUTTER_VERSION: "x"` внутри workflow.
  Set<String> envVersions(String text) => RegExp(
    r'^\s*FLUTTER_VERSION:\s*"?([0-9][^"\s]*)"?\s*$',
    multiLine: true,
  ).allMatches(text).map((m) => m.group(1)!).toSet();

  /// Значения всех `flutter-version:` — и `${{ env.… }}`, и литералы.
  List<String> actionVersions(String text) => RegExp(
    r'^\s*flutter-version:\s*(.+?)\s*$',
    multiLine: true,
  ).allMatches(text).map((m) => m.group(1)!.trim()).toList();

  final pins = <String, Set<String>>{
    for (final entry in texts.entries)
      if (envVersions(entry.value).isNotEmpty)
        nameOf(entry.key): envVersions(entry.value),
  };

  test('хотя бы один workflow пинит версию Flutter', () {
    expect(pins, isNotEmpty);
  });

  test('все workflow объявляют одну и ту же версию Flutter', () {
    final all = pins.values.expand((v) => v).toSet();
    expect(
      all,
      hasLength(1),
      reason: 'сборки и проверки расходятся по движку: $pins',
    );
  });

  test('каждая установка flutter-action задаёт версию', () {
    final offenders = <String>[];
    for (final entry in texts.entries) {
      final lines = entry.value.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('uses: subosito/flutter-action')) continue;
        // `with:` идёт сразу за `uses:`, до следующего шага — не дальше.
        final window = lines.skip(i + 1).take(6).join('\n');
        final stepEnd = window.indexOf('- name:');
        final scoped = stepEnd == -1 ? window : window.substring(0, stepEnd);
        if (!scoped.contains('flutter-version:')) {
          offenders.add('${nameOf(entry.key)}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'без пина движок меняется молча');
  });

  test('литералы версии не расходятся с env', () {
    final expected = pins.values.expand((v) => v).toSet().single;
    final offenders = <String>[];
    for (final entry in texts.entries) {
      for (final value in actionVersions(entry.value)) {
        if (value.startsWith(r'${{')) continue; // ссылка на env — проверена выше
        final literal = value.replaceAll('"', '').replaceAll("'", '');
        if (literal != expected) {
          offenders.add('${nameOf(entry.key)}: $value (ожидалось $expected)');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('melos ставится точной версией из документации', () {
    final doc = File('../../docs/ios-release.md').readAsStringSync();
    final documented = RegExp(
      r'melos \*\*([0-9][0-9.]*)\*\*',
    ).firstMatch(doc)!.group(1)!;
    final offenders = <String>[];
    for (final entry in texts.entries) {
      for (final line in entry.value.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('run: dart pub global activate melos')) continue;
        if (!trimmed.endsWith(' $documented') &&
            !trimmed.endsWith("'$documented'")) {
          offenders.add('${nameOf(entry.key)}: $trimmed');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'melos 7/8 не читают melos.yaml, а 6.x-мелочи меняют workspace',
    );
  });

  test('документация релиза называет ту же версию Flutter, что CI', () {
    final doc = File('../../docs/ios-release.md');
    expect(doc.existsSync(), isTrue, reason: 'docs/ios-release.md пропал');
    final text = doc.readAsStringSync();
    final mentioned = RegExp(
      r'Flutter \*\*([0-9][0-9.]*)\*\*',
    ).allMatches(text).map((m) => m.group(1)!).toSet();
    expect(mentioned, hasLength(1), reason: 'в доке несколько версий: $mentioned');
    expect(
      mentioned.single,
      pins.values.expand((v) => v).toSet().single,
      reason: 'собирающий по доке возьмёт не тот движок, что проверяет CI',
    );
  });

  test('в доке клон и проверка — на той же версии', () {
    final text = File('../../docs/ios-release.md').readAsStringSync();
    final recommended = RegExp(
      r'Flutter \*\*([0-9][0-9.]*)\*\*',
    ).firstMatch(text)!.group(1)!;
    expect(
      text,
      contains('git clone -b $recommended'),
      reason: 'в доке должен быть клон движка той же версии',
    );
    expect(
      RegExp(r'flutter-[0-9.]+').allMatches(text).map((m) => m.group(0)!).toSet(),
      {'flutter-$recommended'},
      reason: 'пути клона/проверки в доке расходятся с рекомендованной версией',
    );
  });

  test('номер сборки для загрузки задаётся флагом, а не правкой pubspec', () {
    // Маркетинговая версия одна на все платформы и привязана к тегу. Повторная
    // загрузка в App Store Connect требует нового CFBundleVersion — это флаг
    // `--build-number`, а не новая строка `version:` в pubspec.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^version:\s*\S+$', multiLine: true).hasMatch(pubspec),
      isTrue,
      reason: 'версия должна остаться одной строкой в pubspec',
    );
    final doc = File('../../docs/ios-release.md').readAsStringSync();
    expect(
      doc,
      contains('--build-number'),
      reason: 'иначе перезагрузку в TestFlight делать нечем',
    );
    expect(
      doc,
      contains('version:'),
      reason: 'дока обязана ссылаться на версию из pubspec',
    );
  });

  group('Dart/Flutter CI', () {
    final dart = File('../../.github/workflows/ci-dart.yml').readAsStringSync();
    final melos = File('../../melos.yaml').readAsStringSync();

    test('анализирует Flutter-пакеты, а не пустой Dart-фильтр', () {
      expect(dart, contains('run: melos run analyze:flutter'));
      expect(dart, isNot(contains('run: melos run analyze\n')));
      expect(dart, isNot(contains('run: melos run test\n')));
      expect(
        melos,
        contains(
          'flutter analyze --no-fatal-infos --no-fatal-warnings .',
        ),
      );
    });

    test('перед тестами собирает и подключает нативное ядро', () {
      expect(dart, contains('./scripts/setup_ffi_link.sh'));
      expect(dart, contains('cargo build --locked --release -p mnd-ffi'));
      expect(
        dart,
        contains(
          r'MND_FFI_SO: ${{ github.workspace }}/target/release/libmnd_ffi.so',
        ),
      );
      expect(
        dart,
        contains(r'LD_LIBRARY_PATH: ${{ github.workspace }}/target/release'),
      );
    });

    test('Rust-изменения запускают Dart/Flutter проверки', () {
      final trigger = dart.substring(0, dart.indexOf('concurrency:'));
      expect(trigger, contains("'crates/**'"));
      expect(trigger, contains("'Cargo.lock'"));
      expect(trigger, contains("'scripts/setup_ffi_link.sh'"));
    });

    test('тесты внутри пакета идут параллельно', () {
      expect(melos, contains('flutter test --concurrency=8'));
    });
  });

  group('Политика iOS-сборок', () {
    final ios = File('../../.github/workflows/ci-ios.yml').readAsStringSync();

    test('на PR собирается debug-симулятор без device-архива', () {
      expect(
        ios,
        contains('flutter build ios --debug --simulator --no-codesign'),
      );
      expect(ios, isNot(contains('flutter build ios --release --simulator')));

      final at = ios.indexOf(
        r'if [ "${{ github.event_name }}" = "pull_request" ]; then',
      );
      expect(at, greaterThan(0), reason: 'PR-выбор среза пропал');
      final branch = ios.substring(at, ios.indexOf('elif', at));
      expect(branch, contains('"name":"simulator"'));
      expect(branch, isNot(contains('"name":"device"')));
    });

    test('matrix берёт только выбранные config-джобом срезы', () {
      expect(ios, contains('outputs:'));
      expect(ios, contains(r'slices: ${{ steps.slices.outputs.value }}'));
      expect(
        ios,
        contains(r'slice: ${{ fromJSON(needs.config.outputs.slices) }}'),
      );
    });

    test('device release проверяется на main, тегах и ручном запуске', () {
      expect(ios, contains('flutter build ipa --release --no-codesign'));
      expect(ios, contains('frb_get_rust_content_hash'));
      expect(ios, contains('push:'));
      expect(ios, contains('branches:'));
      expect(ios, contains('- main'));
      expect(ios, contains('tags:'));
      expect(ios, contains("- 'v*'"));
      expect(ios, contains('workflow_dispatch:'));
    });

    test('предсобранное ядро не пересобирается Xcode-фазой', () {
      expect(ios, contains('.built-triple'));
      expect(ios, contains(r"printf '%s' '${{ matrix.slice.rust_target }}'"));
    });

    test('архив ядра проверяется на символы FRB и Lua', () {
      expect(ios, contains('grep -q frb_'));
      expect(ios, contains('grep -q luaL_newstate'));
    });
  });
}
