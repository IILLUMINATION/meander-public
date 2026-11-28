import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_core/utils/bounded_image_provider.dart';
import 'package:mnd_player/providers/game_screen_provider.dart';
import 'package:mnd_player/providers/game_state_provider.dart';
import 'package:mnd_player/providers/quest_provider.dart';
import 'package:mnd_player/screens/game_screen.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:mnd_player/widgets/content_display_factory.dart';
import 'package:mnd_player/widgets/shared/quest_inline_image.dart';

const _questId = 'inline-image-quest';
const _imagePath = 'res/images/attack.png';
const _replacementPath = 'res/images/replacement.png';
const _remountImagePath = 'res/images/remount.png';
const _tallImagePath = 'res/images/tall.png';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFklEQVR42mO4o2EDR3IVz+CIYWhJAAD+t1eBlf3/1wAAAABJRU5ErkJggg==';
const _tallPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAICAYAAADeM14FAAAAEklEQVR4nGPYomHzHxkzDIwAALW3QuFtqw/LAAAAAElFTkSuQmCC';

final _screenKey = (questId: _questId, docKey: 'standalone');

class _TestGameScreenNotifier extends GameScreenNotifier {
  _TestGameScreenNotifier(Ref ref, String questId)
    : super(ref, questId, sessionKey: '$questId::standalone');

  void emit(GameScreenState next) => state = next;
}

Future<bool> _neverStart() async => false;

late Directory _appDir;

Future<void> _settleImages(WidgetTester tester, {Object? previousImage}) async {
  // File I/O и декодирование идут вне fake-clock, поэтому pumpAndSettle их не ждёт.
  for (var i = 0; i < 100; i++) {
    await tester.pump();
    if (find.byIcon(Icons.broken_image_outlined).evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
    final images = tester.allRenderObjects.whereType<RenderImage>();
    final decoded =
        images.isNotEmpty && images.every((image) => image.image != null);
    final replaced =
        previousImage == null ||
        images.any((image) => !identical(image.image, previousImage));
    if (decoded && replaced) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

ContentItem _textItem(String text, {Color? outlineColor}) => ContentItem(
  id: 'text-1',
  type: 'text',
  text: text,
  textSize: 24,
  textOutlineColor: outlineColor,
);

Future<void> _renderText(
  WidgetTester tester,
  String text, {
  String textFit = 'wrap',
  Color? outlineColor,
  Key? boundaryKey,
}) async {
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer()..listen(gameStateProvider, (_, __) {});
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 400,
                child: TextItemWidget(
                  item: _textItem(text, outlineColor: outlineColor),
                  questId: _questId,
                  onNavigateToNode: (_) {},
                  textFit: textFit,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settleImages(tester);
}

Future<void> _renderButton(
  WidgetTester tester,
  String text, {
  ButtonStyleConfig? styleConfig,
}) async {
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer()..listen(gameStateProvider, (_, __) {});
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassButton(
              onPressed: () {},
              text: text,
              wrapText: false,
              questId: _questId,
              styleConfig:
                  styleConfig ??
                  const ButtonStyleConfig(
                    moduleSize: 12,
                    horizontalModules: 2,
                    centerModules: 4,
                    paddingH: 4,
                    textSize: 20,
                  ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settleImages(tester);
}

List<FontWeight?> _imageAncestorWeights(WidgetTester tester) {
  final result = <FontWeight?>[];
  void walk(InlineSpan span, FontWeight? inherited) {
    if (span is WidgetSpan) {
      result.add(inherited);
      return;
    }
    if (span is! TextSpan) return;
    final weight = span.style?.fontWeight ?? inherited;
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, weight);
    }
  }

  for (final widget in tester.allWidgets.whereType<RichText>()) {
    walk(widget.text, null);
  }
  return result;
}

List<FontWeight?> _weightsForText(WidgetTester tester, String needle) {
  final result = <FontWeight?>[];
  void walk(InlineSpan span, FontWeight? inherited) {
    if (span is! TextSpan) return;
    final weight = span.style?.fontWeight ?? inherited;
    if ((span.text ?? '').contains(needle)) result.add(weight);
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, weight);
    }
  }

  for (final widget in tester.allWidgets.whereType<RichText>()) {
    walk(widget.text, null);
  }
  return result;
}

List<String> _drawnTexts(WidgetTester tester) => [
  for (final widget in tester.allWidgets.whereType<RichText>())
    widget.text.toPlainText(),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _appDir = await Directory.systemTemp.createTemp('mnd_inline_image_test');
    FileStorage.overrideAppDirectory(_appDir);
    QuestImageSource.invalidate();
    final file = File('${_appDir.path}/quests/$_questId/$_imagePath');
    await file.parent.create(recursive: true);
    final bytes = base64Decode(_png);
    await file.writeAsBytes(bytes);
    final tall = File('${_appDir.path}/quests/$_questId/$_tallImagePath');
    await tall.writeAsBytes(base64Decode(_tallPng));
    final replacement = File(
      '${_appDir.path}/quests/$_questId/$_replacementPath',
    );
    await replacement.writeAsBytes(bytes);
    final remount = File('${_appDir.path}/quests/$_questId/$_remountImagePath');
    await remount.writeAsBytes(bytes);
  });

  tearDownAll(() async {
    FileStorage.overrideAppDirectory(null);
    QuestImageSource.invalidate();
    if (_appDir.existsSync()) await _appDir.delete(recursive: true);
  });

  testWidgets('markdown рисует валидный тег и оставляет битый буквальным', (
    tester,
  ) async {
    await _renderText(tester, 'Атака [img=$_imagePath] [img=../secret.png]');

    final images = tester.allWidgets.whereType<QuestInlineImage>().toList();
    expect(images, hasLength(1));
    expect(images.single.path, _imagePath);
    expect(images.single.outlineOnly, isFalse);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.getSize(find.byType(Image)).width, closeTo(32.4, 0.01));
    expect(_drawnTexts(tester), anyElement(contains('[img=../secret.png]')));
  });

  testWidgets('markdown сохраняет жирный фрагмент вокруг картинки', (
    tester,
  ) async {
    await _renderText(tester, '**Атака [img=$_imagePath]**');

    expect(find.byType(QuestInlineImage), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(_drawnTexts(tester), everyElement(isNot(contains('**'))));
  });

  testWidgets('markdown оставляет тег картинки внутри кода буквальным', (
    tester,
  ) async {
    await _renderText(tester, '`[img=$_imagePath]`');

    expect(find.byType(QuestInlineImage), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(_drawnTexts(tester), anyElement(contains('[img=$_imagePath]')));
  });

  testWidgets('scale-режим оставляет тег картинки внутри кода буквальным', (
    tester,
  ) async {
    await _renderText(tester, '`[img=$_imagePath]`', textFit: 'scale');

    expect(find.byType(QuestInlineImage), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(_drawnTexts(tester), anyElement(contains('[img=$_imagePath]')));
  });

  testWidgets('scale-режим учитывает многострочный инлайн-код', (tester) async {
    await _renderText(
      tester,
      '`строка\n[img=$_imagePath]\nещё` [img=$_imagePath]',
      textFit: 'scale',
    );

    expect(find.byType(QuestInlineImage), findsOneWidget);
    expect(_drawnTexts(tester), anyElement(contains('[img=$_imagePath]')));
  });

  testWidgets('подпись кнопки оставляет тег картинки внутри кода буквальным', (
    tester,
  ) async {
    await _renderButton(tester, '`[img=$_imagePath]`');

    expect(find.byType(QuestInlineImage), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(_drawnTexts(tester), anyElement(contains('[img=$_imagePath]')));
  });

  testWidgets('подпись кнопки учитывает многострочный инлайн-код', (
    tester,
  ) async {
    await _renderButton(
      tester,
      '`строка\n[img=$_imagePath]\nещё` [img=$_imagePath]',
    );

    expect(find.byType(QuestInlineImage), findsOneWidget);
    expect(_drawnTexts(tester), anyElement(contains('[img=$_imagePath]')));
  });

  testWidgets('scale-режим сохраняет жирность вокруг картинки', (tester) async {
    await _renderText(tester, '**Атака [img=$_imagePath]**', textFit: 'scale');

    expect(find.byType(QuestInlineImage), findsOneWidget);
    expect(_imageAncestorWeights(tester), contains(FontWeight.w900));
    expect(_drawnTexts(tester), everyElement(isNot(contains('**'))));
  });

  testWidgets('подпись кнопки рисует картинку внутри жирного фрагмента', (
    tester,
  ) async {
    await _renderButton(tester, '**Атака [img=$_imagePath]**');

    expect(find.byType(QuestInlineImage), findsOneWidget);
    expect(_imageAncestorWeights(tester), contains(FontWeight.w900));
    expect(_drawnTexts(tester), everyElement(isNot(contains('**'))));
  });

  testWidgets('жирность кнопки переопределяет заданный textWeight', (
    tester,
  ) async {
    const config = ButtonStyleConfig(
      moduleSize: 12,
      horizontalModules: 2,
      centerModules: 4,
      paddingH: 4,
      textSize: 20,
      textWeight: 400,
    );
    await _renderButton(
      tester,
      '**Атака [img=$_imagePath]**',
      styleConfig: config,
    );

    expect(_weightsForText(tester, 'Атака'), contains(FontWeight.w900));
    expect(_imageAncestorWeights(tester), contains(FontWeight.w900));
  });

  testWidgets('обводка добавляет прозрачный слот, а не вторую картинку', (
    tester,
  ) async {
    const boundaryKey = ValueKey('inline-image-outline');
    await _renderText(
      tester,
      'Атака [img=$_imagePath]',
      outlineColor: Colors.red,
      boundaryKey: boundaryKey,
    );

    final images = tester.allWidgets.whereType<QuestInlineImage>().toList();
    expect(images, hasLength(2));
    expect(images.where((image) => image.outlineOnly), hasLength(1));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(
      tester.allRenderObjects.whereType<RenderImage>().single.image,
      isNotNull,
    );
    for (final image in images) {
      expect(tester.getSize(find.byWidget(image)).width, closeTo(32.4, 0.01));
    }
    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile('goldens/inline_image_render.png'),
    );
  });

  testWidgets('отсутствующий файл держит размер строки и показывает ошибку', (
    tester,
  ) async {
    await _renderText(tester, 'Атака [img=res/images/missing.png]');

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(
      tester.getSize(find.byType(QuestInlineImage)).width,
      closeTo(32.4, 0.01),
    );
  });

  testWidgets('добавленный после ошибки файл появляется после invalidate', (
    tester,
  ) async {
    const path = 'res/images/added-later.png';
    await _renderText(tester, 'Атака [img=$path]');
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);

    final file = File('${_appDir.path}/quests/$_questId/$path');
    await tester.runAsync(() => file.writeAsBytes(base64Decode(_png)));
    QuestImageSource.invalidate();
    tester.element(find.byType(QuestInlineImage)).markNeedsBuild();
    await tester.pump();
    await _settleImages(tester);

    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('инвалидация резолвера не убирает уже нарисованную картинку', (
    tester,
  ) async {
    await _renderText(tester, 'Атака [img=$_imagePath]');
    final before = tester.allRenderObjects
        .whereType<RenderImage>()
        .single
        .image;
    final beforeImage = before;
    if (beforeImage == null) fail('Первый декод не завершился');

    QuestImageSource.invalidate();
    tester.element(find.byType(TextItemWidget)).markNeedsBuild();
    await tester.pump();

    final during = tester.allRenderObjects.whereType<RenderImage>();
    expect(during, hasLength(1));
    expect(during.single.image, same(beforeImage));

    await _settleImages(tester);
    final after = tester.allRenderObjects.whereType<RenderImage>().single.image;
    expect(after, isNotNull);
  });

  testWidgets('повторный mount сразу берёт картинку из кэша', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    final imageWidget = MaterialApp(
      home: Scaffold(
        body: Center(
          child: QuestInlineImage(questId: _questId, path: _remountImagePath),
        ),
      ),
    );
    await tester.pumpWidget(imageWidget);
    await _settleImages(tester);
    final before = tester.allRenderObjects
        .whereType<RenderImage>()
        .single
        .image;
    expect(before, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    QuestImageSource.invalidate();
    await tester.pumpWidget(imageWidget);
    await tester.pump();

    final after = tester.allRenderObjects.whereType<RenderImage>();
    expect(after, hasLength(1));
    expect(after.single.image, isNotNull);
    expect(after.single.image!.width, before!.width);
    expect(after.single.image!.height, before.height);
    await _settleImages(tester, previousImage: before);
  });

  testWidgets('live-reload той же ноды сохраняет элемент inline-картинки', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previousMessagesHandler = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) {
      if (channel.startsWith('xyz.luan/audioplayers')) {
        return Future<ByteData?>.value(
          const StandardMethodCodec().encodeSuccessEnvelope(null),
        );
      }
      return previousMessagesHandler?.call(channel, handler, message) ??
          messenger.delegate.send(channel, message);
    };
    addTearDown(() {
      messenger.allMessagesHandler = previousMessagesHandler;
    });
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        gameScreenProvider(
          _screenKey,
        ).overrideWith((ref) => _TestGameScreenNotifier(ref, _questId)),
        questProvider(
          _questId,
        ).overrideWith((ref) => Quest(id: _questId, title: 'Inline')),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: GameScreen(
            questId: _questId,
            preflight: _neverStart,
            isTesting: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final notifier =
        container.read(gameScreenProvider(_screenKey).notifier)
            as _TestGameScreenNotifier;
    final item = _textItem('Атака [img=$_imagePath]');
    final initial = GameScreenState(
      isLoading: false,
      currentNode: SavedNode(
        id: 'node-1',
        chapterId: 'chapter-1',
        title: 'Inline',
        content: const {'items': <dynamic>[]},
      ),
      revealedItems: [item],
      presentationId: 'presentation-1',
    );
    notifier.emit(initial);
    await tester.pump();
    await _settleImages(tester);

    final imageFinder = find.byType(QuestInlineImage);
    final elementBefore = tester.element(imageFinder);
    final imageBefore = tester.allRenderObjects
        .whereType<RenderImage>()
        .single
        .image;
    expect(imageBefore, isNotNull);

    QuestImageSource.invalidate();
    notifier.emit(initial.copyWith(revealEpoch: 1));
    await tester.pump();

    expect(tester.element(imageFinder), same(elementBefore));
    final during = tester.allRenderObjects.whereType<RenderImage>();
    expect(during, hasLength(1));
    expect(during.single.image, same(imageBefore));

    await _settleImages(tester, previousImage: imageBefore);
  });

  testWidgets('замена файла по тому же пути сбрасывает декодированный кэш', (
    tester,
  ) async {
    await _renderText(tester, 'Атака [img=$_replacementPath]');
    final before = tester.allRenderObjects
        .whereType<RenderImage>()
        .single
        .image;
    final beforeImage = before;
    if (beforeImage == null) fail('Первый декод не завершился');

    final file = File('${_appDir.path}/quests/$_questId/$_replacementPath');
    await tester.runAsync(() => file.writeAsBytes(base64Decode(_tallPng)));
    QuestImageSource.invalidate();
    tester.element(find.byType(QuestInlineImage)).markNeedsBuild();
    await tester.pump();
    await _settleImages(tester, previousImage: beforeImage);

    final after = tester.allRenderObjects.whereType<RenderImage>().single.image;
    final afterImage = after;
    if (afterImage == null) fail('Повторный декод не завершился');
    expect(afterImage, isNot(same(beforeImage)));
    expect(afterImage.width, lessThan(beforeImage.width));
    expect(afterImage.height, beforeImage.height);
  });

  testWidgets('нулевой размер текста не даёт нулевой decode', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: QuestInlineImage(
              questId: _questId,
              path: _imagePath,
              style: const TextStyle(fontSize: 0),
            ),
          ),
        ),
      ),
    );
    await _settleImages(tester);

    expect(tester.takeException(), isNull);
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<BoundedImageProvider>());
    expect((provider as BoundedImageProvider).maxSide, 1);
    expect(tester.getSize(find.byType(Image)).width, 1.0);
  });

  testWidgets('bounded decode сохраняет пропорции высокого изображения', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: QuestInlineImage(
              questId: _questId,
              path: _tallImagePath,
              style: const TextStyle(fontSize: 2, height: 1),
            ),
          ),
        ),
      ),
    );
    await _settleImages(tester);

    expect(tester.takeException(), isNull);
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<BoundedImageProvider>());
    expect((provider as BoundedImageProvider).maxSide, 2);
    expect(tester.getSize(find.byType(Image)), const Size.square(2));
    final decoded = tester.allRenderObjects
        .whereType<RenderImage>()
        .single
        .image;
    expect(decoded, isNotNull);
    expect(decoded!.width, 1);
    expect(decoded.height, 2);
  });

  testWidgets('минимальный бокс не обнуляет узкую сторону изображения', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: QuestInlineImage(
              questId: _questId,
              path: _tallImagePath,
              style: const TextStyle(fontSize: 1, height: 1),
            ),
          ),
        ),
      ),
    );
    await _settleImages(tester);

    expect(tester.takeException(), isNull);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<BoundedImageProvider>());
    expect((image.image as BoundedImageProvider).maxSide, 1);
    final decoded = tester.allRenderObjects
        .whereType<RenderImage>()
        .single
        .image;
    expect(decoded, isNotNull);
    expect(decoded!.width, 1);
    expect(decoded.height, 1);
  });

  testWidgets('module-кнопка замеряет картинку как отдельный слот', (
    tester,
  ) async {
    const config = ButtonStyleConfig(
      moduleSize: 12,
      horizontalModules: 2,
      verticalModules: 2,
      centerModules: 4,
      paddingH: 4,
      paddingV: 4,
      textSize: 20,
      cornerAsset: _imagePath,
      hAsset: _imagePath,
      vAsset: _imagePath,
      centerAsset: _imagePath,
    );
    await _renderButton(tester, 'AAAA', styleConfig: config);
    final plainWidth = tester.getSize(find.byType(GlassButton)).width;

    await _renderButton(tester, 'AAAA [img=$_imagePath]', styleConfig: config);
    final imageWidth = tester.getSize(find.byType(GlassButton)).width;

    expect(imageWidth, greaterThan(plainWidth + 20));
    final imageFinder = find.byType(QuestInlineImage);
    final image = tester.widget<QuestInlineImage>(imageFinder);
    final inherited = DefaultTextStyle.of(tester.element(imageFinder)).style;
    final expectedSide = QuestInlineImage.sideForStyle(
      inherited.merge(image.style),
    );
    expect(tester.getSize(imageFinder).width, closeTo(expectedSide, 0.01));
  });

  testWidgets('длина пути не раздувает автоцентрирование кнопки', (
    tester,
  ) async {
    await _renderButton(tester, 'A [img=a.png]');
    final short = tester.getSize(find.byType(GlassButton)).width;

    final longPath = 'res/images/${'x' * 160}.png';
    await _renderButton(tester, 'A [img=$longPath]');
    final long = tester.getSize(find.byType(GlassButton)).width;

    expect(long, closeTo(short, 0.5));
  });
}
