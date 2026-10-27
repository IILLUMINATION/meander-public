import 'package:canvas_app/core/l10n/app_language.dart';
import 'package:canvas_app/core/l10n/l10n_provider.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/models/market_activity_model.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// === СОСТОЯНИЕ UI (Поиск и Фильтры) ===
final marketSearchProvider = StateProvider<String>((ref) => '');
// Теперь это может хранить не только категорию, но и 'verified', 'trending'
final marketCategoryProvider = StateProvider<String?>((ref) => null);

// === ЯЗЫКОВОЙ ПОРЯДОК ===

/// Совпадает ли язык квеста с языком игрока — с точностью до региона: игроку
/// `pt-BR` подходит и `pt-BR`, и `pt`.
///
/// Квест без метки считается написанным на языке оригинала интерфейса
/// (русском): так исторически сложилось, и без этого допущения квесты
/// новых авторов проваливались бы в конец списка для всех, кроме иностранцев.
bool _matchesPlayerLanguage(String? questLanguage, String playerLanguage) {
  final code = questLanguage ?? kSourceLanguageCode;
  if (code == playerLanguage) return true;
  return code.split('-').first == playerLanguage.split('-').first;
}

/// Квесты на языке игрока — первыми, остальные — в исходном порядке.
///
/// Порядок внутри групп не трогается: он уже выставан сортировкой списка
/// (свежесть, рейтинг), и перемешивать его ради языка было бы обманом
/// читателя. Если совпадений нет вообще, список возвращается как есть.
List<MarketQuest> orderByPlayerLanguage(
  List<MarketQuest> quests,
  String playerLanguage,
) {
  final mine = quests
      .where((q) => _matchesPlayerLanguage(q.language, playerLanguage))
      .toList();
  if (mine.isEmpty || mine.length == quests.length) return quests;
  final mineIds = mine.map((q) => q.id).toSet();
  return [
    ...mine,
    ...quests.where((q) => !mineIds.contains(q.id)),
  ];
}

// === ПОРЯДОК УРОВНЕЙ ===

/// Устойчивая сортировка по уровню каталога: демо уезжает вниз, порядок
/// внутри уровня не меняется. Устойчивость важна — до неё список уже
/// отсортирован по свежести/рейтингу, и перемешивать его незачем.
List<MarketQuest> orderByMarketTier(List<MarketQuest> quests) {
  final indexed = quests.indexed.toList()
    ..sort((a, b) {
      final byTier = a.$2.marketTier.compareTo(b.$2.marketTier);
      return byTier != 0 ? byTier : a.$1.compareTo(b.$1);
    });
  return [for (final entry in indexed) entry.$2];
}

/// Порядок каталога для игрока: сначала уровень, внутри уровня — его язык,
/// дальше исходный порядок (сервер уже отсортировал по свежести).
///
/// Язык не может поднять демо выше отобранного квеста: новичок должен
/// видеть лучшее первым, даже если оно на другом языке.
List<MarketQuest> orderCatalogForPlayer(
  List<MarketQuest> quests,
  String playerLanguage,
) {
  final indexed = quests.indexed.toList()
    ..sort((a, b) {
      final byTier = a.$2.marketTier.compareTo(b.$2.marketTier);
      if (byTier != 0) return byTier;
      final aMine = _matchesPlayerLanguage(a.$2.language, playerLanguage);
      final bMine = _matchesPlayerLanguage(b.$2.language, playerLanguage);
      if (aMine != bMine) return aMine ? -1 : 1;
      return a.$1.compareTo(b.$1);
    });
  return [for (final entry in indexed) entry.$2];
}

// === DATA PROVIDERS ===

/// 1. Свежие релизы (Все квесты, сортировка по ДАТЕ ОБНОВЛЕНИЯ)
/// ИСПРАВЛЕНО: Теперь сортируем по updatedAt, чтобы поднятые квесты были сверху
final marketQuestsProviderNew = FutureProvider.autoDispose<List<MarketQuest>>((
  ref,
) async {
  final apiService = ref.watch(apiServiceProvider);
  final playerLanguage = ref.watch(appLanguageProvider).code;
  try {
    final responseData = await apiService.get('quests');
    final list = (responseData as List)
        .map((json) => MarketQuest.fromJson(json))
        .toList();

    // Сортируем: сначала самые свежие (по созданию ИЛИ обновлению)
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return orderCatalogForPlayer(list, playerLanguage);
  } catch (e) {
    print('Error loading new quests: $e');
    rethrow;
  }
});

/// 2. В тренде (Популярные)
final marketQuestsProviderPopular =
    FutureProvider.autoDispose<List<MarketQuest>>((ref) async {
      final apiService = ref.watch(apiServiceProvider);
      try {
        final responseData = await apiService.get('quests');
        final list = (responseData as List)
            .map((json) => MarketQuest.fromJson(json))
            .toList();

        // Сортировка по скачиваниям + рейтингу, затем уровень: популярное
        // демо не должно стоять выше отобранного квеста.
        list.sort((a, b) {
          final scoreA = a.downloadsCount + (a.likeCount * 5);
          final scoreB = b.downloadsCount + (b.likeCount * 5);
          return scoreB.compareTo(scoreA);
        });
        return orderByMarketTier(list);
      } catch (e) {
        return [];
      }
    });

/// 3. Выбор Миандера (Featured / Рекомендуемое)
final meanderRecommendsProvider = FutureProvider.autoDispose<List<MarketQuest>>(
  (ref) async {
    final apiService = ref.watch(apiServiceProvider);
    try {
      final responseData = await apiService.get('quests/featured');
      final featured = (responseData as List)
          .map((json) => MarketQuest.fromJson(json))
          .where((q) => !q.isDemo)
          .toList();

      if (featured.isNotEmpty) return orderByMarketTier(featured);

      // ФОЛЛБЭК: Если список пуст, берем топ-5 самых рейтинговых
      final all = await ref.read(marketQuestsProviderNew.future);
      all.sort((a, b) => b.averageRating.compareTo(a.averageRating));
      return orderByMarketTier(all.where((q) => !q.isDemo).toList());
    } catch (e) {
      return [];
    }
  },
);

/// 4. От проверенных авторов (Verified Authors)
final verifiedAuthorsQuestsProvider =
    FutureProvider.autoDispose<List<MarketQuest>>((ref) async {
      try {
        final allQuests = await ref.watch(marketQuestsProviderNew.future);
        return allQuests.where((q) => q.authorIsVerified).toList();
      } catch (e) {
        return [];
      }
    });

/// 4b. Лучшие: отобраны вручную. Отдельная полка, а не фильтр по рейтингу —
/// место в ней даёт куратор, и оно не должно размываться языком или свежестью.
final bestQuestsProvider = FutureProvider.autoDispose<List<MarketQuest>>((
  ref,
) async {
  try {
    final allQuests = await ref.watch(marketQuestsProviderNew.future);
    return allQuests.where((q) => q.isBest).toList();
  } catch (e) {
    return [];
  }
});

/// 5. Скрытые алмазы (Random for Newbies)
/// Показывает случайные квесты, у которых мало скачиваний
final undiscoveredQuestsProvider =
    FutureProvider.autoDispose<List<MarketQuest>>((ref) async {
      try {
        final allQuests = await ref.watch(marketQuestsProviderNew.future);
        // Берем квесты где меньше 100 скачиваний. Демо сюда не пускаем:
        // это витрина новинок, а не второй вход в третий уровень.
        final newbies = allQuests
            .where((q) => q.downloadsCount < 100 && !q.isDemo)
            .toList();
        newbies.shuffle(); // Перемешиваем
        return newbies.take(10).toList(); // Берем 10 штук
      } catch (e) {
        return [];
      }
    });

/// 6. Провайдер поиска (для экрана поиска)
final searchQuestsProvider = FutureProvider.autoDispose
    .family<List<MarketQuest>, String>((ref, query) async {
      if (query.trim().isEmpty) return [];
      final apiService = ref.watch(apiServiceProvider);
      final playerLanguage = ref.watch(appLanguageProvider).code;
      try {
        final responseData = await apiService.get(
          'quests',
          queryParams: {'search': query},
        );
        return orderCatalogForPlayer(
          (responseData as List)
              .map((json) => MarketQuest.fromJson(json))
              .toList(),
          playerLanguage,
        );
      } catch (e) {
        return [];
      }
    });

/// Что показывать в сетке маркета.
///
/// Демо-версии спрятаны из общего каталога: у них своя категория и своя лента,
/// а в основном списке они только шумят. В поиске же их показываем — человек
/// ищет по слову, и скрыть подходящие демо означало бы потерять результат.
List<MarketQuest> visibleMarketQuests({
  required List<MarketQuest> quests,
  required String searchQuery,
  required String? selectedCategory,
}) {
  if (selectedCategory == 'demo' || searchQuery.trim().isNotEmpty) {
    return quests;
  }
  return quests.where((q) => !q.isDemo).toList();
}

/// 7. Агрегированный провайдер (Поиск + Категории) для главного экрана
final filteredMarketQuestsProvider =
    FutureProvider.autoDispose<List<MarketQuest>>((ref) async {
      final searchQuery = ref.watch(marketSearchProvider);
      final category = ref.watch(marketCategoryProvider);

      // Если есть поиск по тексту
      if (searchQuery.isNotEmpty) {
        final results = await ref.watch(
          searchQuestsProvider(searchQuery).future,
        );
        if (category == 'demo') {
          return results.where((q) => q.isDemo).toList();
        }
        if (category == 'featured') {
          final featured = await ref.watch(meanderRecommendsProvider.future);
          final featuredIds = featured.map((q) => q.id).toSet();
          return results.where((q) => featuredIds.contains(q.id)).toList();
        }
        if (category == 'best') {
          return results.where((q) => q.isBest).toList();
        }
        if (category != null &&
            category != 'verified' &&
            category != 'trending') {
          // Фильтруем результаты поиска еще и по категории, если выбрана
          // (кроме спец-категорий, так как API поиска обычно ищет глобально)
          return results
              .where(
                (q) => q.genres.contains(category) || q.category == category,
              )
              .toList();
        }
        return results;
      }

      // Если выбрана категория (чипы)
      if (category != null) {
        if (category == 'best') {
          return await ref.watch(bestQuestsProvider.future);
        }
        if (category == 'featured') {
          return await ref.watch(meanderRecommendsProvider.future);
        }
        if (category == 'verified') {
          return await ref.watch(verifiedAuthorsQuestsProvider.future);
        }
        if (category == 'trending') {
          return await ref.watch(marketQuestsProviderPopular.future);
        }
        if (category == 'demo') {
          return await ref.watch(demoQuestsProvider.future);
        }
        // Обычные жанры
        final all = await ref.watch(marketQuestsProviderNew.future);
        return all
            .where((q) => q.genres.contains(category) || q.category == category)
            .toList();
      }

      return [];
    });

/// 8. ????-??????
final demoQuestsProvider = FutureProvider.autoDispose<List<MarketQuest>>((
  ref,
) async {
  try {
    final allQuests = await ref.watch(marketQuestsProviderNew.future);
    return allQuests.where((q) => q.isDemo).toList();
  } catch (e) {
    return [];
  }
});

/// 9. Последние действия в маркете (публикации/лайки/отзывы)
final marketRecentActivityProvider =
    FutureProvider.autoDispose<List<MarketActivityItem>>((ref) async {
      final apiService = ref.watch(apiServiceProvider);
      try {
        final responseData = await apiService.get(
          'quests/activity/recent',
          queryParams: {'limit': '20'},
        );
        if (kDebugMode) {
          final responseType = responseData.runtimeType;
          final rawLength = responseData is List ? responseData.length : -1;
          debugPrint(
            '[MarketActivity] responseType=$responseType rawLength=$rawLength',
          );
        }
        final list = (responseData as List)
            .map((json) => MarketActivityItem.fromJson(json))
            .toList();
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (kDebugMode) {
          debugPrint('[MarketActivity] parsedLength=${list.length}');
        }
        return list;
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('[MarketActivity] load failed: $e');
          debugPrint('$st');
        }
        return [];
      }
    });
