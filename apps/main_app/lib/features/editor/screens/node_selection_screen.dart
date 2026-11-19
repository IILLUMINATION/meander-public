import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/editor/providers/node_clipboard_provider.dart';
import 'package:canvas_app/features/editor/providers/tag_provider.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

enum NodeSortFilter { byName, byChapter, byContent }

class NodeSelectionScreen extends ConsumerStatefulWidget {
  final String questId;
  final String? currentNodeId;
  final String? selectedNodeId;

  /// Подсказка для имени новой ноды (например, текст кнопки, для которой её
  /// создают). Если задана — кнопка "Создать новую" использует это как title
  /// вместо дефолтного 'Новая нода'.
  final String? suggestedTitle;

  /// Разрешить создание ноды отсюда даже когда текущей ноды нет — то есть
  /// экран открыли «выбрать», а не «редактировать». Выбор стартовой ноды
  /// свежего квеста иначе упирается в пустой список без выхода.
  final bool allowCreate;

  const NodeSelectionScreen({
    super.key,
    required this.questId,
    this.currentNodeId,
    this.selectedNodeId,
    this.suggestedTitle,
    this.allowCreate = false,
  });

  @override
  ConsumerState<NodeSelectionScreen> createState() =>
      _NodeSelectionScreenState();
}

class _NodeSelectionScreenState extends ConsumerState<NodeSelectionScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  NodeSortFilter _activeFilter = NodeSortFilter.byName;
  bool _isAscending = true;
  bool _isCreating = false;

  static const int _maxTitleLength = 40;

  /// Создавать ли ноду прямо отсюда: обычно экран открывают «перейти /
  /// привязать», где есть текущая нода отсчёта, и выбор стартовой ноды, где
  /// её нет, а создавать отсюда можно и нужно.
  bool get _canCreate => widget.currentNodeId != null || widget.allowCreate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.invalidate(allQuestNodesProvider(widget.questId));
        ref.invalidate(questTagsProvider(widget.questId));
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Color _getColorForTag(String tagId) {
    const double goldenRatioConjugate = 0.61803398875;
    final hash = tagId.hashCode;
    final double hue = (hash * goldenRatioConjugate).remainder(1.0);
    return HSLColor.fromAHSL(1.0, hue * 360.0, 0.55, 0.65).toColor();
  }

  String? _getContentSnippet(SavedNode node) {
    final items = node.content['items'] as List<dynamic>?;
    if (items == null) return null;
    final textItem = items.firstWhereOrNull(
      (item) => item is Map && item['type'] == 'text',
    );
    if (textItem != null && textItem['text'] is String) {
      String text = textItem['text'] as String;
      text = text.replaceAll('\n', ' ').trim();
      if (text.isEmpty) return null;
      return text.length > 80 ? '${text.substring(0, 80)}…' : text;
    }
    return null;
  }

  List<SavedNode> _sortNodes(
    List<SavedNode> nodes,
    Map<String, String> tagMap,
  ) {
    nodes.sort((a, b) {
      int comparison;
      switch (_activeFilter) {
        case NodeSortFilter.byName:
          comparison = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
        case NodeSortFilter.byChapter:
          final nameA = tagMap[a.chapterId] ?? 'Ω';
          final nameB = tagMap[b.chapterId] ?? 'Ω';
          comparison = nameA.toLowerCase().compareTo(nameB.toLowerCase());
          break;
        case NodeSortFilter.byContent:
          final snippetA = _getContentSnippet(a) ?? '';
          final snippetB = _getContentSnippet(b) ?? '';
          comparison = snippetA.toLowerCase().compareTo(snippetB.toLowerCase());
          break;
      }
      return _isAscending ? comparison : -comparison;
    });
    return nodes;
  }

  /// Готовим заголовок новой ноды из подсказки (например, из текста кнопки):
  /// убираем переводы строк, тримим, обрезаем до [_maxTitleLength].
  String _prepareTitleFromHint(String? hint) {
    if (hint == null) return tr('Новая нода');
    final cleaned = hint.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return tr('Новая нода');
    if (cleaned.length <= _maxTitleLength) return cleaned;
    return '${cleaned.substring(0, _maxTitleLength - 1)}…';
  }

  void _showCreationFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
      ),
    );
  }

  Future<void> _createAndSelectNewNode() async {
    if (_isCreating) return;
    setState(() => _isCreating = true);

    try {
      final allNodes = await ref.read(
        allQuestNodesProvider(widget.questId).future,
      );

      double baseX = 0;
      double baseY = 0;
      String chapterId = '';

      if (widget.currentNodeId != null) {
        final currentNode = allNodes.firstWhereOrNull(
          (n) => n.id == widget.currentNodeId,
        );
        if (currentNode != null) {
          // Размещаем новую ноду снизу от текущей (по Y), а не справа.
          // Так канвас растёт вниз — это удобнее для веток диалога.
          baseX = currentNode.x;
          baseY = currentNode.y + 220;
          chapterId = currentNode.chapterId;
        }
      }

      if (chapterId.isEmpty) {
        final tags = await ref.read(questTagsProvider(widget.questId).future);
        if (tags.isNotEmpty) {
          chapterId = tags.first.id;
        } else {
          // Случайного id главы быть не может: канвас показывает только ноды
          // своей главы, поэтому нода «ни в какую» не появилась бы ни в одной
          // главе — ни в списке, ни в редакторе. Главе нужно родиться вместе
          // с нодой.
          final chapter = await createTag(widget.questId, 'Глава 1');
          if (chapter == null) {
            _showCreationFailure(tr('Не удалось создать главу'));
            return;
          }
          chapterId = chapter.id;
          ref.invalidate(questTagsProvider(widget.questId));
        }
      }

      // Антиколлизионная автопозиция: если базовая точка уже занята —
      // ищем ближайший свободный слот по Y.
      final pos = findFreePositionNear(allNodes, baseX, baseY);

      final title = _prepareTitleFromHint(widget.suggestedTitle);
      final newNodeId = const Uuid().v4();
      final newNode = SavedNode(
        id: newNodeId,
        chapterId: chapterId,
        title: title,
        content: {'items': []},
        x: pos.dx,
        y: pos.dy,
      );

      final saved = await saveNodes(widget.questId, [newNode]);
      if (!saved) {
        _showCreationFailure(tr('Не удалось сохранить ноду'));
        return;
      }

      ref.invalidate(allQuestNodesProvider(widget.questId));

      if (mounted) {
        Navigator.pop(context, newNodeId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final nodesAsync = ref.watch(allQuestNodesProvider(widget.questId));
    final tagsAsync = ref.watch(questTagsProvider(widget.questId));

    final canCreateNew = _canCreate;
    final hasHint = (widget.suggestedTitle ?? '').trim().isNotEmpty;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(tr('Выбор ноды'), style: textTheme.titleLarge),
      ),
      floatingActionButton: canCreateNew
          ? FloatingActionButton.extended(
              heroTag: null,
              onPressed: _isCreating ? null : _createAndSelectNewNode,
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              icon: _isCreating
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: scheme.onPrimaryContainer,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.add_rounded),
              label: Text(
                hasHint
                    ? trf('Создать «{p0}»', {'p0': _prepareTitleFromHint(widget.suggestedTitle)})
                    : tr('Создать новую'),
              ),
            )
          : null,
      body: AdaptiveContent(
        maxWidth: 800,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: tr('Поиск ноды…'),
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: scheme.surfaceContainerHigh,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide(
                            color: scheme.primary,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value.toLowerCase();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _showSortDialog,
                    icon: const Icon(Icons.sort_rounded),
                    tooltip: tr('Сортировка'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: nodesAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(
                  child: Text(
                    trf('Ошибка: {p0}', {'p0': friendlyError(err)}),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
                data: (nodes) {
                  return tagsAsync.when(
                    loading: () => const SizedBox(),
                    error: (_, __) => const SizedBox(),
                    data: (tags) {
                      final tagMap = {for (var tag in tags) tag.id: tag.name};
                      final tagColorMap = {
                        for (var tag in tags) tag.id: _getColorForTag(tag.id),
                      };

                      var filteredNodes = nodes.where((node) {
                        if (node.id == widget.currentNodeId) return false;
                        if (_searchQuery.isNotEmpty) {
                          return node.title.toLowerCase().contains(
                            _searchQuery,
                          );
                        }
                        return true;
                      }).toList();

                      filteredNodes = _sortNodes(filteredNodes, tagMap);

                      if (filteredNodes.isEmpty) {
                        return _buildEmptyState(scheme, textTheme);
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                        itemCount: filteredNodes.length,
                        itemBuilder: (context, index) {
                          final node = filteredNodes[index];
                          final isSelected = widget.selectedNodeId == node.id;
                          final tagName = tagMap[node.chapterId] ?? tr('Без главы');
                          final tagColor =
                              tagColorMap[node.chapterId] ?? scheme.outline;
                          final snippet = _getContentSnippet(node);

                          return Padding(
                            key: ValueKey(node.id),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: isSelected
                                  ? scheme.primaryContainer
                                  : scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(16),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => Navigator.pop(context, node.id),
                                // Долгий тап остался: на телефоне это единственный
                                // вход в меню. Правая кнопка мыши — его ПК-
                                // эквивалент, но у неё есть ещё и позиция курсора.
                                onLongPress: () =>
                                    _showContextMenu(context, node),
                                onSecondaryTapUp: (details) => _showContextMenu(
                                  context,
                                  node,
                                  anchor: details.globalPosition,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 64,
                                      color: tagColor,
                                    ),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 12,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              node.title,
                                              style: textTheme.titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                    color: isSelected
                                                        ? scheme
                                                              .onPrimaryContainer
                                                        : scheme.onSurface,
                                                  ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (snippet != null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                snippet,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: textTheme.bodySmall?.copyWith(
                                                  color: isSelected
                                                      ? scheme
                                                            .onPrimaryContainer
                                                            .withOpacity(0.75)
                                                      : scheme.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                            const SizedBox(height: 6),
                                            _buildChapterChip(
                                              scheme,
                                              textTheme,
                                              tagColor,
                                              tagName,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (isSelected)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 12,
                                        ),
                                        child: Icon(
                                          Icons.check_circle_rounded,
                                          color: scheme.onPrimaryContainer,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChapterChip(
    ColorScheme scheme,
    TextTheme textTheme,
    Color tagColor,
    String tagName,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tagColor.withOpacity(0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: tagColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            tagName,
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme scheme, TextTheme textTheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.search_off_rounded,
              size: 36,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr('Ноды не найдены'),
            style: textTheme.titleMedium?.copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            _emptyStateHint(),
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          // Выбор стартовой ноды свежего квеста иначе тупик: выбирать не из
          // чего, а создать ноду можно только вернувшись в редактор.
          if (_searchQuery.isEmpty && _canCreate) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isCreating ? null : _createAndSelectNewNode,
              icon: _isCreating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded),
              label: Text(_isCreating ? tr('Создаём…') : tr('Создать ноду')),
            ),
          ],
        ],
      ),
    );
  }

  /// Нода, от которой отталкиваются, есть — значит речь про «другие»; в
  /// свежем квесте «других» нет вовсе, и пугать этим новичка незачем.
  String _emptyStateHint() {
    if (_searchQuery.isNotEmpty) return tr('Попробуйте изменить запрос');
    return widget.currentNodeId != null
        ? tr('В этом квесте пока нет других нод')
        : tr('В этом квесте пока нет нод');
  }

  void _showSortDialog() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    showAdaptiveSheet(
      context: context,
      backgroundColor: scheme.surface,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: scheme.onSurfaceVariant.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(tr('Сортировка'), style: textTheme.titleLarge),
                        IconButton.filledTonal(
                          tooltip: _isAscending
                              ? tr('По возрастанию')
                              : tr('По убыванию'),
                          icon: Icon(
                            _isAscending
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded,
                          ),
                          onPressed: () =>
                              setModalState(() => _isAscending = !_isAscending),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildSortOption(
                      scheme: scheme,
                      textTheme: textTheme,
                      title: tr('По имени ноды'),
                      icon: Icons.sort_by_alpha_rounded,
                      value: NodeSortFilter.byName,
                      groupValue: _activeFilter,
                      onChanged: (v) => setModalState(() => _activeFilter = v!),
                    ),
                    _buildSortOption(
                      scheme: scheme,
                      textTheme: textTheme,
                      title: tr('По главе'),
                      icon: Icons.bookmark_outline_rounded,
                      value: NodeSortFilter.byChapter,
                      groupValue: _activeFilter,
                      onChanged: (v) => setModalState(() => _activeFilter = v!),
                    ),
                    _buildSortOption(
                      scheme: scheme,
                      textTheme: textTheme,
                      title: tr('По содержимому'),
                      icon: Icons.notes_rounded,
                      value: NodeSortFilter.byContent,
                      groupValue: _activeFilter,
                      onChanged: (v) => setModalState(() => _activeFilter = v!),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          setState(() {});
                          Navigator.pop(context);
                        },
                        child: Text(tr('Применить')),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showContextMenu(
    BuildContext context,
    SavedNode node, {
    Offset? anchor,
  }) {
    final clipboardState = ref.read(nodeClipboardProvider.notifier);
    final clipboardValue = ref.read(nodeClipboardProvider);

    showMenu<String>(
      context: context,
      // На ПК меню открывается по правому клику — оно обязано появиться под
      // курсором, а не в фиксированной точке экрана.
      position: anchor == null
          ? const RelativeRect.fromLTRB(100, 100, 0, 0)
          : contextMenuRect(anchor, MediaQuery.sizeOf(context)),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              const Icon(Icons.copy_rounded, size: 20),
              const SizedBox(width: 8),
              Text(trf('Копировать в главу "{p0}"', {'p0': node.chapterId})),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'cut',
          child: Row(
            children: [
              const Icon(Icons.cut_rounded, size: 20),
              const SizedBox(width: 8),
              Text(trf('Вырезать в главу "{p0}"', {'p0': node.chapterId})),
            ],
          ),
        ),
        if (clipboardValue != null)
          PopupMenuItem<String>(
            value: 'paste',
            child: Row(
              children: [
                const Icon(Icons.paste_rounded, size: 20),
                const SizedBox(width: 8),
                Text(
                  clipboardValue.operation == 'copy'
                      ? tr('Вставить (копия)')
                      : tr('Вставить (переместить)'),
                ),
              ],
            ),
          ),
      ],
    ).then((value) async {
      if (value == null) return;

      if (value == 'copy' || value == 'cut') {
        clipboardState.state = NodeClipboardItem(
          nodeId: node.id,
          questId: widget.questId,
          operation: value,
        );

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                value == 'copy'
                    ? tr('Нода скопирована в буфер обмена')
                    : tr('Нода вырезана в буфер обмена'),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else if (value == 'paste' && clipboardValue != null) {
        bool success = false;

        if (clipboardValue.operation == 'copy') {
          success = await copyNodeToChapter(
            clipboardValue.questId,
            clipboardValue.nodeId,
            node.chapterId,
          );
        } else {
          success = await moveNodeToChapter(
            clipboardValue.questId,
            clipboardValue.nodeId,
            node.chapterId,
          );
        }

        if (success) {
          clipboardState.state = null;

          if (context.mounted) {
            ref.invalidate(allQuestNodesProvider(widget.questId));
          }
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(tr('Ошибка при вставке ноды')),
                behavior: SnackBarBehavior.floating,
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
              ),
            );
          }
        }
      }
    });
  }

  Widget _buildSortOption({
    required ColorScheme scheme,
    required TextTheme textTheme,
    required String title,
    required IconData icon,
    required NodeSortFilter value,
    required NodeSortFilter groupValue,
    required ValueChanged<NodeSortFilter?> onChanged,
  }) {
    final isSelected = value == groupValue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isSelected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onChanged(value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isSelected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: textTheme.bodyLarge?.copyWith(
                      color: isSelected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (isSelected)
                  Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: scheme.onSecondaryContainer,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
