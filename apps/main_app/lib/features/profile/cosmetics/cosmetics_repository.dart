import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';

// ============================================================================
//  Косметика: права и экипировка
//
//  Владелец прав — бэкенд (`user_cosmetics`), клиент только показывает витрину
//  и просит надеть. Поэтому [myCosmeticsProvider] не падает при ошибке сети:
//  каталог статичен в коде, а без ответа сервера пользователь видит
//  бесплатные предметы вместо сломанного экрана.
// ============================================================================

class MyCosmetics {
  const MyCosmetics({this.equipped = EquippedCosmetics.none, this.granted = const {}});

  /// Надетые предметы (то, что видит гость профиля).
  final EquippedCosmetics equipped;

  /// id выданных предметов с действующим сроком.
  final Set<String> granted;

  bool owns(CosmeticDef def) => def.free || granted.contains(def.id);

  bool canEquip(CosmeticDef def) => owns(def);
}

final myCosmeticsProvider = FutureProvider<MyCosmetics>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getString('jwt_token') == null) return const MyCosmetics();

  try {
    final res = await ref.watch(apiServiceProvider).get('profiles/cosmetics/mine');
    if (res is! Map<String, dynamic>) return const MyCosmetics();
    final granted = <String>{};
    final now = DateTime.now();
    for (final raw in res['granted'] ?? const <dynamic>[]) {
      if (raw is! Map) continue;
      final id = raw['id'] as String?;
      if (id == null || cosmeticById(id) == null) continue;
      final expires = raw['expires_at'] as String?;
      final until = expires == null ? null : DateTime.tryParse(expires);
      // Просроченное право не показываем: бэк такие строки тоже отсекает.
      if (until != null && until.isBefore(now)) continue;
      granted.add(id);
    }
    return MyCosmetics(
      equipped: EquippedCosmetics.fromJson(res['equipped']),
      granted: granted,
    );
  } catch (_) {
    // 404 = прод ещё без косметики, 5xx = сервер на обслуживании. Витрина
    // от этого не обязан разваливаться.
    return const MyCosmetics();
  }
});

/// Человекочитаемая причина отказа от бэка (`{"error":"..."}` в тексте исключения).
String serverErrorMessage(Object error, {String? fallback}) {
  final match = RegExp(
    r'"error"\s*:\s*"([^"]+)"',
  ).firstMatch(error.toString());
  return match?.group(1) ?? fallback ?? tr('Не удалось сохранить оформление');
}

/// Текст об активации промокода. Бэк перечисляет выданные предметы их id, а
/// названия живут только здесь — показываем человеку «Салют», а не «fireworks».
/// Длинные id подменяем первыми: иначе «rain» успел бы испортить «coin_rain».
String promoResultMessage(Map<dynamic, dynamic> res) {
  final message = res['message'] as String? ?? tr('Код активирован');
  final ids = ((res['cosmetics'] as List?) ?? const [])
      .whereType<String>()
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  var result = message;
  for (final id in ids) {
    result = result.replaceAll(id, cosmeticById(id)?.name ?? id);
  }
  return result;
}

/// Активация промокода: общий вызов для настроек и профиля. Код выдаёт
/// оформление, поэтому после успеха сбрасываем права и профиль — иначе
/// витрина до перезапуска покажет предметы закрытыми.
/// Бросает исключение; наружный слой показывает его [serverErrorMessage]-ом.
Future<String> redeemPromoCode({
  required WidgetRef ref,
  required String userId,
  required String code,
}) async {
  final dynamic res;
  try {
    res = await ref
        .read(apiServiceProvider)
        .post('profiles/redeem', body: {'code': code});
  } catch (e) {
    // 404 «Промокод не найден», 400 «Лимит активаций исчерпан» — это штатные
    // ответы, а не авария: человек должен прочитать текст бэка, а не стек.
    throw Exception(serverErrorMessage(e, fallback: tr('Не удалось активировать код')));
  }
  ref.invalidate(myCosmeticsProvider);
  ref.invalidate(userProfileProvider(userId));
  return promoResultMessage(
    res is Map<dynamic, dynamic> ? res : const <dynamic, dynamic>{},
  );
}

/// Надевает/снимает предмет слота. Сервер проверяет право — клиент лишь
/// отрисовывает ответ.
Future<void> equipCosmetic({
  required WidgetRef ref,
  required String userId,
  required EquippedCosmetics next,
}) async {
  await ref
      .read(apiServiceProvider)
      .post('profiles/me', body: {'cosmetics': next.toJson()});
  ref.invalidate(myCosmeticsProvider);
  ref.invalidate(userProfileProvider(userId));
}
