import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/features/resources/models/resource_file.dart';
import 'package:canvas_app/features/resources/screens/markdown_editor_screen.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/features/resources/services/resource_service.dart';
import 'package:canvas_app/features/resources/widgets/inline_image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';

const _questId = 'q-inline-images';
const _attackPath = 'res/images/attack.png';
const _shieldPath = 'res/images/shield.png';
const _attackPng =
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAH0lEQVR42mO44+b2nxLMMGoADQwgBEaCAaPpYAAMAAAyWJm//uFU0QAAAABJRU5ErkJggg==';
const _shieldPng =
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAHUlEQVR42mOwqbjznxLMMIwNQAejBoxMA0ZQXgAAULK8vwF1eucAAAAASUVORK5CYII=';

class _FakeResourceService implements ResourceService {
  _FakeResourceService(this.data);

  final ResourcesData data;

  @override
  Future<ResourcesData> loadResources() async => data;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ResourceService _resourceService() => _FakeResourceService(
  ResourcesData(
    resources: [
      ResourceFile(
        id: 'attack.png',
        name: 'attack.png',
        path: 'quests/$_questId/$_attackPath',
        type: 'image',
        friendlyName: 'Атака',
      ),
      ResourceFile(
        id: 'shield.webp',
        name: 'shield.webp',
        path: 'quests/$_questId/$_shieldPath',
        type: 'image',
        friendlyName: 'Щит',
      ),
    ],
    explicitFolders: const [],
  ),
);

Future<TextEditingController> _pumpEditor(
  WidgetTester tester, {
  required String text,
  ValueChanged<MarkdownEditorResult>? onChanged,
}) async {
  final service = _resourceService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [resourceServiceProvider(_questId).overrideWithValue(service)],
      child: RepaintBoundary(
        key: const ValueKey('markdown-editor-root'),
        child: MaterialApp(
          home: MarkdownEditorScreen(
            initialText: text,
            questId: _questId,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final field = find.byType(TextField).first;
  await tester.enterText(field, text);
  await tester.pump();
  return tester.widget<TextField>(field).controller!;
}

Future<void> _openImagePicker(WidgetTester tester) async {
  final button = find.byIcon(Icons.add_photo_alternate_rounded);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  expect(button.hitTestable(), findsOneWidget);
  await tester.tap(button);
  await tester.pumpAndSettle();

  final picker = find.byType(InlineImagePicker, skipOffstage: false);
  expect(picker, findsOneWidget);
  expect(tester.widget<InlineImagePicker>(picker).questId, _questId);
}

Future<void> _answerImagePicker(WidgetTester tester, String? path) async {
  await _openImagePicker(tester);
  if (path == null) {
    final close = find.byKey(const ValueKey('inline-image-picker-close'));
    await tester.ensureVisible(close);
    await tester.pumpAndSettle();
    await tester.tap(close);
  } else {
    final option = find.byKey(ValueKey('inline-image-$path'));
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
  }
  await tester.pumpAndSettle();
}

Future<void> _settleImages(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump();
    final images = tester.allRenderObjects.whereType<RenderImage>();
    if (images.isNotEmpty && images.every((image) => image.image != null)) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory appDir;

  setUpAll(() async {
    appDir = await Directory.systemTemp.createTemp('mnd_markdown_inline_image');
    FileStorage.overrideAppDirectory(appDir);
    QuestImageSource.invalidate();
    for (final entry in {
      _attackPath: _attackPng,
      _shieldPath: _shieldPng,
    }.entries) {
      final file = File('${appDir.path}/quests/$_questId/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(entry.value));
    }
  });

  tearDownAll(() async {
    FileStorage.overrideAppDirectory(null);
    QuestImageSource.invalidate();
    if (appDir.existsSync()) await appDir.delete(recursive: true);
  });

  testWidgets('пикер вставляет один самозакрывающийся тег картинки', (
    tester,
  ) async {
    final changes = <String>[];
    final controller = await _pumpEditor(
      tester,
      text: 'Атака ',
      onChanged: (result) => changes.add(result.text),
    );

    await _answerImagePicker(tester, 'res/images/attack.png');

    const expected = 'Атака [img=res/images/attack.png]';
    expect(controller.text, expected);
    expect(controller.selection.baseOffset, expected.length);
    expect(changes.last, expected);
    expect('[img='.allMatches(controller.text), hasLength(1));
    expect(controller.text, isNot(contains('[/img]')));
  });

  testWidgets('поиск находит сохранённое эмодзи и вставляет его', (
    tester,
  ) async {
    final controller = await _pumpEditor(tester, text: 'Защита ');
    await _openImagePicker(tester);
    final search = find.descendant(
      of: find.byType(InlineImagePicker),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'щит');
    await tester.pump();

    expect(
      find.byKey(const ValueKey('inline-image-$_attackPath')),
      findsNothing,
    );
    final shield = find.byKey(const ValueKey('inline-image-$_shieldPath'));
    expect(shield, findsOneWidget);
    await tester.ensureVisible(shield);
    await tester.pumpAndSettle();
    await tester.tap(shield);
    await tester.pumpAndSettle();

    expect(controller.text, 'Защита [img=$_shieldPath]');
  });

  testWidgets('отмена пикера не меняет текст', (tester) async {
    final controller = await _pumpEditor(tester, text: 'Атака ');

    await _answerImagePicker(tester, null);

    expect(controller.text, 'Атака ');
    expect(controller.text, isNot(contains('[img=')));
  });

  testWidgets('пикер помещается над клавиатурой на низком экране', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resourceServiceProvider(
            _questId,
          ).overrideWithValue(_resourceService()),
        ],
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(390, 500),
              viewInsets: EdgeInsets.only(bottom: 350),
            ),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: InlineImagePicker(questId: _questId),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final picker = find.byType(InlineImagePicker, skipOffstage: false);
    final media = MediaQuery.of(tester.element(picker));
    expect(tester.takeException(), isNull);
    expect(media.size.height, 500);
    expect(media.viewInsets.bottom, 350);
    expect(tester.getSize(picker).height, lessThanOrEqualTo(150));
    expect(
      find.byKey(const ValueKey('inline-image-picker-close')),
      findsOneWidget,
    );
  });

  testWidgets('пикер сохранённых эмодзи на телефоне', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpEditor(tester, text: 'Атака ');
    await _openImagePicker(tester);
    await _settleImages(tester);

    await expectLater(
      find.byKey(const ValueKey('markdown-editor-root')),
      matchesGoldenFile('goldens/inline_image_picker_phone.png'),
    );
  });

  testWidgets('пикер сохранённых эмодзи в широком окне', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpEditor(tester, text: 'Атака ');
    await _openImagePicker(tester);
    await _settleImages(tester);

    await expectLater(
      find.byKey(const ValueKey('markdown-editor-root')),
      matchesGoldenFile('goldens/inline_image_picker_desktop.png'),
    );
  });
}
