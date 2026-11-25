import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_block_shell.dart';

enum ScratchFieldKind {
  eventType,
  eventFunction,
  watchPaths,
  expression,
  templateExpression,
  variable,
  node,
  contentItem,
  audio,
  script,
  function,
  functionEntry,
  luaSource,
  luaScript,
  luaFunction,
  table,
  tableVariable,
  tablePath,
  tableOperation,
  saveOperation,
  visibilityMode,
  panelMode,
  volumeTarget,
  volume,
  blurTarget,
  blur,
  stopSoundTarget,
  pauseTarget,
  pauseAction,
  httpMethod,
  httpUrl,
  httpBody,
  httpHeaders,
  httpResponseVariable,
  httpStatusVariable,
  musicLoop,
  musicGlobal,
  whileSettings,
  loopCount,
  loopFrom,
  loopTo,
  loopStep,
  loopVariable,
  maxIterations,
  foreachPrefix,
  foreachIndex,
  comment,
}

/// Как блок выглядит на канвасе: заголовок, значения-чипсы, цвет и ветки.
///
/// Классический редактор рисует каждый блок своим виджетом с полями и
/// диалогами. Канвас рисует тысячи блоков одним painter'ом, поэтому ему нужен
/// дешёвый текстовый портрет блока. Каждый чип несёт тип своего редактора.
class ScratchBlockView {
  const ScratchBlockView({
    required this.title,
    this.values = const [],
    this.fieldKinds = const [],
    this.caption,
  });

  /// Постоянная часть подписи: «Ждать», «Если», «Сменить картинку».
  final String title;

  /// Значения блока — чипсы после заголовка. Пустая строка допустима:
  /// у блока есть поле, но оно ещё не заполнено.
  final List<String> values;

  /// Редактор каждого чипа. Отсутствие элемента означает неправлемую подпись.
  final List<ScratchFieldKind?> fieldKinds;

  ScratchFieldKind? fieldKindAt(int index) =>
      index < fieldKinds.length ? fieldKinds[index] : null;

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

String _field(String raw, [int max = 40]) {
  final text = displayFieldSentinel(raw);
  return text.trim().isEmpty ? tr('Пусто') : _short(text, max);
}

String _choice(String raw) => raw.trim().isEmpty ? tr('Не выбрано') : raw;

String _yesNo(bool value) => value ? tr('да') : tr('нет');

String _eventTypeLabel(EventType type) => switch (type) {
  EventType.onQuestStart => tr('При запуске квеста'),
  EventType.onNodeEnter => tr('При запуске ноды'),
  EventType.onPress => tr('При нажатии'),
  EventType.onContentAppear => tr('При появлении контента'),
  EventType.onDataChange => tr('При изменении данных'),
  EventType.function => tr('Функция'),
};

String _modeLabel(String mode) => switch (mode) {
  'show' => tr('показать'),
  'hide' => tr('скрыть'),
  'remove' => tr('убрать'),
  'toggle' => tr('переключить'),
  _ => mode,
};

/// Текстовая версия блока для painter'а.
ScratchBlockView scratchViewOf(VisualScriptBlock block) {
  switch (block) {
    case EventBlock b:
      final type = b.eventType ?? EventType.onNodeEnter;
      final values = <String>[_eventTypeLabel(type)];
      final kinds = <ScratchFieldKind?>[ScratchFieldKind.eventType];
      if (type == EventType.function) {
        values.add(_field(b.functionName));
        kinds.add(ScratchFieldKind.eventFunction);
      }
      if (type == EventType.onDataChange) {
        values.add(_field(b.watchPaths.join(', ')));
        kinds.add(ScratchFieldKind.watchPaths);
      }
      return ScratchBlockView(
        title: tr('Событие'),
        values: values,
        fieldKinds: kinds,
      );

    case ConditionBlock b:
      return ScratchBlockView(
        title: tr('Если'),
        values: [_field(b.expression, 60)],
        fieldKinds: const [ScratchFieldKind.expression],
      );

    case AssignVariableBlock b:
      return ScratchBlockView(
        title: tr('Присвоить'),
        values: [_field(b.variableName), '=', _field(b.value)],
        fieldKinds: const [
          ScratchFieldKind.variable,
          null,
          ScratchFieldKind.expression,
        ],
      );

    case SetImageBlock b:
      return ScratchBlockView(
        title: tr('Сменить картинку'),
        values: [_field(b.itemName), _field(b.source)],
        fieldKinds: const [
          ScratchFieldKind.contentItem,
          ScratchFieldKind.templateExpression,
        ],
      );

    case SetVisibleBlock b:
      return ScratchBlockView(
        title: tr('Скрыть / убрать'),
        values: [_modeLabel(b.mode), _field(b.itemName)],
        fieldKinds: const [
          ScratchFieldKind.visibilityMode,
          ScratchFieldKind.contentItem,
        ],
      );

    case SetTopPanelBlock b:
      return ScratchBlockView(
        title: tr('Верхняя панель'),
        values: [_modeLabel(b.mode)],
        fieldKinds: const [ScratchFieldKind.panelMode],
      );

    case SetVolumeBlock b:
      return ScratchBlockView(
        title: tr('Установить громкость'),
        values: [_choice(b.target), b.volume.toStringAsFixed(2)],
        fieldKinds: const [
          ScratchFieldKind.volumeTarget,
          ScratchFieldKind.volume,
        ],
      );

    case SetBlurBlock b:
      return ScratchBlockView(
        title: tr('Установить размытие'),
        values: [_choice(b.target), b.blurValue.toStringAsFixed(1)],
        fieldKinds: const [ScratchFieldKind.blurTarget, ScratchFieldKind.blur],
      );

    case GoToNodeBlock b:
      return ScratchBlockView(
        title: tr('Перейти к ноде'),
        values: [_field(b.targetNodeName)],
        fieldKinds: const [ScratchFieldKind.node],
      );

    case CallScriptBlock b:
      return ScratchBlockView(
        title: tr('Запустить скрипт'),
        values: [_field(b.scriptName)],
        fieldKinds: const [ScratchFieldKind.script],
      );

    case CallFunctionBlock b:
      return ScratchBlockView(
        title: tr('Вызвать функцию'),
        values: [_field(b.functionName), _field(b.functionEntry)],
        fieldKinds: const [
          ScratchFieldKind.function,
          ScratchFieldKind.functionEntry,
        ],
      );

    case CallLuaBlock b:
      final isFile = b.scriptId != null;
      return ScratchBlockView(
        title: tr('Вызвать Lua'),
        values: [
          if (isFile) tr('файл .lua') else 'Inline',
          _field(isFile ? b.scriptName : b.script),
          _field(b.function),
          if (b.args != null) _short(b.args.toString()),
        ],
        fieldKinds: [
          ScratchFieldKind.luaSource,
          ScratchFieldKind.luaScript,
          ScratchFieldKind.luaFunction,
          if (b.args != null) null,
        ],
      );

    case DelayBlock b:
      return ScratchBlockView(
        title: tr('Ждать'),
        values: [_field(b.expression), tr('мс')],
        fieldKinds: const [ScratchFieldKind.expression, null],
      );

    case TableOperationBlock b:
      return ScratchBlockView(
        title: tr('Данные'),
        values: [
          b.operation.label,
          _field(b.tableName),
          _field(b.path),
          if (b.operation.needsValue) _field(b.value),
          if (b.operation.needsTarget) _field(b.targetVariable),
        ],
        fieldKinds: [
          ScratchFieldKind.tableOperation,
          ScratchFieldKind.tableVariable,
          ScratchFieldKind.tablePath,
          if (b.operation.needsValue) ScratchFieldKind.expression,
          if (b.operation.needsTarget) ScratchFieldKind.variable,
        ],
      );

    case PlaySoundBlock b:
      return ScratchBlockView(
        title: tr('Воспроизвести звук'),
        values: [_field(b.audioName), b.volume.toStringAsFixed(2)],
        fieldKinds: const [ScratchFieldKind.audio, ScratchFieldKind.volume],
      );

    case StopSoundBlock b:
      return ScratchBlockView(
        title: tr('Остановить звук'),
        values: [_choice(b.target), if (b.target != 'all') _field(b.audioName)],
        fieldKinds: [
          ScratchFieldKind.stopSoundTarget,
          if (b.target != 'all') ScratchFieldKind.audio,
        ],
      );

    case PlayMusicBlock b:
      return ScratchBlockView(
        title: tr('Воспроизвести музыку'),
        values: [
          _field(b.audioName),
          b.volume.toStringAsFixed(2),
          trf('петля: {p0}', {'p0': _yesNo(b.loop)}),
          trf('везде: {p0}', {'p0': _yesNo(b.global)}),
        ],
        fieldKinds: const [
          ScratchFieldKind.audio,
          ScratchFieldKind.volume,
          ScratchFieldKind.musicLoop,
          ScratchFieldKind.musicGlobal,
        ],
      );

    case StopMusicBlock _:
      return ScratchBlockView(title: tr('Остановить музыку'));

    case PauseResumeBlock b:
      return ScratchBlockView(
        title: tr('Пауза / Возобновление'),
        values: [_choice(b.target), _choice(b.action)],
        fieldKinds: const [
          ScratchFieldKind.pauseTarget,
          ScratchFieldKind.pauseAction,
        ],
      );

    case CrossfadeBlock b:
      return ScratchBlockView(
        title: tr('Кроссфейд (затемнение)'),
        values: [_field(b.durationExpression), tr('мс')],
        fieldKinds: const [ScratchFieldKind.expression, null],
      );

    case OpenLinkBlock b:
      return ScratchBlockView(
        title: tr('Открыть ссылку'),
        values: [_field(b.url, 48)],
        fieldKinds: const [ScratchFieldKind.expression],
      );

    case HttpRequestBlock b:
      return ScratchBlockView(
        title: tr('HTTP-запрос'),
        values: [
          _choice(b.method),
          _field(b.url, 48),
          _field(b.body, 32),
          _field(b.headers, 32),
          _field(b.targetVariable),
          _field(b.statusVariable),
        ],
        fieldKinds: const [
          ScratchFieldKind.httpMethod,
          ScratchFieldKind.httpUrl,
          ScratchFieldKind.httpBody,
          ScratchFieldKind.httpHeaders,
          ScratchFieldKind.httpResponseVariable,
          ScratchFieldKind.httpStatusVariable,
        ],
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
          _field(b.slotName),
        ],
        fieldKinds: const [
          ScratchFieldKind.saveOperation,
          ScratchFieldKind.expression,
        ],
      );

    case CommentBlock b:
      return ScratchBlockView(
        title: tr('Комментарий'),
        values: [_field(b.text, 80)],
        fieldKinds: const [ScratchFieldKind.comment],
      );

    case ForEachBlock b:
      return ScratchBlockView(
        title: tr('Для каждой строки'),
        values: [
          _field(b.tableName),
          _field(b.varPrefix),
          _field(b.indexVariable),
        ],
        fieldKinds: const [
          ScratchFieldKind.table,
          ScratchFieldKind.foreachPrefix,
          ScratchFieldKind.foreachIndex,
        ],
      );

    case WhileBlock b:
      final mode = b.hasExpression
          ? 'expression'
          : b.hasRange
          ? 'range'
          : 'count';
      final values = <String>[
        switch (mode) {
          'expression' => tr('пока'),
          'range' => tr('диапазон'),
          _ => tr('раз'),
        },
      ];
      final kinds = <ScratchFieldKind?>[ScratchFieldKind.whileSettings];
      if (b.hasExpression) {
        values.add(_field(b.expression, 50));
        kinds.add(ScratchFieldKind.expression);
      } else if (b.hasRange) {
        values.addAll([
          _field(b.from),
          tr('до'),
          _field(b.to),
          tr('шаг'),
          _field(b.step),
        ]);
        kinds.addAll([
          ScratchFieldKind.loopFrom,
          null,
          ScratchFieldKind.loopTo,
          null,
          ScratchFieldKind.loopStep,
        ]);
      } else {
        values.addAll([_field(b.count), tr('раз')]);
        kinds.addAll([ScratchFieldKind.loopCount, null]);
      }
      values.add(_field(b.loopVar));
      kinds.add(ScratchFieldKind.loopVariable);
      values.add(b.maxIterations.toString());
      kinds.add(ScratchFieldKind.maxIterations);
      return ScratchBlockView(
        title: b.hasExpression ? tr('Повторять, пока') : tr('Повторить'),
        values: values,
        fieldKinds: kinds,
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
