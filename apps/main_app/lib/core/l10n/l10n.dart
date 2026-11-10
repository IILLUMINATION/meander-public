import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show VoidCallback;

import 'app_language.dart';
import 'app_languages.dart';

/// Переключение языка интерфейса.
///
/// Ключ строки — её русский оригинал (русский язык-источник), поэтому
/// `tr('Сохранить')` без перевода вернёт «Сохранить»: интерфейс остаётся
/// целиком рабочим, пока словарь языка наполняется. Новый язык — это файл
/// словаря + одна строка в `app_languages.dart`, либо импортированный
/// пользователем пакет (`register`/`unregister` ниже).
///
/// Живые языки реестра (`de`, `pt-BR`, …) добирают промахи у английского:
/// `fallbackCode`. Недопереведённая строка показывается по-английски, а не
/// кириллицей, — иначе перевод был бы формальным: в списке квестов человек
/// видел бы русский среди немецкого интерфейса.
class L10n {
  L10n._();

  static final Map<String, AppLanguage> _byCode = {
    for (final language in supportedLanguages) language.code: language,
  };

  /// Языки, импортированные пользователем, в порядке регистрации. Вшитые
  /// языки в этот список не попадают: их реестр — `app_languages.dart`.
  static final List<AppLanguage> _custom = [];

  /// Русский — язык-источник: он не нуждается в словаре.
  static final AppLanguage _source = _byCode[kSourceLanguageCode]!;
  static AppLanguage _current = _source;

  static final List<VoidCallback> _listeners = [];

  static AppLanguage get current => _current;
  static String get code => _current.code;

  /// Русский оригинал текущей строки — для подписей вроде «English /
  /// Английский» и для тестов.
  static String source(String ru) => ru;

  static List<AppLanguage> get supported => [
    ...supportedLanguages,
    ..._custom,
  ];

  static bool isCustom(String code) =>
      _custom.any((language) => language.code == code);

  /// Неизвестный код -> русский: приложение не должно стартовать с пустым
  /// словарём из-за опечатки в настройках.
  static AppLanguage byCode(String code) => _byCode[code] ?? _source;

  /// Регионы, где китайский пишут традиционными иероглифами: подставлять им
  /// упрощённый нельзя — это другой набор знаков, а не «почти то же».
  static const Set<String> _traditionalChineseRegions = {'TW', 'HK', 'MO'};

  /// Язык системы -> язык реестра там, где кодов у одного языка несколько.
  /// Португальский у нас один — бразильский, поэтому `pt-PT` тоже он.
  static const Map<String, String> _systemLanguageAliases = {'pt': 'pt-BR'};

  /// Язык интерфейса для системной локали. `null` — система говорит на языке,
  /// которого в реестре нет: что показать вместо него, решает вызывающий.
  static AppLanguage? forSystemLocale(Locale locale) {
    final language = locale.languageCode.toLowerCase();
    if (language == 'zh') {
      final traditional =
          locale.scriptCode?.toLowerCase() == 'hant' ||
          _traditionalChineseRegions.contains(locale.countryCode?.toUpperCase());
      return traditional ? null : _byCode['zh-CN'];
    }
    return _byCode[_systemLanguageAliases[language] ?? language];
  }

  /// Первая поддерживаемая локаль из системного списка: `PlatformDispatcher
  /// .locales` идёт в порядке предпочтения пользователя, поэтому второй язык
  /// системы выигрывает у английского по умолчанию.
  static AppLanguage? forSystemLocales(Iterable<Locale> locales) {
    for (final locale in locales) {
      final match = forSystemLocale(locale);
      if (match != null) return match;
    }
    return null;
  }

  static void addListener(VoidCallback listener) => _listeners.add(listener);

  static void removeListener(VoidCallback listener) => _listeners.remove(
    listener,
  );

  /// Меняет язык и извещает подписчиков. Интерфейс перерисовывается сам:
  /// `_AppState.build` слушает провайдер языка и пересобирает `MaterialApp`,
  /// извещение здесь нужно подпискам вне этого каскада (`LanguageRebuild`).
  /// Совпадение кода — ничего не делаем: смена языка сбрасывает прокрутку и
  /// локальное состояние экранов.
  static void setCurrent(AppLanguage language) {
    if (language.code == _current.code) return;
    _current = language;
    _notify();
  }

  static void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  /// Добавить (или обновить) импортированный язык. Вшитый язык подменить
  /// нельзя: его словарь лежит в репозитории и пересобирается вместе с
  /// приложением, а правка из настроек создала бы два «английских».
  ///
  /// Повторный импорт текущего языка — это замена словаря на месте: если он
  /// и выбран, экраны обязаны перерисоваться, иначе пользователь видит
  /// старые строки языка, который он только что поправил.
  static void register(AppLanguage language) {
    if (!language.custom) {
      throw ArgumentError.value(
        language.code,
        'language',
        'импортировать можно только пользовательский язык',
      );
    }
    if (supportedLanguages.any((item) => item.code == language.code)) return;
    final isCurrent = language.code == _current.code;
    _byCode[language.code] = language;
    final index = _custom.indexWhere((item) => item.code == language.code);
    if (index >= 0) {
      _custom[index] = language;
    } else {
      _custom.add(language);
    }
    if (isCurrent) {
      _current = language;
      _notify();
    }
  }

  /// Убрать импортированный язык; возвращает `false`, если такого языка нет
  /// или он вшитый. С выбранным языком остаётся русский: строки-то русские,
  /// а словаря больше нет.
  static bool unregister(String code) {
    final index = _custom.indexWhere((language) => language.code == code);
    if (index < 0) return false;
    _custom.removeAt(index);
    _byCode.remove(code);
    if (_current.code == code) {
      _current = _source;
      _notify();
    }
    return true;
  }

  /// Строка на текущем языке: свой словарь, затем `fallbackCode`, затем русский.
  static String tr(String ru) => _lookup(ru) ?? ru;

  /// Цепочка «язык -> fallback» без циклов: пользовательский пакет вправе
  /// указать `fallbackCode` на себя, а `register` допускает перезапись языка.
  /// Пустое значение словаря — промах: недопереведённая запись template-файла
  /// не должна побеждать английский.
  static Iterable<AppLanguage> get _chain sync* {
    final visited = <String>{};
    AppLanguage? step = _current;
    while (step != null && visited.add(step.code)) {
      yield step;
      step = step.fallbackCode == null ? null : _byCode[step.fallbackCode];
    }
  }

  static String? _lookup(String ru) {
    for (final language in _chain) {
      final value = language.dictionary[ru];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static List<String>? _lookupPlurals(String lemma) {
    for (final language in _chain) {
      final forms = language.plurals[lemma];
      if (forms != null && forms.isNotEmpty) return forms;
    }
    return null;
  }

  /// Русская строка с подстановками `{key}` на текущем языке.
  static String trf(String ru, Map<String, Object?> args) => fill(tr(ru), args);

  /// Формы множественного числа. `ruForms` — русские `[одна, мало, много]`
  /// (порядок `slavicPlural`), ключ словаря — первая форма. Язык выбирает
  /// форму по своему правилу; без словарной записи и в языке-источнике
  /// остаётся русская.
  ///
  /// Взятые из fallback формы считаются правилом текущего языка: их длина
  /// своя, поэтому индекс зажимается до последней формы — «много» вместо
  /// промаха за край.
  ///
  /// `count` подставляется в шаблон сам, как аргумент `n`.
  static String trp(
    List<String> ruForms,
    int count, {
    Map<String, Object?>? args,
  }) {
    final forms = _lookupPlurals(ruForms.first);
    final values = <String, Object?>{'n': count, ...?args};
    if (forms == null) {
      return fill(ruForms[_clampIndex(slavicPlural(count), ruForms.length)],
          values);
    }
    return fill(forms[_clampIndex(_current.pluralOf(count), forms.length)],
        values);
  }

  static int _clampIndex(int index, int length) =>
      index < length ? index : length - 1;

  /// Все формы текущего языка, в порядке его `pluralOf`. Нужен свёрнутым
  /// числам («1.2k просмотров»), где форма всегда последняя, а счётчик к
  /// слову не применяется.
  static List<String> pluralForms(List<String> ruForms) =>
      _lookupPlurals(ruForms.first) ?? ruForms;

  /// Подставляет `{key}`; чужие плейсхолдеры остаются как есть, чтобы
  /// опечатка в словаре была видна, а не проглатывалась.
  static String fill(String template, Map<String, Object?> args) {
    if (!template.contains('{')) return template;
    final out = StringBuffer();
    var cursor = 0;
    for (final match in _placeholder.allMatches(template)) {
      final value = args[match.group(1)];
      if (value == null) continue;
      out
        ..write(template.substring(cursor, match.start))
        ..write(value);
      cursor = match.end;
    }
    out.write(template.substring(cursor));
    return out.toString();
  }

  static final RegExp _placeholder = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');
}

/// Русская строка на текущем языке интерфейса.
String tr(String ru) => L10n.tr(ru);

/// Русская строка с подстановками `{key}` на текущем языке.
String trf(String ru, Map<String, Object?> args) => L10n.trf(ru, args);

/// Множественное число: `[одна, мало, много]` по-русски + количество.
String trp(List<String> ruForms, int count, {Map<String, Object?>? args}) =>
    L10n.trp(ruForms, count, args: args);

/// Последняя (множественная) форма текущего языка — для «1.2k просмотров».
String trpMany(List<String> ruForms) => L10n.pluralForms(ruForms).last;
