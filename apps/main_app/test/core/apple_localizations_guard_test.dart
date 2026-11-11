// Гард на список языков для App Store.
//
// Правило: единственный источник поддерживаемых языков — `supportedLanguages`
// в lib/core/l10n/app_languages.dart. У Apple нет .lproj-файлов (строки лежат
// в Dart-словарях), поэтому блок «Языки» в карточке магазина наполняется из
// `CFBundleLocalizations` в Info.plist. Списки расходятся молча: новый язык со
// словарём появляется в приложении, но магазин о нём не узнаёт — и обе
// карточки (iOS и macOS) висят с прошлогодним набором. Тест сшивает два
// списка и падает на любом расхождении в обе стороны.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory get _appRoot {
  var dir = Directory.current;
  while (dir.path != dir.parent.path) {
    if (Directory('${dir.path}/lib/core/l10n').existsSync()) return dir;
    dir = dir.parent;
  }
  fail('не найден корень apps/main_app от ${Directory.current.path}');
}

/// Код языка приложения → код, которым Apple называет ту же локализацию.
/// Совпадают почти всегда; исключения — варианты, где Apple использует
/// скрипт (`zh-Hans`), а не страну.
String appleCodeFor(String appCode) {
  switch (appCode) {
    case 'zh-CN':
      return 'zh-Hans';
    default:
      return appCode;
  }
}

Set<String> _codesFromLanguagesSource(String source) {
  final codes = RegExp(
    r"code:\s*'([^']+)'",
  ).allMatches(source).map((m) => m.group(1)!).toSet();
  final sourceCode = RegExp(
    r"kSourceLanguageCode\s*=\s*'([^']+)'",
  ).firstMatch(source);
  if (sourceCode != null) codes.add(sourceCode.group(1)!);
  return codes;
}

Set<String> _plistLocalizations(String plist) {
  final block = RegExp(
    r'<key>CFBundleLocalizations</key>\s*<array>(.*?)</array>',
    dotAll: true,
  ).firstMatch(plist);
  if (block == null) return const {};
  return RegExp(
    r'<string>([^<]+)</string>',
  ).allMatches(block.group(1)!).map((m) => m.group(1)!.trim()).toSet();
}

void main() {
  final appRoot = _appRoot;
  final languagesSource = File(
    '${appRoot.path}/lib/core/l10n/app_languages.dart',
  ).readAsStringSync();
  final languageCodeSource = File(
    '${appRoot.path}/lib/core/l10n/app_language.dart',
  ).readAsStringSync();

  final supported = _codesFromLanguagesSource(
    '$languagesSource\n$languageCodeSource',
  );
  final expected = supported.map(appleCodeFor).toSet();

  test('в приложении больше одного языка (иначе список не нужен)', () {
    expect(supported.length, greaterThan(1));
  });

  for (final plistPath in [
    'ios/Runner/Info.plist',
    'macos/Runner/Info.plist',
  ]) {
    test(
      'CFBundleLocalizations в $plistPath совпадает с supportedLanguages',
      () {
        final file = File('${appRoot.path}/$plistPath');
        expect(file.existsSync(), isTrue, reason: 'нет $plistPath');
        final declared = _plistLocalizations(file.readAsStringSync());

        expect(
          declared.difference(expected),
          isEmpty,
          reason:
              'в $plistPath есть языки, которых нет в supportedLanguages '
              '(магазин покажет неподдерживаемый язык)',
        );
        expect(
          expected.difference(declared),
          isEmpty,
          reason:
              'в $plistPath не хватает языков из supportedLanguages '
              '(магазин их не покажет): ${expected.difference(declared)}',
        );
      },
    );
  }
}
