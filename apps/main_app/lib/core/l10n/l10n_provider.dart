import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_language.dart';
import 'l10n.dart';

/// Язык интерфейса: выбор хранится в prefs и зеркалируется в `L10n`, чтобы
/// `tr()` работал и вне виджетов — в сервисах, моделях блоков, генераторах
/// текста.
class AppLanguageNotifier extends StateNotifier<AppLanguage> {
  static const String prefsKey = 'ui_language';

  AppLanguageNotifier() : super(L10n.current) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(prefsKey);
    if (code != null) await select(code);
  }

  /// Порядок важен: `L10n` обязан сменить язык до перерисовки виджетов,
  /// иначе часть экрана успеет отрисовать строки старого языка.
  Future<void> select(String code) async {
    final language = L10n.byCode(code);
    if (language.code == state.code) return;
    L10n.setCurrent(language);
    state = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, language.code);
  }
}

final appLanguageProvider =
    StateNotifierProvider<AppLanguageNotifier, AppLanguage>((ref) {
      return AppLanguageNotifier();
    });

/// Читает язык до первого кадра, чтобы сплэш уже рисовался на выбранном
/// языке. `AppLanguageNotifier` после этого находит тот же код и молчит.
///
/// Порядок: выбор пользователя -> язык системы -> английский. Системный язык
/// не сохраняется: пока человек не выбрал язык руками, приложение идёт за
/// системой, и после смены языка ОС он получает свой, а не чужой.
Future<void> initAppLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString(AppLanguageNotifier.prefsKey);
  if (code != null) {
    L10n.setCurrent(L10n.byCode(code));
    return;
  }
  final system = L10n.forSystemLocales(
    WidgetsBinding.instance.platformDispatcher.locales,
  );
  // Языка системы в реестре нет — английский: словари остальных языков и так
  // добирают промахи у него, а русский среди английского смотрелся бы чужим.
  L10n.setCurrent(system ?? L10n.byCode('en'));
}
