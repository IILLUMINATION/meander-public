import 'dart:async';
import 'dart:io';

import 'package:canvas_app/features/editor/screens/node_content/content_item_card.dart';
import 'package:canvas_app/features/editor/screens/node_content/modal_editor_screen.dart';
import 'package:canvas_app/features/editor/screens/node_content_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnd_core/models/saved_node.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';

const _questId = '55555555-5555-4555-8555-555555555555';
const _chapterId = 'chapter-1';

Future<void> _seedNode() async {
  await FileStorage.writeJsonFile(QuestPaths.config(_questId), {
    'id': _questId,
    'title': 'Autosave race',
    'startNodeId': 'n1',
    'tags': [
      {'id': _chapterId, 'name': 'Глава 1'},
    ],
    'connections': <dynamic>[],
  });
  await FileStorage.writeJsonFile(QuestPaths.nodesLegacy(_questId), {
    'nodes': [
      {
        'id': 'n1',
        'chapterId': _chapterId,
        'title': 'Нода',
        'x': 0.0,
        'y': 0.0,
        'content': {
          'items': [
            {
              'id': 'modal-1',
              'type': 'modal',
              'targetNodeId': 'n2',
              'buttonText': 'Уведомление',
            },
          ],
        },
      },
      {
        'id': 'n2',
        'chapterId': _chapterId,
        'title': 'Цель',
        'x': 100.0,
        'y': 0.0,
        'content': {'items': <dynamic>[]},
      },
    ],
    'groups': <dynamic>[],
    'comments': <dynamic>[],
  });
  FileStorage.invalidateJsonCache([
    QuestPaths.config(_questId),
    QuestPaths.nodesLegacy(_questId),
  ]);
  await QuestNodesStore.ensurePerNode(_questId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('новая правка во время сохранения не теряется', (tester) async {
    final appDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('mnd_modal_autosave'),
    ))!;
    FileStorage.overrideAppDirectory(appDir);
    addTearDown(() {
      FileStorage.overrideAppDirectory(null);
      if (appDir.existsSync()) appDir.deleteSync(recursive: true);
    });
    await tester.runAsync(() => _seedNode());

    final writes = <SavedNode>[];
    final releaseFirstWrite = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: NodeContentScreen(
            questId: _questId,
            nodeId: 'n1',
            saveNodeOverride: (_, node) async {
              writes.add(node);
              if (writes.length == 1) {
                await releaseFirstWrite.future;
              }
            },
          ),
        ),
      ),
    );
    await tester.pump();
    for (
      var i = 0;
      i < 50 && find.byType(ContentItemCard).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ContentItemCard), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Нода до правки');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(writes, hasLength(1));

    await tester.tap(
      find.descendant(
        of: find.byType(ContentItemCard),
        matching: find.byIcon(Icons.edit),
      ),
    );
    await tester.pump();
    for (
      var i = 0;
      i < 50 && find.byType(ModalEditorScreen).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    final modal = tester.widget<ModalEditorScreen>(
      find.byType(ModalEditorScreen),
    );
    modal.onChanged!(
      modal.existingItem!.copyWith(
        scriptAssetId: 'scripts/gs-hp.json',
        clearTargetNodeId: true,
      ),
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(writes, hasLength(1));

    releaseFirstWrite.complete();
    for (var i = 0; i < 50 && writes.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(writes, hasLength(2));
    final items = writes.last.content['items'] as List<dynamic>;
    final modalJson = items.single as Map<String, dynamic>;
    expect(modalJson['scriptAssetId'], 'scripts/gs-hp.json');
    expect(modalJson['targetNodeId'], isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
