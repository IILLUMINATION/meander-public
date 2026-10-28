import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_document_launcher.dart';
import 'package:canvas_app/features/guides/screens/guide_screen.dart';
import 'package:canvas_app/features/guides/screens/guides_screen.dart';
import 'package:canvas_app/features/quests/screens/quest_history_screen.dart';

void main() {
  test('каталог гайдов открывается списком, а не статьёй', () {
    final widget = EditorDocumentLauncher.buildDocument(
      EditorDocumentDescriptor.guidesCatalog('q1'),
    );

    expect(widget, isA<GuidesScreen>());
    expect((widget as GuidesScreen).questId, 'q1');
  });

  test('вкладка гайда открывает статью с тем же id', () {
    final widget = EditorDocumentLauncher.buildDocument(
      EditorDocumentDescriptor.guide('q1', 'market', title: 'Маркет'),
    );

    expect(widget, isA<GuideScreen>());
    expect((widget as GuideScreen).info.id, 'market');
  });

  test('исчезнувший из каталога гайд не оставляет пустую вкладку', () {
    final widget = EditorDocumentLauncher.buildDocument(
      EditorDocumentDescriptor.guide('q1', 'removed_guide'),
    );

    expect(widget, isA<GuidesScreen>());
    expect((widget as GuidesScreen).questId, 'q1');
  });

  test('вкладка истории версий знает свой квест', () {
    final widget = EditorDocumentLauncher.buildDocument(
      EditorDocumentDescriptor.questHistory('q42'),
    );

    expect(widget, isA<QuestHistoryScreen>());
    expect((widget as QuestHistoryScreen).questId, 'q42');
  });
}
