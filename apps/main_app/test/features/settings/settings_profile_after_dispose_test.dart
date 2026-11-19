// Настройки → профиль. Пять долгих путей пишут на сервер и перезагружают
// `userProfileProvider`: имя, био, «18+», «Не беспокоить ночью» и фоновый
// часовой пояс. Все пять делали `ref.invalidate` после await.
//
// Экран настроек живёт в табах и закрывается тапом по «Назад», а POST из
// мобильного интернета — это секунды. Долетевший ответ попадал в мёртвый
// `ref`: в debug это StateError («This widget has been unmounted…»), дальше
// пути расходились:
// - в `_syncTimezone` и `_toggleQuietHours` бросок ловил `catch (_) {}` — то
//   есть сервер значение принял, а кэш профиля остался со старым, и человек
//   видел прежний переключатель;
// - в `_editName`, `_editBio` и `_toggleNsfw` бросок ловил `catch (e)`, а тот
//   печатал «Ошибка: …» — успешное сохранение выглядело провалом (снэкбар
//   стоит под `if (mounted)`, так что на закрытом экране не появлялось и он:
//   сохранённое имя молча оставалось невидимым до перезапуска).
//
// Отдельный дефект у «Не беспокоить ночью»: провал (нет сети, просроченная
// сессия) не показывал ничего. Тап по строке не давал ни изменения, ни
// слова — жест повторяли, решив что «не с первого раза».
//
// Правка та же, что в срезе H, I и в `session_service.dart`: контейнер берётся
// до первого await, обновления идут через него и ДО mounted-гарда.
//
// Здесь держим: два реальных пути через UI (тап по строке «Не беспокоить
// ночью» и диалог «Изменить имя») на гейте вместо сети, внешнего слушателя
// `userProfileProvider` (провайдер autoDispose — без живого слушателя
// invalidate нечего обновлять, и тест был бы пустым), честный текст провала
// и скан исходника на остальные три метода.
//
// НЕГАТИВНЫЙ КОНТРОЛЬ (проверено): откатить `settings_screen.dart` — падают
// оба dispose-теста (слушатель остаётся со старым значением), тест провала
// (снэкбара нет вовсе) и скан (пять `ref.invalidate`, ноль containerOf).

import 'dart:async';
import 'dart:io';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _uid = 'u-1';
const String _quietTile = 'Не беспокоить ночью';
const String _nameTile = 'Редактировать имя';

/// Сервер в тесте: GET профиля, POST в `profiles/me`, гейт вместо задержки
/// сети и опциональная ошибка вместо ответа.
class _FakeApi extends ApiService {
  _FakeApi();

  bool quietHours = true;
  String fullName = 'Илья';
  String bio = '';
  bool showNsfw = false;

  /// Нерешённый future — POST висит на нём, пока тест его не отпустит.
  Completer<void>? gate;

  /// Кинуть это вместо успеха.
  Object? failWith;

  int posts = 0;

  Map<String, dynamic> json() => {
    'id': _uid,
    'full_name': fullName,
    'bio': bio,
    'created_at': '2026-01-01T00:00:00.000Z',
    'quiet_hours_enabled': quietHours,
    'show_nsfw': showNsfw,
  };

  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    if (endpoint == 'auth/account') {
      return <String, dynamic>{'deletion_scheduled_at': null};
    }
    if (endpoint == 'profiles/$_uid') return json();
    throw StateError('неожиданный GET $endpoint');
  }

  @override
  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) async {
    if (endpoint != 'profiles/me') {
      throw StateError('неожиданный POST $endpoint');
    }
    posts++;
    final fail = failWith;
    if (fail != null) throw fail;
    final pending = gate;
    if (pending != null) await pending.future;
    final fields = body ?? const <String, dynamic>{};
    if (fields.containsKey('quiet_hours_enabled')) {
      quietHours = fields['quiet_hours_enabled'] as bool;
    }
    if (fields.containsKey('full_name')) {
      fullName = fields['full_name'] as String;
    }
    if (fields.containsKey('bio')) bio = fields['bio'] as String;
    if (fields.containsKey('show_nsfw')) {
      showNsfw = fields['show_nsfw'] as bool;
    }
    return json();
  }
}

/// Каркас: слева — внешний слушатель профиля (он переживает экран), справа —
/// сами настройки, снимаемые с дерева флагом. Возвращает этот флаг: `false` —
/// то же самое, что закрыть вкладку настроек посреди операции.
Future<ValueNotifier<bool>> _pumpSettings(
  WidgetTester tester,
  _FakeApi api,
) async {
  final showScreen = ValueNotifier<bool>(true);
  addTearDown(showScreen.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 170,
                child: Consumer(
                  builder: (context, ref, _) {
                    final profile = ref.watch(userProfileProvider(_uid));
                    final p = profile.valueOrNull;
                    return Text(
                      p == null
                          ? 'profile:нет данных'
                          : 'profile:${p.fullName}|${p.quietHoursEnabled}',
                      textDirection: TextDirection.ltr,
                    );
                  },
                ),
              ),
              Expanded(
                child: ValueListenableBuilder<bool>(
                  valueListenable: showScreen,
                  builder: (context, show, _) =>
                      show ? const SettingsScreen() : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await _wait(tester, () => find.text('profile:Илья|true').evaluate().isNotEmpty);
  expect(
    find.text('profile:Илья|true'),
    findsOneWidget,
    reason: 'профиль не загрузился — проверке не на чём висеть',
  );
  return showScreen;
}

/// Промотать fake-часы: POST и перезагрузка профиля — обычные future’ы, диск
/// тут не участвует, так что `runAsync` не нужен.
Future<void> _wait(WidgetTester tester, bool Function() until) async {
  for (var i = 0; i < 60 && !until(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _tile(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(InkWell));

/// Доехать до строки списком.
///
/// Настройки — слайверы, а их дети строятся только вокруг вьюпорта: искать
/// строку ниже первого экрана бессмысленно, её ещё нет в дереве. Плюс высота
/// строк зависит от переносов подписей, поэтому порог «видна без прокрутки»
/// гуляет от любой правки выше по списку — прокрутка надёжнее.
Future<Finder> _scrollToTile(WidgetTester tester, String title) async {
  final tile = _tile(title);
  await tester.scrollUntilVisible(
    tile,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  expect(tile, findsOneWidget, reason: 'строки «$title» нет в списке');
  return tile;
}

/// Проверка, что тест вообще про dispose: экрана нет, операция ещё в полёте.
void _expectOperationStillInFlight(_FakeApi api, ValueNotifier<bool> showScreen) {
  expect(
    api.posts,
    1,
    reason: 'POST не ушёл — тап пришёл мимо строки',
  );
  expect(showScreen.value, isFalse, reason: 'экран не снимался с дерева');
  expect(
    find.byType(SettingsScreen),
    findsNothing,
    reason: 'экран не снят — проверки ниже бессмысленны',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // `_syncTimezone` при открытии настроек отправил бы POST первым же делом и
    // съел бы счётчик/гейт теста, поэтому считаем, что сегодня уже
    // синхронизировались.
    final today = DateTime.now().toIso8601String().substring(0, 10);
    SharedPreferences.setMockInitialValues({
      'user_id': _uid,
      'jwt_token': 't-1',
      'tz_last_sync': today,
    });
  });

  test('долгие пути в настройках обновляют профиль через container', () {
    final source = File(
      'lib/features/settings/screens/settings_screen.dart',
    ).readAsStringSync();

    expect(
      'ref.invalidate'.allMatches(source).length,
      0,
      reason: 'ref после dispose бросает — через него обновлений быть не должно',
    );
    expect(
      'ProviderScope.containerOf(context'.allMatches(source).length,
      6,
      reason:
          'контейнер должны брать все шесть долгих путей: имя, юзернейм, био, '
          '18+, «не беспокоить», часовой пояс',
    );

    // Тихий провал — это то, из-за чего жест повторяют.
    final start = source.indexOf('Future<void> _toggleQuietHours(');
    expect(start, isNot(-1), reason: '_toggleQuietHours не найден');
    final quiet = source.substring(start, source.indexOf('\n  }\n', start));
    expect(quiet, contains('container.invalidate(userProfileProvider'));
    expect(quiet, contains('friendlyError'));
    expect(
      quiet,
      isNot(contains('catch (_) {}')),
      reason: 'провал молча — человек не узнаёт, что сервер его не принял',
    );
  });

  testWidgets('закрыть настройки посреди переключения — профиль перезагрузился', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(460, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _FakeApi();
    final showScreen = await _pumpSettings(tester, api);

    final tile = await _scrollToTile(tester, _quietTile);
    await tester.pump();

    api.gate = Completer<void>();
    await tester.tap(tile);
    await tester.pump();
    expect(
      find.text('profile:Илья|true'),
      findsOneWidget,
      reason: 'переключение уже долетело — тест ничего не проверяет',
    );

    showScreen.value = false;
    await tester.pump();
    _expectOperationStillInFlight(api, showScreen);

    api.gate!.complete();
    await _wait(
      tester,
      () => find.text('profile:Илья|false').evaluate().isNotEmpty,
    );

    expect(
      find.text('profile:Илья|false'),
      findsOneWidget,
      reason:
          'сервер принял значение, а кэш профиля остался со старым: '
          'долетевший invalidate упирался в мёртвый ref, и его ловил catch',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'долетевший POST не должен трогать ref/context после dispose',
    );
  });

  testWidgets('сохранить имя и закрыть экран — новое имя доживает', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(460, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _FakeApi();
    final showScreen = await _pumpSettings(tester, api);

    final tile = _tile(_nameTile);
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final field = find.byType(TextField);
    expect(field, findsOneWidget, reason: 'диалог «Изменить имя» не открылся');
    await tester.enterText(field, 'Мийа');
    await tester.pump();

    api.gate = Completer<void>();
    await tester.tap(find.text('Сохранить'));
    await tester.pump();

    showScreen.value = false;
    await tester.pump();
    _expectOperationStillInFlight(api, showScreen);

    api.gate!.complete();
    await _wait(
      tester,
      () => find.text('profile:Мийа|true').evaluate().isNotEmpty,
    );
    expect(
      find.text('profile:Мийа|true'),
      findsOneWidget,
      reason:
          'имя сохранилось на сервере, но кэш не перезагрузился: до правки '
          'бросок от мёртвого ref ловил catch (e), и успех выглядел как «Ошибка: …»',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('переключение без сети — человек видит причину', (tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _FakeApi()..failWith = const SocketException('нет сети');
    await _pumpSettings(tester, api);

    final tile = await _scrollToTile(tester, _quietTile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.textContaining('Не удалось изменить'),
      findsOneWidget,
      reason:
          'раньше здесь был catch (_) {} — тап не давал ни изменения, ни слова',
    );
    expect(
      find.textContaining('Нет соединения с сервером'),
      findsOneWidget,
      reason: 'причину называет friendlyError, а не дамп SocketException',
    );
    expect(
      find.text('profile:Илья|true'),
      findsOneWidget,
      reason: 'на провале значение не должно меняться',
    );
    expect(tester.takeException(), isNull);
  });
}
