import 'package:flutter_test/flutter_test.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/scratch_script_editor/scratch_block_view.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_creation.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/shared/script_contracts.dart';

/// Текстовый портрет блока для painter'а.
///
/// Канвас не рисует виджеты, поэтому подпись блока — единственное, что видит
/// автор. Блок без подписи («Блок») на канвасе выглядит как поломка, а не как
/// новый тип, поэтому проверяем, что каждый тип из палитры что-то говорит.
void main() {
  test('каждый тип палитры получает осмысленный заголовок', () {
    final fallback = tr('Блок');
    // События в палитре нет: их добавляет отдельная кнопка, `event` в
    // `createBlockOfType` намеренно не входит.
    final types = <String>{
      BlockTypes.condition,
      BlockTypes.assignVariable,
      BlockTypes.goToNode,
      BlockTypes.setVolume,
      BlockTypes.setBlur,
      BlockTypes.wait,
      BlockTypes.callScript,
      BlockTypes.callFunction,
      BlockTypes.callLua,
      BlockTypes.tableOperation,
      BlockTypes.setImage,
      BlockTypes.setVisible,
      BlockTypes.setTopPanel,
      BlockTypes.playSound,
      BlockTypes.stopSound,
      BlockTypes.playMusic,
      BlockTypes.stopMusic,
      BlockTypes.pauseResume,
      BlockTypes.crossfade,
      BlockTypes.saveOperation,
      BlockTypes.openLink,
      BlockTypes.httpRequest,
      BlockTypes.comment,
      BlockTypes.forEach,
      BlockTypes.whileLoop,
    };

    expect(types.length, greaterThanOrEqualTo(25));
    for (final type in types) {
      final view = scratchViewOf(createBlockOfType(type));
      expect(view.title, isNotEmpty, reason: 'тип $type без заголовка');
      expect(view.title, isNot(fallback), reason: 'тип $type провалился в заглушку');
    }
  });

  test('неизвестный тип блока подписан честно', () {
    final block = VisualScriptBlock.fromJson({'type': 'нет_такого_типа'});
    final view = scratchViewOf(block);
    expect(view.title, tr('Неизвестный блок'));
    expect(view.values, isNotEmpty, reason: 'виден исходный тип');
  });

  group('события', () {
    test('подпись зависит от типа события', () {
      for (final type in EventType.values) {
        final view = scratchViewOf(EventBlock(eventType: type));
        expect(view.title, isNotEmpty);
        expect(view.title, isNot(tr('Блок')));
      }
    });

    test('подписи типов различаются', () {
      final titles = {
        for (final type in EventType.values)
          scratchViewOf(EventBlock(eventType: type)).title,
      };
      expect(titles, hasLength(EventType.values.length));
    });
  });

  group('ветки', () {
    test('контейнер отдаёт ветки, лист — нет', () {
      expect(scratchBranchesOf(EventBlock(children: [DelayBlock()])), hasLength(1));
      expect(
        scratchBranchesOf(ConditionBlock(thenBlocks: [DelayBlock()])),
        hasLength(2),
      );
      expect(scratchBranchesOf(WhileBlock()), hasLength(1));
      expect(scratchBranchesOf(ForEachBlock()), hasLength(1));
      expect(scratchBranchesOf(CrossfadeBlock()), hasLength(1));
      expect(scratchBranchesOf(DelayBlock()), isEmpty);
    });

    test('свёрнутый контейнер прячет ветки', () {
      final block = ConditionBlock(thenBlocks: [DelayBlock()], collapsed: true);
      expect(scratchBranchesOf(block), isEmpty);
      expect(scratchIsCollapsible(block), isTrue);
      expect(scratchIsCollapsed(block), isTrue);

      scratchToggleCollapsed(block);
      expect(scratchIsCollapsed(block), isFalse);
      expect(scratchBranchesOf(block), hasLength(2));
    });

    test('лист не сворачивается', () {
      final block = DelayBlock();
      expect(scratchIsCollapsible(block), isFalse);
      scratchToggleCollapsed(block);
      expect(scratchIsCollapsed(block), isFalse);
    });
  });
}