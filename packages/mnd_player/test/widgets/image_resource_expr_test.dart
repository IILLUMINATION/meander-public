// Рантайм: картинка берёт путь из формулы-источника (`{pic}`, `res/{level}.png`)
// и перезагружается, когда скрипт меняет переменные. Проверяется и откат на
// статический resourcePath при пустом значении — сцена не должна оставаться
// без картинки. Плюс канал `set_image`: движок назначает айтему источник
// напрямую, и это перебивает и формулу, и файл из ноды.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/widgets/content_display_factory.dart'
    show ImageItemWidget;

/// Формулы подставляет Rust-ядро, поэтому этим тестам нужен собранный `.so`
/// (как в `packages/mnd_core/test/engine/brace_collapse_test.dart`).
final String? _soPath = () {
  final env = Platform.environment['MND_FFI_SO'];
  if (env != null && File(env).existsSync()) return env;
  for (final candidate in [
    '../../target/release/libmnd_ffi.so',
    '../../crates/mnd-ffi/target/release/libmnd_ffi.so',
  ]) {
    if (File(candidate).existsSync()) return File(candidate).absolute.path;
  }
  return null;
}();

/// Валидный 1×1 PNG — `Image.file` в тесте реально декодирует файл.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ'
    '/pLvAAAAAElFTkSuQmCC';

void main() {
  late Directory appDir;

  setUpAll(() async {
    if (_soPath != null) {
      await initRustCore(externalLibrary: ExternalLibrary.open(_soPath!));
    }
    appDir = await Directory.systemTemp.createTemp('mnd_image_expr_test');
    final dir = Directory('${appDir.path}/quests/q1/res/images')
      ..createSync(recursive: true);
    File('${dir.path}/a.png').writeAsBytesSync(base64Decode(_png));
    File('${dir.path}/b.png').writeAsBytesSync(base64Decode(_png));
    // Библиотека ресурсов: у b.png есть имя, по которому его ищем.
    File('${appDir.path}/quests/q1/res/metadata.json').writeAsStringSync(
      jsonEncode({
        'b.png': {'name': 'закат', 'folder': '/картинки'},
      }),
    );
  });

  tearDownAll(() async {
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  /// Мок ставим внутри теста: `FileStorage` кэширует каталог приложения, и
  /// первый же вызов без обработчика залипает ошибкой на весь процесс.
  void stubPathProvider() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? appDir.path
              : null,
        );
  }

  String paintedFile(WidgetTester tester) {
    // Картинка узла декодируется под экран, поэтому файл лежит под
    // `ResizeImage` — тест проверяет именно выбранный файл, а обёртка для
    // декода здесь не предмет проверки.
    ImageProvider provider = tester.widget<Image>(find.byType(Image).first).image;
    while (provider is ResizeImage) {
      provider = provider.imageProvider;
    }
    expect(provider, isA<FileImage>());
    return (provider as FileImage).file.path;
  }

  ContentItem image({String? path, String? expr}) => ContentItem(
    id: 'img',
    type: 'image',
    resourcePath: path,
    resourceExpr: expr,
  );

  /// Реальный I/O (поиск файла + `exists`) не крутится в fake-async зоне
  /// теста, поэтому кадры прокручиваем внутри `runAsync` — как в
  /// `node_flip_transition_test.dart`. Первую `metadata.json` диск отдаёт
  /// медленнее кадра, поэтому ждём именно появления картинки.
  Future<void> settleWithIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.byType(Image).hasFound) return;
    }
  }

  Future<ProviderContainer> render(
    WidgetTester tester,
    ContentItem item,
  ) async {
    final container = ProviderContainer()
      ..listen(gameStateProvider, (_, __) {});
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ImageItemWidget(
              item: item,
              questId: 'q1',
              onInteract: (_) {},
            ),
          ),
        ),
      ),
    );
    await settleWithIo(tester);
    return container;
  }

  testWidgets('без формулы рисуется resourcePath', (tester) async {
    stubPathProvider();

    await render(tester, image(path: 'res/images/a.png'));

    expect(paintedFile(tester), endsWith('res/images/a.png'));
  });

  testWidgets('resourcePath может быть именем из библиотеки ресурсов', (
    tester,
  ) async {
    stubPathProvider();

    await render(tester, image(path: 'закат'));

    expect(paintedFile(tester), endsWith('res/images/b.png'));
  });

  testWidgets('блок set_image меняет картинку', (tester) async {
    stubPathProvider();
    final container = await render(tester, image(path: 'res/images/a.png'));

    // Движок пишет переопределение в служебную переменную — модель не трогаем.
    container.read(gameStateProvider.notifier).setVariable(kItemSourceVar, {
      'img': 'res/images/b.png',
    });
    await settleWithIo(tester);

    expect(paintedFile(tester), endsWith('res/images/b.png'));
  });

  testWidgets('set_image применим столько раз, сколько вызван', (tester) async {
    stubPathProvider();
    final container = await render(tester, image(path: 'res/images/a.png'));

    // Спрайт у «фото» меняют несколько раз за сцену, в том числе обратно на
    // уже показанный файл: каждое переопределение перетирает предыдущее.
    for (final next in [
      'res/images/b.png',
      'res/images/a.png',
      'res/images/b.png',
    ]) {
      container.read(gameStateProvider.notifier).setVariable(kItemSourceVar, {
        'img': next,
      });
      await settleWithIo(tester);
      expect(paintedFile(tester), endsWith(next), reason: next);
    }
  });

  testWidgets('переопределение чужого айтема игнорируется', (tester) async {
    stubPathProvider();
    final container = await render(tester, image(path: 'res/images/a.png'));

    container.read(gameStateProvider.notifier).setVariable(kItemSourceVar, {
      'other': 'res/images/b.png',
    });
    await settleWithIo(tester);

    expect(paintedFile(tester), endsWith('res/images/a.png'));
  });

  testWidgets('set_image важнее формулы-источника', (tester) async {
    stubPathProvider();
    final container = await render(
      tester,
      image(path: 'res/images/a.png', expr: 'res/images/a.png'),
    );

    container.read(gameStateProvider.notifier).setVariable(kItemSourceVar, {
      'img': 'res/images/b.png',
    });
    await settleWithIo(tester);

    expect(paintedFile(tester), endsWith('res/images/b.png'));
  });

  group('формула-источник', () {
    testWidgets('формула `{pic}` меняет картинку на лету', (tester) async {
      stubPathProvider();
      final container = await render(
        tester,
        image(path: 'res/images/a.png', expr: '{pic}'),
      );
      expect(paintedFile(tester), endsWith('res/images/a.png'));

      // Скрипт сделал `pic = res/images/b.png` — второго айтема не нужно.
      container
          .read(gameStateProvider.notifier)
          .setVariable('pic', 'res/images/b.png');
      await settleWithIo(tester);

      expect(paintedFile(tester), endsWith('res/images/b.png'));
    });

    testWidgets('формула склеивает путь из частиц', (tester) async {
      stubPathProvider();
      final container = await render(
        tester,
        image(expr: 'res/images/{pic}.png'),
      );
      container.read(gameStateProvider.notifier).setVariable('pic', 'b');
      await settleWithIo(tester);

      expect(paintedFile(tester), endsWith('res/images/b.png'));
    });

    testWidgets('пустое значение переменной — откат на файл из ноды', (
      tester,
    ) async {
      stubPathProvider();
      final container = await render(
        tester,
        image(path: 'res/images/a.png', expr: '{pic}'),
      );
      container.read(gameStateProvider.notifier).setVariable('pic', '   ');
      await settleWithIo(tester);

      expect(paintedFile(tester), endsWith('res/images/a.png'));
    });

    testWidgets('формула выдаёт имя ресурса, а не путь', (tester) async {
      stubPathProvider();
      final container = await render(
        tester,
        image(path: 'res/images/a.png', expr: '{pic}'),
      );

      container.read(gameStateProvider.notifier).setVariable('pic', 'закат');
      await settleWithIo(tester);

      expect(paintedFile(tester), endsWith('res/images/b.png'));
    });
  }, skip: _soPath == null);
}
