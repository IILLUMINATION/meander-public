import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/content_item.dart';
import 'package:mnd_core/utils/bounded_image_provider.dart';
import 'package:mnd_web_player/item_view.dart';
import 'package:mnd_web_player/player.dart';
import 'package:mnd_web_player/quest_bundle.dart';
import 'package:mnd_web_player/quest_source.dart';

const _questId = 'inline-image-quest';
const _imagePath = 'res/images/attack.png';
const _tallImagePath = 'res/images/tall.png';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ'
    '/pLvAAAAAElFTkSuQmCC';
const _tallPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAICAYAAADeM14FAAAAEklEQVR4nGPYomHzHxkzDIwAALW3QuFtqw/LAAAAAElFTkSuQmCC';

final _pngBytes = Uint8List.fromList(base64Decode(_png));
final _tallPngBytes = Uint8List.fromList(base64Decode(_tallPng));

QuestBundle _bundle({Map<String, Uint8List> assets = const {}}) => QuestBundle(
  questId: _questId,
  config: const {'id': _questId, 'title': 'Картинки', 'startNodeId': 'n1'},
  nodesJson: const {
    'nodes': [
      {'id': 'n1', 'content': []},
    ],
    'groups': [],
  },
  templates: const [],
  embeddedScripts: const {},
  assets: assets,
);

class _MutableAssets extends QuestAssets {
  final _assets = <String, Uint8List>{};

  void add(String path, Uint8List bytes) {
    _assets[path] = bytes;
    notifyListeners();
  }

  @override
  String get questId => _questId;

  @override
  Map<String, dynamic> get config => const {'id': _questId};

  @override
  Map<String, dynamic> get nodesJson => const {'nodes': []};

  @override
  List<dynamic> get templates => const [];

  @override
  Map<String, String> get embeddedScripts => const {};

  @override
  Map<String, Uint8List> get assets => _assets;

  @override
  List<String> get fontPaths => const [];

  @override
  bool get hasScripts => false;

  @override
  Uint8List? assetBytes(String? source) => _assets[source?.trim()];
}

ContentItem _textItem(
  String text, {
  Color? outlineColor,
  String textReveal = 'none',
  double revealSpeed = 40,
}) => ContentItem(
  id: 'text-1',
  type: 'text',
  text: text,
  textSize: 24,
  textOutlineColor: outlineColor,
  textReveal: textReveal,
  revealSpeed: revealSpeed,
);

Future<QuestPlayer> _renderText(
  WidgetTester tester,
  QuestAssets assets,
  String text, {
  Color? outlineColor,
  String textReveal = 'none',
  double revealSpeed = 40,
}) async {
  final player = QuestPlayer(assets);
  addTearDown(() {
    player.dispose();
    assets.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ItemView(
              player: player,
              item: _textItem(
                text,
                outlineColor: outlineColor,
                textReveal: textReveal,
                revealSpeed: revealSpeed,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return player;
}

List<String> _textsWithWeight(WidgetTester tester, FontWeight weight) {
  final result = <String>[];
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.style?.fontWeight == weight && span.text != null) {
      result.add(span.text!);
    }
    span.children?.forEach(walk);
  }

  for (final widget in tester.allWidgets.whereType<RichText>()) {
    walk(widget.text);
  }
  return result;
}

int _widgetSpanCount(WidgetTester tester) {
  var count = 0;
  void walk(InlineSpan span) {
    if (span is WidgetSpan) count++;
    if (span is TextSpan) span.children?.forEach(walk);
  }

  for (final widget in tester.allWidgets.whereType<RichText>()) {
    walk(widget.text);
  }
  return count;
}

List<String> _drawnTexts(WidgetTester tester) => [
  for (final widget in tester.allWidgets.whereType<RichText>())
    widget.text.toPlainText(),
];

void main() {
  testWidgets('валидный тег рисует ресурс, а небезопасный остаётся текстом', (
    tester,
  ) async {
    await _renderText(
      tester,
      _bundle(assets: {_imagePath: _pngBytes}),
      'Атака [img=$_imagePath] [img=../secret.png]',
    );

    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<BoundedImageProvider>());
    final bounded = provider as BoundedImageProvider;
    expect(bounded.imageProvider, isA<MemoryImage>());
    expect(
      (bounded.imageProvider as MemoryImage).bytes,
      orderedEquals(_pngBytes),
    );
    expect(bounded.maxSide, isPositive);
    expect(tester.getSize(find.byType(Image)).width, closeTo(32.4, 0.01));
    expect(_drawnTexts(tester), anyElement(contains('[img=../secret.png]')));
    expect(
      _drawnTexts(tester),
      everyElement(isNot(contains('[img=$_imagePath]'))),
    );
  });

  testWidgets('картинка внутри жирного фрагмента сохраняет жирность', (
    tester,
  ) async {
    await _renderText(
      tester,
      _bundle(assets: {_imagePath: _pngBytes}),
      '**Атака [img=$_imagePath]**',
    );

    expect(find.byType(Image), findsOneWidget);
    expect(_textsWithWeight(tester, FontWeight.bold), contains('Атака '));
    expect(_drawnTexts(tester), everyElement(isNot(contains('**'))));
  });

  testWidgets('многострочный код оставляет тег буквальным', (tester) async {
    await _renderText(
      tester,
      _bundle(assets: {_imagePath: _pngBytes}),
      '`строка\n[img=$_imagePath]\nещё` [img=$_imagePath]',
    );

    expect(find.byType(Image), findsOneWidget);
    expect(_drawnTexts(tester), anyElement(contains('[img=$_imagePath]')));
  });

  testWidgets('экранированная скобка оставляет тег буквальным', (tester) async {
    await _renderText(
      tester,
      _bundle(assets: {_imagePath: _pngBytes}),
      r'\[img=res/images/literal.png] [img=res/images/attack.png]',
    );

    expect(find.byType(Image), findsOneWidget);
    expect(
      _drawnTexts(tester),
      anyElement(contains('[img=res/images/literal.png]')),
    );
  });

  testWidgets('обводка добавляет прозрачный слот без второй картинки', (
    tester,
  ) async {
    await _renderText(
      tester,
      _bundle(assets: {_imagePath: _pngBytes}),
      'Атака [img=$_imagePath]',
      outlineColor: Colors.red,
    );

    expect(_widgetSpanCount(tester), 2);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.getSize(find.byType(Image)).width, closeTo(32.4, 0.01));
  });

  testWidgets('отсутствующий файл держит размер строки и показывает ошибку', (
    tester,
  ) async {
    await _renderText(tester, _bundle(), 'Атака [img=$_imagePath]');

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(
      tester.getSize(find.byIcon(Icons.broken_image_outlined)).width,
      closeTo(32.4, 0.01),
    );
  });

  testWidgets('потоковый ресурс появляется после уведомления источника', (
    tester,
  ) async {
    final assets = _MutableAssets();
    await _renderText(tester, assets, 'Атака [img=$_imagePath]');
    expect(find.byType(Image), findsNothing);

    assets.add(_imagePath, _pngBytes);
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
  });

  testWidgets('нулевой размер текста не даёт нулевой decode', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    final assets = _bundle(assets: {_imagePath: _pngBytes});
    final player = QuestPlayer(assets);
    addTearDown(() {
      player.dispose();
      assets.dispose();
    });
    final span = buildInlineSpan(
      '[img=$_imagePath]',
      const TextStyle(fontSize: 0),
      player: player,
    );
    final child = ((span as TextSpan).children!.single as WidgetSpan).child;
    await tester.pumpWidget(MaterialApp(home: Center(child: child)));

    expect(tester.takeException(), isNull);
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<BoundedImageProvider>());
    expect((provider as BoundedImageProvider).maxSide, 1);
  });

  testWidgets('bounded decode сохраняет пропорции высокого изображения', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    final assets = _bundle(assets: {_tallImagePath: _tallPngBytes});
    final player = QuestPlayer(assets);
    addTearDown(() {
      player.dispose();
      assets.dispose();
    });
    final span = buildInlineSpan(
      '[img=$_tallImagePath]',
      const TextStyle(fontSize: 2, height: 1),
      player: player,
    );
    final child = ((span as TextSpan).children!.single as WidgetSpan).child;
    await tester.pumpWidget(MaterialApp(home: Center(child: child)));

    expect(tester.takeException(), isNull);
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<BoundedImageProvider>());
    expect((provider as BoundedImageProvider).maxSide, 2);
    expect(tester.getSize(find.byType(Image)), const Size.square(2));
  });

  testWidgets('печатная машинка показывает картинку после первого символа', (
    tester,
  ) async {
    await _renderText(
      tester,
      _bundle(assets: {_imagePath: _pngBytes}),
      'А[img=$_imagePath]Б',
      textReveal: 'typewriter',
      revealSpeed: 4,
    );
    expect(find.byType(Image), findsNothing);

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(Image), findsOneWidget);
    expect(_drawnTexts(tester), everyElement(isNot(contains('Б'))));

    await tester.pump(const Duration(milliseconds: 250));
    expect(_drawnTexts(tester), anyElement(contains('Б')));
  });

  testWidgets('печатная машинка не превращает тег внутри кода в картинку', (
    tester,
  ) async {
    const tag = '[img=$_imagePath]';
    await _renderText(
      tester,
      _bundle(assets: {_imagePath: _pngBytes}),
      'A`$tag`Б',
      textReveal: 'typewriter',
      revealSpeed: 4,
    );

    await tester.pump(const Duration(milliseconds: 7200));
    expect(find.byType(Image), findsNothing);
    expect(_drawnTexts(tester), anyElement(contains(tag)));
    expect(
      _drawnTexts(tester),
      everyElement((String text) => '`'.allMatches(text).length % 2 == 0),
    );

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byType(Image), findsNothing);
    expect(_drawnTexts(tester), anyElement(contains('A$tagБ')));
  });
}
