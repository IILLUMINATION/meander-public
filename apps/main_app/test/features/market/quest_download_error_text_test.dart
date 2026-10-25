// Скачивание квеста — самое первое действие новичка в «Маркете», и оно же
// самое частое, что падает: нет сети, DNS не резолвится, файл сняли с
// публикации. Экран печатает причину из состояния загрузки как есть, поэтому
// гость без интернета читал в снэкбаре «Ошибка: SocketException: Failed host
// lookup: … (OS Error: …, errno = -2)».
//
// НЕГАТИВНЫЙ КОНТРОЛЬ: верни в нотифаере `error: e.toString()` — падает
// последний тест: в состояние возвращается префикс класса («HttpException: …»).

import 'dart:io';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/features/market/providers/market_download_provider.dart';
import 'package:canvas_app/models/market_quest_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Сервер в этих тестах не нужен: регистрация скачивания проглатывается
/// нотифаером, а падает сам HTTP-клиент Flutter-песочницы.
class _SilentApi extends ApiService {
  @override
  Future<dynamic> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async => {};

  @override
  Future<dynamic> post(String endpoint, {Map<String, dynamic>? body}) async =>
      {};
}

MarketQuest _quest() => MarketQuest(
  id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  title: 'Тихий дом',
  downloadUrl: 'https://backend.example.invalid/quests/aaaa.mnd',
  downloadsCount: 3,
  likeCount: 1,
  dislikeCount: 0,
  averageRating: 4.5,
  version: '1.0.0',
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('причина отказа от скачивания', () {
    test('обрыв сети — одна фраза, а не дамп с errno', () {
      // Человек без интернета должен видеть «нет связи», а не стек-трейс:
      // «попробовать снова» тут бессмысленно до тех пор, пока связь не
      // появится, и приложение не сломано.
      expect(
        questDownloadErrorText(
          const SocketException('Failed host lookup: backend.example.invalid'),
        ),
        'Нет соединения с сервером',
      );
      expect(
        questDownloadErrorText(
          Exception('TimeoutException after 0:00:300.000000: not completed'),
        ),
        'Нет соединения с сервером',
      );
    });

    test('сервер отвечает по коду — понятная фраза по коду', () {
      // Коды `HttpException` приходят из `/quests/:id/file`: 404 — файл сняли,
      // 403 — публикация закрыта. Человек должен понять разницу без трейса.
      expect(
        questDownloadErrorText(const HttpException('HTTP 404: Not Found')),
        'Квеста больше нет на сервере',
      );
      expect(
        questDownloadErrorText(const HttpException('HTTP 403: Forbidden')),
        'Сервер не отдаёт этот квест',
      );
      expect(
        questDownloadErrorText(const HttpException('HTTP 500: Server Error')),
        'Сервер не отдал квест (код 500)',
      );
    });

    test('прочие причины остаются фразой без префикса класса', () {
      // `Exception.toString()` печатает «Exception: » — это то, что раньше
      // и попадало в снэкбар.
      expect(
        questDownloadErrorText(Exception('Не удалось скачать файл')),
        'Не удалось скачать файл',
      );
    });
  });

  group('состояние загрузки', () {
    late Directory appDir;

    setUpAll(() async {
      appDir = await Directory.systemTemp.createTemp('mnd_market_dl_test');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getTemporaryDirectory' ||
                call.method == 'getApplicationDocumentsDirectory') {
              return appDir.path;
            }
            return null;
          });
    });

    setUp(() => SharedPreferences.setMockInitialValues({}));

    tearDownAll(() async {
      if (appDir.existsSync()) await appDir.delete(recursive: true);
    });

    /// Прогоняет загрузку до отказа и возвращает текст причины.
    Future<String?> runUntilFailure(MarketQuest quest) async {
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(_SilentApi())],
      );
      addTearDown(container.dispose);
      await container
          .read(marketDownloadProvider.notifier)
          .startDownload(quest: quest, token: '');

      for (var i = 0; i < 80; i++) {
        final state = container.read(marketDownloadProvider)[quest.id];
        if (state?.hasFailed ?? false) return state?.error;
        if (state?.isCompleted ?? false) return null;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw StateError(
        'загрузка не завершилась за 2 с: '
        '${container.read(marketDownloadProvider)[quest.id]}',
      );
    }

    test('неудача хранит одну человеческую строку', () async {
      final error = await runUntilFailure(_quest());

      // HTTP-клиент песочницы отвечает 400 — важно не то, какая это код-фраза,
      // а что в состоянии не остаётся трейса: экран печатает его в снэкбаре.
      expect(error, isNotNull);
      expect(error, isNot(contains('\n')));
      expect(error, isNot(contains('Exception')));
      expect(error, isNot(contains('OS Error')));
      expect(error, isNot(contains('errno')));
      expect(error!.length, lessThanOrEqualTo(120));
    });
  });
}
