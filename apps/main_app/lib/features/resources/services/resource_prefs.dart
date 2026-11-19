import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Личные предпочтения библиотеки ресурсов — хранятся на устройстве и
/// никуда не синхронизируются.
///
/// `ResourcesScreen` открывается синхронно (лаунчер документов строит вкладку
/// без `await`, восстановление сессии — тоже), поэтому настройка «с чего
/// начинать» читается заранее в bootstrap и держится в памяти.
class ResourcesPrefs {
  ResourcesPrefs._();
  static final ResourcesPrefs instance = ResourcesPrefs._();

  /// Открывать библиотеку на корневой папке, а не там, где её закрыли.
  static const String openAtRootKey = 'resources_open_at_root';

  bool _openAtRoot = false;
  bool _loaded = false;

  bool get openAtRoot => _openAtRoot;

  @visibleForTesting
  void resetForTests() {
    _openAtRoot = false;
    _loaded = false;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _openAtRoot = prefs.getBool(openAtRootKey) ?? false;
    _loaded = true;
  }

  Future<void> setOpenAtRoot(bool value) async {
    _openAtRoot = value;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(openAtRootKey, value);
  }
}
