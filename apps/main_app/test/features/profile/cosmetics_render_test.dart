import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/core/theme/banner_presets.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_painters.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart';
import 'package:canvas_app/features/profile/widgets/profile_widgets.dart';
import 'package:canvas_app/models/market_activity_model.dart';
import 'package:canvas_app/models/notification_model.dart';
import 'package:canvas_app/models/user_profile_model.dart';

/// Все превью рендерятся статично: тикер с периодом 600 c не даст
/// `pumpAndSettle` завершиться, а нам важен сам факт отсутствия исключений.
Widget _wrapStatic(Widget child) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: Center(child: SizedBox(width: 320, child: child))),
  ),
);

void main()
{
  group('каталог', () {
    test('id уникальны и каждый предмет попадает в свой слот', () {
      final seen = <String>{};
      // Витрина ищет предметы по названию (`find.text`), поэтому две карточки
      // с одним именем ломают не только тесты, но и выдачу из админки.
      final names = <String>{};
      for (final def in kCosmetics) {
        expect(seen.add(def.id), isTrue, reason: 'дубликат id ${def.id}');
        expect(def.name, isNotEmpty);
        expect(names.add(def.name), isTrue, reason: 'дубликат имени «${def.name}»');
        expect(specSlot(def), def.slot);
      }
    });

    test('старые пресеты баннеров живы: их id уже лежат в базах у игроков', () {
      for (final preset in kBannerPresets) {
        final def = cosmeticById(preset.id);
        expect(def, isNotNull, reason: 'потерян id баннера ${preset.id}');
        expect(def!.slot, CosmeticSlot.banner);
      }
    });

    test('banner_style строкой читается: ветка не мёртвая', () {
      final profile = UserProfile.fromJson(const {
        'id': 'u-1',
        'created_at': '2026-01-01T00:00:00Z',
        'banner_style': '{"type":"preset","id":"aurora"}',
        'cosmetics': '{"banner":"gold_leaf"}',
      });
      expect(profile.bannerStyle?.id, 'aurora');
      expect(profile.cosmetics.banner, 'gold_leaf');
    });

    test('неизвестный id не роняет разбор, а теряется', () {
      final equipped = EquippedCosmetics.fromJson({
        'banner': 'no_such_banner',
        'name_style': 'royal_gold',
      });
      expect(equipped.banner, isNull);
      expect(equipped.nameStyle, 'royal_gold');
    });

    test('экипировка переживает json-строку от старого драйвера', () {
      final raw = EquippedCosmetics(banner: 'starfield', effect: 'snowfall');
      final decoded = EquippedCosmetics.fromJson('{"banner":"starfield","effect":"snowfall"}');
      expect(decoded.banner, raw.banner);
      expect(decoded.effect, raw.effect);
      expect(decoded.toJson()['effect'], 'snowfall');
    });

    test('список слота отсортирован по убыванию редкости', () {
      final list = cosmeticsOfSlot(CosmeticSlot.avatarFrame);
      for (var i = 1; i < list.length; i++) {
        expect(
          list[i - 1].tier.rank,
          greaterThanOrEqualTo(list[i].tier.rank),
          reason: '${list[i - 1].id} стоит до ${list[i].id}',
        );
      }
    });

    test('у каждого арта и фона есть файл в бандле', () {
      // Путь к картинке — это контракт с pubspec: опечатка в имени файла
      // не ломает сборку, а молча подменяет арт градиентом на устройстве.
      final paths = <String>{
        for (final def in kCosmetics)
          if (def.spec is BannerSpec) ...[
            if (def.banner.image != null) def.banner.image!,
            if (def.banner.animatedImage != null) def.banner.animatedImage!,
          ] else if (def.spec is BackgroundSpec)
            def.background.image,
      };
      expect(paths, isNotEmpty);
      for (final path in paths) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: 'нет файла $path');
        expect(file.lengthSync(), greaterThan(1024), reason: 'пустой/битый $path');
        expect(
          File('pubspec.yaml').readAsStringSync(),
          contains('assets/images/cosmetics/'),
          reason: 'папка с артами не объявлена в pubspec',
        );
      }
    });
  });

  group('рендереры', () {
    testWidgets('каждый предмет каталога рисуется без исключений', (tester) async {
      for (final def in kCosmetics) {
        await tester.pumpWidget(_wrapStatic(CosmeticPreview(def: def)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'исключение на ${def.id}');
      }
    });

    test('салют переживает весь цикл залпов и неполную пачку', () {
      // Статичное превью снимает только первую фазу, а залп живёт циклом:
      // прогоняем все фазы вручную. Неполная пачка (count не кратен размеру
      // залпа) — отдельный риск: центр берётся из первой частицы пачки.
      final spec = cosmeticById('fireworks')!.effect;
      final ragged = EffectSpec(
        kind: ParticleKind.burst,
        colors: spec.colors,
        count: spec.count - 5,
        speed: spec.speed,
      );
      for (final field in [spec, ragged]) {
        for (var ms = 0; ms <= 5000; ms += 137) {
          final recorder = ui.PictureRecorder();
          ParticleFieldPainter(
            spec: field,
            t: ms / 1000,
          ).paint(Canvas(recorder), const Size(360, 160));
          recorder.endRecording().dispose();
        }
      }
    });

    testWidgets('обложка с частицами и надетым эффектом не конфликтует', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapStatic(
          CosmeticBanner(
            def: cosmeticById('frost_panel'),
            height: 120,
            overlayEffect: cosmeticById('coin_rain'),
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('без предмета обложка берёт fallback-градиент темы', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapStatic(
          CosmeticBanner(
            def: null,
            height: 100,
            fallbackGradient: const LinearGradient(colors: [Colors.red, Colors.blue]),
            child: const Text('шапка'),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('шапка'), findsOneWidget);
    });

    test('у арт-обложки живой кадр включается только при разрешённом движении', () {
      final live = cosmeticById('art_night_meadow')!.banner;
      expect(artImageFor(live, animate: true), endsWith('art_0_loop.webp'));
      expect(artImageFor(live, animate: false), endsWith('art_0.webp'));

      final still = cosmeticById('art_golden_field')!.banner;
      expect(artImageFor(still, animate: true), endsWith('art_1.webp'));
    });

    testWidgets('арт-обложка со reduceMotion показывает статичный кадр', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapStatic(
          CosmeticBanner(
            def: cosmeticById('art_night_meadow'),
            height: 160,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as AssetImage).assetName,
        'assets/images/cosmetics/art_0.webp',
        reason: 'reduceMotion — статичный первый кадр',
      );
    });

    testWidgets('фон профиля рисует арт, а не пустоту', (tester) async {
      await tester.pumpWidget(
        _wrapStatic(
          SizedBox(
            height: 240,
            child: CosmeticBackground(def: cosmeticById('bg_golden_field')),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as AssetImage).assetName,
        'assets/images/cosmetics/art_1.webp',
      );
    });

    testWidgets('reduceMotion глушит тикер, косметика остаётся кадром', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapStatic(
          CosmeticNameText(
            name: 'Победитель',
            def: cosmeticById('royal_gold'),
            hero: true,
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Победитель'), findsOneWidget);
      // Ничего не тикает: можно спокойно докрутить тест до конца.
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('ник в списке красится основным цветом предмета', (tester) async {
      await tester.pumpWidget(
        _wrapStatic(
          CosmeticNameText(
            name: 'Август',
            def: cosmeticById('toxic_lime'),
            style: const TextStyle(fontSize: 14),
          ),
        ),
      );
      await tester.pump();
      final text = tester.widget<Text>(find.text('Август'));
      expect(text.style?.color, const Color(0xFFB6FF3C));
    });

    testWidgets('в шапке профиля ник ведёт градиентом предмета', (tester) async {
      final def = cosmeticById('pride_wave')!;
      await tester.pumpWidget(
        _wrapStatic(CosmeticNameText(name: 'Август', def: def, hero: true)),
      );
      await tester.pump();
      // ShaderMask по границам текста — это и есть переливающийся ник. В
      // списках его быть не должно (тест выше): там сотни строк за экран.
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('аватар без предмета и без картинки — заглушка', (tester) async {
      await tester.pumpWidget(
        _wrapStatic(CosmeticAvatar(frame: null, radius: 30)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    });
  });

  group('права', () {
    test('бесплатный предмет можно надеть без выдачи', () {
      const mine = MyCosmetics();
      expect(mine.owns(cosmeticById('beige')!), isTrue);
      expect(mine.canEquip(cosmeticById('gold_leaf')!), isFalse);

      final granted = MyCosmetics(granted: const {'gold_leaf'});
      expect(granted.owns(cosmeticById('gold_leaf')!), isTrue);
    });

    test('текст ошибки бэка читается человеком', () {
      expect(
        serverErrorMessage(
          Exception('Failed to put data: 403 {"error":"Нет права на оформление"}'),
        ),
        'Нет права на оформление',
      );
      expect(serverErrorMessage(Exception('boom')), isNotEmpty);
    });

    test('промокод называет выданные предметы, а не их id', () {
      // Бэк не знает названий: каталог с ними живёт в клиенте.
      expect(
        promoResultMessage(const {
          'message': 'Премиум активирован на 30 дней. '
              'Выдано оформление: coin_rain, rain_placeholder, snowfall',
          'cosmetics': ['snowfall', 'coin_rain', 'rain_placeholder'],
        }),
        'Премиум активирован на 30 дней. '
            'Выдано оформление: Денежный дождь, rain_placeholder, Снегопад',
      );
      // Код без оформления — сообщение бэка как есть.
      expect(
        promoResultMessage(const {'message': 'Премиум активирован на 3 дня'}),
        'Премиум активирован на 3 дня',
      );
    });

    test('ник внутри фразы получает плоский цвет, лента — id из бэка', () {
      expect(cosmeticNameInlineStyle('toxic_lime')?.color, const Color(0xFFB6FF3C));
      // Обложка и пустота стилем ника не красятся.
      expect(cosmeticNameInlineStyle('aurora_drift'), isNull);
      expect(cosmeticNameInlineStyle(null), isNull);

      final item = MarketActivityItem.fromJson(const {
        'actor_name': 'Иван',
        'actor_name_style': 'royal_gold',
        'actor_avatar_frame': 'prism_ring',
      });
      expect(item.actorNameStyle, 'royal_gold');
      expect(item.actorFrame, 'prism_ring');
    });
  });

  group('списки других людей', () {
    testWidgets('уведомление красит ник актёра и обводит его аватар', (
      tester,
    ) async {
      final notification = AppNotification(
        id: 'n-1',
        type: 'wall_post_comment',
        createdAt: DateTime(2026),
        actorName: 'Иллюминат',
        actorNameStyle: 'toxic_lime',
        actorAvatarFrame: 'prism_ring',
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Scaffold(
                body: ProfileNotificationTile(notification: notification),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      // `Text` в этой версии Flutter держит только текст-спеку: обычный
      // find.text по RichText не ищется, поэтому идём по списку Text-виджетов.
      final tile = tester.widgetList<Text>(find.byType(Text)).firstWhere(
        (t) =>
            t.textSpan?.toPlainText() ==
            'Иллюминат прокомментировал(а) ваш пост',
      );
      final actorSpan = _spanWithText(tile.textSpan!, 'Иллюминат');
      expect(
        actorSpan?.style?.color,
        cosmeticNameInlineStyle('toxic_lime')?.color,
        reason: 'ник в заголовке уведомления не получил цвет из каталога',
      );
      expect(
        tester.widget<CosmeticAvatar>(find.byType(CosmeticAvatar)).frame?.id,
        'prism_ring',
      );
    });

    testWidgets('уведомление без косметики остаётся обычным текстом', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ProfileNotificationTile(
                notification: AppNotification(
                  id: 'n-2',
                  type: 'quest_approved',
                  createdAt: DateTime(2026),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('Квест прошёл модерацию'),
        findsOneWidget,
        reason: 'служебные уведомления собираются из хвоста без актёра',
      );
    });
  });
}

/// Обходит дерево спанов и возвращает узел с нужным текстом.
TextSpan? _spanWithText(InlineSpan root, String text) {
  TextSpan? found;
  root.visitChildren((span) {
    if (span is TextSpan && span.text == text) {
      found = span;
      return false;
    }
    return true;
  });
  return found;
}

/// Слот по типу спеки — ловит случай, когда предмет положили в каталог под
/// неправильным слотом (тогда витрина его вообще не покажет).
CosmeticSlot specSlot(CosmeticDef def) => switch (def.spec) {
  BannerSpec() => CosmeticSlot.banner,
  BackgroundSpec() => CosmeticSlot.background,
  FrameSpec() => CosmeticSlot.avatarFrame,
  NameSpec() => CosmeticSlot.nameStyle,
  EffectSpec() => CosmeticSlot.effect,
  _ => throw StateError('неизвестная спека у ${def.id}'),
};
