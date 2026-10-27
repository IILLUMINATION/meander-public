import 'package:shared_preferences/shared_preferences.dart';

/// Какие гайды человек уже дочитал. Отдельно от подсказок: «Понятно» — это
/// прогресс обучения, а не закрытая плашка, и сброс подсказок в настройках
/// не должен стирать отметку «прочитано».
class GuideProgressStore {
  GuideProgressStore._();

  static const String key = 'guides_read_v1';

  static Future<Set<String>> read() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(key) ?? const <String>[]).toSet();
  }

  static Future<bool> isRead(String guideId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key)?.contains(guideId) ?? false;
  }

  static Future<void> markRead(String guideId) async {
    final prefs = await SharedPreferences.getInstance();
    final read = (prefs.getStringList(key) ?? <String>[]).toList();
    if (read.contains(guideId)) return;
    read.add(guideId);
    await prefs.setStringList(key, read);
  }
}
