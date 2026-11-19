import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';

/// Как блок выглядит на канвасе: заголовок, значения-чипсы, цвет и ветки.
///
/// Классический редактор рисует каждый блок своим виджетом с полями и
/// диалогами. Канвас рисует тысячи блоков одним painter'ом, поэтому ему нужен
/// дешёвый текстовый портрет блока. Он не дублирует редактирование — двойной
/// тап открывает тот же виджет-редактор, — но обязан покрывать все типы:
/// иначе новый блок появится на канвасе безымянной плашкой.
class ScratchBlockView {
  const ScratchBlockView({
    required this.title,
    this.values = const [],
    this.caption,
  });

  /// Постоянная часть подписи: «Ждать», «Если», «Сменить картинку».
  final String title;

  /// Значения блока — чипсы после заголовка. Пустая строка допустима:
  /// у блока есть поле, но оно ещё не заполнено.
  final List<String> values;

  /// Подпись под заголовком (адрес, комментарий).
  final String? caption;
}

/// Одна ветка контейнера: подпись и список блоков внутри.
class ScratchBranchSpec {
  const ScratchBranchSpec({this.label, required this.blocks});

  final String? label;
  final List<VisualScriptBlock> blocks;
}

/// Ветки контейнера в порядке отрисовки. Пусто — блок обычный.
///
/// Свёрнутый блок веток не отдаёт: тело не раскладывается, чтобы дерево из
/// тысячи блоков оставалось читаемым и быстрым.
List<ScratchBranchSpec> scratchBranchesOf(VisualScriptBlock block) {
  switch (block) {
    case EventBlock b:
      if (b.collapsed) return const [];
      return [ScratchBranchSpec(blocks: b.children)];
    case ConditionBlock b:
      if (b.collapsed) return const [];
      return [
        ScratchBranchSpec(label: tr('Если истина'), blocks: b.thenBlocks),
        ScratchBranchSpec(label: tr('Иначе'), blocks: b.elseBlocks),
      ];
    case WhileBlock b:
      if (b.collapsed) return const [];
      return [ScratchBranchSpec(blocks: b.children)];
    case ForEachBlock b:
      if (b.collapsed) return const [];
      return [ScratchBranchSpec(blocks: b.children)];
    case CrossfadeBlock b:
      if (b.collapsed) return const [];
      return [ScratchBranchSpec(blocks: b.children)];
    default:
      return const [];
  }
}

bool scratchIsCollapsible(VisualScriptBlock block) =>
    block is EventBlock ||
    block is ConditionBlock ||
    block is WhileBlock ||
    block is ForEachBlock ||
    block is CrossfadeBlock;

bool scratchIsCollapsed(VisualScriptBlock block) => switch (block) {
  final EventBlock b => b.collapsed,
  final ConditionBlock b => b.collapsed,
  final WhileBlock b => b.collapsed,
  final ForEachBlock b => b.collapsed,
  final CrossfadeBlock b => b.collapsed,
  _ => false,
};

void scratchToggleCollapsed(VisualScriptBlock block) {
  switch (block) {
    case EventBlock b:
      b.collapsed = !b.collapsed;
    case ConditionBlock b:
      b.collapsed = !b.collapsed;
    case WhileBlock b:
      b.collapsed = !b.collapsed;
    case ForEachBlock b:
      b.collapsed = !b.collapsed;
    case CrossfadeBlock b:
      b.collapsed = !b.collapsed;
    default:
      break;
  }
}

String _short(String raw, [int max = 40]) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  return text.length <= max ? text : '${text.substring(0, max - 1)}…';
}

String _yesNo(bool value) => value ? tr('да') : tr('нет');

String _modeLabel(String mode) => switch (mode) {
  'show' => tr('показать'),
  'hide' => tr('скрыть'),
  'remove' => tr('убрать'),
  'toggle' => tr('переключить'),
  _ => mode,
};

String _eventTitle(EventBlock block) {
  final type = block.eventType ?? EventType.onNodeEnter;
  return switch (type) {
    EventType.onQuestStart => tr('При запуске квеста'),
    EventType.onNodeEnter => tr('При запуске ноды'),
    EventType.onPress => tr('При нажатии'),
    EventType.onContentAppear => tr('При появлении контента'),
    EventType.onDataChange => tr('При изменении данных'),
    EventType.function => trf('Функция {p0}', {'p0': block.functionName}),
  };
}

/// Текстовая версия блока для painter'а.
ScratchBlockView scratchViewOf(VisualScriptBlock block) {
  switch (block) {
    case EventBlock b:
      final type = b.eventType ?? EventType.onNodeEnter;
      final values = <String>[];
      if (b.targetNodeName.trim().isNotEmpty &&
          b.targetNodeName != 'Не выбрана') {
        values.add(b.targetNodeName);
      }
      if (type == EventType.onDataChange && b.watchPaths.isNotEmpty) {
        values.add(b.watchPaths.join(', '));
      }
      return ScratchBlockView(title: _eventTitle(b), values: values);

    case ConditionBlock b:
      return ScratchBlockView(
        title: tr('Если'),
        values: [_short(b.expression, 60)],
      );

    case AssignVariableBlock b:
      return ScratchBlockView(
        title: tr('Присвоить'),
        values: [b.variableName, '=', _short(b.value, 40)],
      );

    case SetImageBlock b:
      return ScratchBlockView(
        title: tr('Сменить картинку'),
        values: [b.itemName, _short(b.source, 40)],
      );

    case SetVisibleBlock b:
      return ScratchBlockView(
        title: tr('Скрыть / убрать'),
        values: [_modeLabel(b.mode), b.itemName],
      );

    case SetTopPanelBlock b:
      return ScratchBlockView(
        title: tr('Верхняя панель'),
        values: [_modeLabel(b.mode)],
      );

    case SetVolumeBlock b:
      return ScratchBlockView(
        title: tr('Установить громкость'),
        values: [b.target, b.volume.toStringAsFixed(2)],
      );

    case SetBlurBlock b:
      return ScratchBlockView(
        title: tr('Установить размытие'),
        values: [b.target, b.blurValue.toStringAsFixed(1)],
      );

    case GoToNodeBlock b:
      return ScratchBlockView(
        title: tr('Перейти к ноде'),
        values: [b.targetNodeName],
      );

    case CallScriptBlock b:
      return ScratchBlockView(
        title: tr('Запустить скрипт'),
        values: [b.scriptName],
      );

    case CallFunctionBlock b:
      return ScratchBlockView(
        title: tr('Вызвать функцию'),
        values: [b.functionName, b.functionEntry],
      );

    case CallLuaBlock b:
      return ScratchBlockView(
        title: tr('Вызвать Lua'),
        values: [b.scriptName, b.function],
      );

    case DelayBlock b:
      return ScratchBlockView(
        title: tr('Ждать'),
        values: [b.expression, tr('мс')],
      );

    case TableOperationBlock b:
      return ScratchBlockView(
        title: tr('Данные'),
        values: [
          b.operation.label,
          b.tableName,
          if (b.path.trim().isNotEmpty) b.path,
          if (b.targetVariable.trim().isNotEmpty && b.operation.needsTarget)
            b.targetVariable,
        ],
      );

    case PlaySoundBlock b:
      return ScratchBlockView(
        title: tr('Воспроизвести звук'),
        values: [b.audioName, '×${b.volume.toStringAsFixed(2)}'],
      );

    case StopSoundBlock b:
      return ScratchBlockView(
        title: tr('Остановить звук'),
        values: [b.audioName],
      );

    case PlayMusicBlock b:
      return ScratchBlockView(
        title: tr('Воспроизвести музыку'),
        values: [
          b.audioName,
          trf('петля: {p0}', {'p0': _yesNo(b.loop)}),
        ],
      );

    case StopMusicBlock _:
      return ScratchBlockView(title: tr('Остановить музыку'));

    case PauseResumeBlock b:
      return ScratchBlockView(
        title: tr('Пауза / Возобновление'),
        values: [b.target, b.action],
      );

    case CrossfadeBlock b:
      return ScratchBlockView(
        title: tr('Кроссфейд (затемнение)'),
        values: [b.durationExpression, tr('с')],
      );

    case OpenLinkBlock b:
      return ScratchBlockView(
        title: tr('Открыть ссылку'),
        values: [_short(b.url, 48)],
      );

    case HttpRequestBlock b:
      return ScratchBlockView(
        title: tr('HTTP-запрос'),
        values: [b.method, _short(b.url, 48)],
      );

    case SaveOperationBlock b:
      return ScratchBlockView(
        title: tr('Сохранения'),
        values: [
          switch (b.operation) {
            SaveOperation.save => tr('сохранить'),
            SaveOperation.open => tr('открыть'),
            SaveOperation.load => tr('загрузить'),
            SaveOperation.delete => tr('удалить'),
          },
          if (b.slotName.trim().isNotEmpty) b.slotName,
        ],
      );

    case CommentBlock b:
      return ScratchBlockView(
        title: tr('Комментарий'),
        caption: _short(b.text, 80),
      );

    case ForEachBlock b:
      return ScratchBlockView(
        title: tr('Для каждой строки'),
        values: [if (b.tableName.trim().isNotEmpty) b.tableName],
      );

    case WhileBlock b:
      if (b.hasExpression) {
        return ScratchBlockView(
          title: tr('Повторять, пока'),
          values: [_short(b.expression, 50)],
        );
      }
      if (b.hasRange) {
        return ScratchBlockView(
          title: tr('Повторить'),
          values: [b.from, tr('до'), b.to, tr('шаг'), b.step],
        );
      }
      return ScratchBlockView(
        title: tr('Повторить'),
        values: [b.count, tr('раз')],
      );

    case UnknownBlock b:
      return ScratchBlockView(
        title: tr('Неизвестный блок'),
        values: [if (b.rawType != null) b.rawType!],
      );

    default:
      // Иерархия блоков не sealed: подкласс из будущей версии не должен
      // ронять канвас. Показываем тип, правило load→save сохранит JSON.
      return ScratchBlockView(
        title: tr('Блок'),
        values: [block.runtimeType.toString()],
      );
  }
}
