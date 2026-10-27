import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:flutter/material.dart';

/// Канонические жанры квеста.
///
/// В базе и в API живёт только `id` — стабильный латинский ключ. Подпись
/// строится на клиенте под текущий язык, поэтому переименование или перевод
/// жанра не ломает фильтр и не требует миграции данных. Старые записи хранят
/// английские названия (`Fantasy`, `Sci-Fi`, …), их переводит
/// [normalizeGenreId].
const List<String> kQuestGenreIds = [
  'fantasy',
  'dark_fantasy',
  'fairytale',
  'mythology',
  'sci_fi',
  'cyberpunk',
  'steampunk',
  'post_apocalypse',
  'space_opera',
  'horror',
  'supernatural',
  'vampire',
  'werewolf',
  'zombie',
  'mystery',
  'detective',
  'noir',
  'crime',
  'mafia',
  'heist',
  'spy',
  'thriller',
  'psychological',
  'adventure',
  'survival',
  'disaster',
  'war',
  'western',
  'pirates',
  'time_travel',
  'alternate_history',
  'historical',
  'romance',
  'drama',
  'tragedy',
  'comedy',
  'satire',
  'parody',
  'slice_of_life',
  'school',
  'family',
  'sports',
  'music',
  'travel',
  'philosophy',
  'puzzle',
  'escape_room',
  'martial_arts',
  'medical',
  'political',
  'business',
  'farming',
];

final Set<String> _genreIdSet = kQuestGenreIds.toSet();

/// Старые английские названия, которые уже лежат в опубликованных квестах.
/// Ключ — в нижнем регистре и с `-` вместо `_`, поэтому сравнение всегда
/// идёт по одному каноническому виду.
const Map<String, String> _legacyGenreAliases = {
  'fantasy': 'fantasy',
  'sci-fi': 'sci_fi',
  'scifi': 'sci_fi',
  'science-fiction': 'sci_fi',
  'horror': 'horror',
  'adventure': 'adventure',
  'mystery': 'mystery',
  'romance': 'romance',
  'comedy': 'comedy',
  'thriller': 'thriller',
  'historical': 'historical',
  'history': 'historical',
  'drama': 'drama',
};

/// Приводит значение из старого конфига/базы к каноническому id.
/// Пустая строка — жанр неизвестен и должен быть отброшен.
String normalizeGenreId(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return '';
  final key = value.toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');
  final alias = _legacyGenreAliases[key];
  if (alias != null) return alias;
  final snake = key.replaceAll('-', '_');
  if (_genreIdSet.contains(snake)) return snake;
  return '';
}

/// Чистит список жанров: убирает неизвестные и повторы, сохраняет порядок.
List<String> normalizeGenreIds(Iterable<dynamic> raw, {int max = 3}) {
  final result = <String>[];
  for (final item in raw) {
    final id = normalizeGenreId('$item');
    if (id.isEmpty || result.contains(id)) continue;
    result.add(id);
    if (result.length >= max) break;
  }
  return result;
}

/// Подпись жанра на текущем языке. Неизвестный id показываем как есть:
/// лучше сырое слово, чем пустая плашка.
String genreLabel(String? id) {
  switch (id) {
    case 'fantasy':
      return tr('Фэнтези');
    case 'dark_fantasy':
      return tr('Тёмное фэнтези');
    case 'fairytale':
      return tr('Сказка');
    case 'mythology':
      return tr('Мифология');
    case 'sci_fi':
      return tr('Фантастика');
    case 'cyberpunk':
      return tr('Киберпанк');
    case 'steampunk':
      return tr('Стимпанк');
    case 'post_apocalypse':
      return tr('Постапокалипсис');
    case 'space_opera':
      return tr('Космоопера');
    case 'horror':
      return tr('Ужасы');
    case 'supernatural':
      return tr('Сверхъестественное');
    case 'vampire':
      return tr('Вампиры');
    case 'werewolf':
      return tr('Оборотни');
    case 'zombie':
      return tr('Зомби');
    case 'mystery':
      return tr('Мистика');
    case 'detective':
      return tr('Детектив');
    case 'noir':
      return tr('Нуар');
    case 'crime':
      return tr('Криминал');
    case 'mafia':
      return tr('Мафия');
    case 'heist':
      return tr('Ограбление');
    case 'spy':
      return tr('Шпионаж');
    case 'thriller':
      return tr('Триллер');
    case 'psychological':
      return tr('Психологический триллер');
    case 'adventure':
      return tr('Приключения');
    case 'survival':
      return tr('Выживание');
    case 'disaster':
      return tr('Катастрофа');
    case 'war':
      return tr('Военный');
    case 'western':
      return tr('Вестерн');
    case 'pirates':
      return tr('Пираты');
    case 'time_travel':
      return tr('Путешествие во времени');
    case 'alternate_history':
      return tr('Альтернативная история');
    case 'historical':
      return tr('История');
    case 'romance':
      return tr('Романтика');
    case 'drama':
      return tr('Драма');
    case 'tragedy':
      return tr('Трагедия');
    case 'comedy':
      return tr('Комедия');
    case 'satire':
      return tr('Сатира');
    case 'parody':
      return tr('Пародия');
    case 'slice_of_life':
      return tr('Повседневность');
    case 'school':
      return tr('Школа');
    case 'family':
      return tr('Семейный');
    case 'sports':
      return tr('Спорт');
    case 'music':
      return tr('Музыка');
    case 'travel':
      return tr('Путешествие');
    case 'philosophy':
      return tr('Философский');
    case 'puzzle':
      return tr('Головоломка');
    case 'escape_room':
      return tr('Квест-комната');
    case 'martial_arts':
      return tr('Боевые искусства');
    case 'medical':
      return tr('Медицина');
    case 'political':
      return tr('Политический');
    case 'business':
      return tr('Бизнес');
    case 'farming':
      return tr('Фермерство');
    default:
      return id ?? '';
  }
}

IconData genreIcon(String? id) {
  switch (id) {
    case 'fantasy':
    case 'dark_fantasy':
    case 'fairytale':
      return Icons.auto_fix_high_rounded;
    case 'mythology':
      return Icons.temple_buddhist_rounded;
    case 'sci_fi':
    case 'space_opera':
      return Icons.rocket_launch_rounded;
    case 'cyberpunk':
      return Icons.memory_rounded;
    case 'steampunk':
      return Icons.settings_suggest_rounded;
    case 'post_apocalypse':
    case 'survival':
      return Icons.local_fire_department_rounded;
    case 'horror':
    case 'zombie':
    case 'vampire':
    case 'werewolf':
      return Icons.dark_mode_rounded;
    case 'supernatural':
      return Icons.auto_awesome_rounded;
    case 'mystery':
    case 'detective':
    case 'noir':
      return Icons.psychology_rounded;
    case 'crime':
    case 'mafia':
    case 'heist':
      return Icons.gavel_rounded;
    case 'spy':
      return Icons.visibility_rounded;
    case 'thriller':
    case 'psychological':
      return Icons.bolt_rounded;
    case 'adventure':
      return Icons.terrain_rounded;
    case 'disaster':
      return Icons.storm_rounded;
    case 'war':
      return Icons.shield_rounded;
    case 'western':
      return Icons.cottage_rounded;
    case 'pirates':
      return Icons.sailing_rounded;
    case 'time_travel':
    case 'alternate_history':
    case 'historical':
      return Icons.account_balance_rounded;
    case 'romance':
      return Icons.favorite_rounded;
    case 'drama':
    case 'tragedy':
      return Icons.masks_rounded;
    case 'comedy':
    case 'satire':
    case 'parody':
      return Icons.theater_comedy_rounded;
    case 'slice_of_life':
      return Icons.local_cafe_rounded;
    case 'school':
      return Icons.school_rounded;
    case 'family':
      return Icons.family_restroom_rounded;
    case 'sports':
      return Icons.sports_soccer_rounded;
    case 'music':
      return Icons.music_note_rounded;
    case 'travel':
      return Icons.flight_takeoff_rounded;
    case 'philosophy':
      return Icons.self_improvement_rounded;
    case 'puzzle':
    case 'escape_room':
      return Icons.extension_rounded;
    case 'martial_arts':
      return Icons.sports_martial_arts_rounded;
    case 'medical':
      return Icons.medical_services_rounded;
    case 'political':
      return Icons.campaign_rounded;
    case 'business':
      return Icons.business_center_rounded;
    case 'farming':
      return Icons.agriculture_rounded;
    default:
      return Icons.label_outline_rounded;
  }
}
