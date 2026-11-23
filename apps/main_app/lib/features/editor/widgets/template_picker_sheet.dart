import 'package:canvas_app/features/editor/providers/template_provider.dart';
import 'package:canvas_app/models/template_model.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

/// Режим, в котором пользователь хочет вставить шаблон.
enum TemplatePickMode {
  /// Полная независимая копия (snapshot). Поведение «как раньше»: payload
  /// клонируется, все id перегенерируются, связь с мастером не сохраняется.
  /// После вставки шаблон можно править как угодно, изменение мастера на
  /// этот объект не повлияет.
  snapshot,

  /// Связанная вставка (linked). На диск пишется только тонкий инстанс
  /// (`templateRef` + локальные layout-поля). При отрисовке резолвер
  /// разворачивает мастер в полное дерево. Изменение мастера сразу
  /// отражается во всех linked-инстансах квеста.
  linked,
}

/// Результат выбора шаблона: что именно выбрали и в каком режиме вставлять.
class TemplatePickResult {
  final TemplateItem template;
  final TemplatePickMode mode;

  /// Был ли шаблон выбран из глобального списка (а не из квестового).
  /// Нужен callsite-ам, чтобы понять: в linked-режиме мастер придётся
  /// «пиннить» в квест (см. `TemplateActions.pinToQuest`).
  final bool wasGlobal;

  const TemplatePickResult({
    required this.template,
    required this.mode,
    required this.wasGlobal,
  });
}

/// Bottom-sheet с фильтрами, поиском и списком шаблонов.
///
/// Существует два публичных API:
/// * [show] — старый, возвращает только `TemplateItem` (всегда snapshot).
///   Сохранён для обратной совместимости со старыми вызовами; продолжает
///   работать как раньше.
/// * [showWithMode] — новый, возвращает `TemplatePickResult` с выбранным
///   режимом вставки (snapshot/linked). Для глав linked-режим недоступен
///   и не предлагается пользователю.
class TemplatePickerSheet extends ConsumerStatefulWidget {
  /// Если null — показывает только глобальные шаблоны.
  final String? questId;

  /// Если задано — оставляет только эти типы.
  final Set<TemplateKind>? allowedKinds;

  final String? title;

  /// Разрешить linked-режим. Если false — у пользователя нет выбора,
  /// результат всегда snapshot (поведение «как раньше»). По умолчанию
  /// `true` для новых вызовов (через [showWithMode]).
  final bool allowLinked;

  const TemplatePickerSheet({
    super.key,
    this.questId,
    this.allowedKinds,
    this.title,
    this.allowLinked = false,
  });

  /// Старый API: возвращает только выбранный шаблон, всегда в режиме
  /// `snapshot`. Используется существующими callsite-ами.
  static Future<TemplateItem?> show(
    BuildContext context, {
    String? questId,
    Set<TemplateKind>? allowedKinds,
    String? title,
  }) async {
    final picked = await showWithMode(
      context,
      questId: questId,
      allowedKinds: allowedKinds,
      title: title,
      allowLinked: false,
    );
    return picked?.template;
  }

  /// Новый API: предлагает пользователю выбрать режим вставки.
  static Future<TemplatePickResult?> showWithMode(
    BuildContext context, {
    String? questId,
    Set<TemplateKind>? allowedKinds,
    String? title,
    bool allowLinked = true,
  }) {
    return showAdaptiveSheet<TemplatePickResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: TemplatePickerSheet(
          questId: questId,
          allowedKinds: allowedKinds,
          title: title,
          allowLinked: allowLinked,
        ),
      ),
    );
  }

  @override
  ConsumerState<TemplatePickerSheet> createState() =>
      _TemplatePickerSheetState();
}

class _TemplatePickerSheetState extends ConsumerState<TemplatePickerSheet> {
  String _search = '';
  final _searchCtrl = TextEditingController();

  /// Выбранный шаблон, для которого сейчас спрашиваем режим вставки.
  /// `null` — показываем список, иначе — шаг «Копия / Связанный».
  TemplateItem? _modeTemplate;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modeTemplate = _modeTemplate;
    if (modeTemplate != null) return _buildModeChoice(modeTemplate);

    final filter = TemplateScopeFilter(
      questId: widget.questId,
      kinds: widget.allowedKinds,
      search: _search,
    );
    final templatesAsync = ref.watch(combinedTemplatesProvider(filter));

    return SafeArea(
      child: Column(
        children: [
          // Заголовок + handle
          Container(
            margin: const EdgeInsets.only(top: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title ?? tr('Выбор шаблона'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    final imported = await ref
                        .read(templateActionsProvider)
                        .importFromFile();
                    if (!context.mounted) return;
                    if (imported == null) return;
                    // Спрашиваем, куда положить
                    final scope = await _askWhereToImport(context);
                    if (scope == null || !context.mounted) return;
                    if (scope == TemplateScope.global) {
                      await ref
                          .read(templateActionsProvider)
                          .saveAsGlobal(
                            imported.template,
                            bytesBySha: imported.bytesBySha,
                          );
                    } else if (widget.questId != null) {
                      await ref
                          .read(templateActionsProvider)
                          .saveToQuest(widget.questId!, imported.template);
                    }
                  },
                  icon: const Icon(
                    Icons.file_download_outlined,
                    color: Colors.white70,
                  ),
                  tooltip: tr('Импорт из файла'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: tr('Поиск...'),
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: Colors.white54,
                ),
                isDense: true,
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: templatesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    trf('Не удалось загрузить шаблоны: {p0}', {'p0': friendlyError(e)}),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bookmark_border_rounded,
                            size: 56,
                            color: Colors.white24,
                          ),
                          SizedBox(height: 12),
                          Text(
                            tr('Шаблонов пока нет'),
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            tr('Сохраняйте элементы как шаблоны через меню «Сохранить как шаблон» — они появятся здесь.'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) => _TemplateTile(
                    template: list[i],
                    onTap: () => _onTileTap(list[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Тап по шаблону: глава вставляется сразу копией, у остальных сначала
  /// спрашиваем режим — следующим шагом этого же шита, без второго роута.
  Future<void> _onTileTap(TemplateItem template) async {
    // Главы всегда вставляются как snapshot — слишком крупная единица, чтобы
    // безопасно делать always-latest.
    final canLinked =
        widget.allowLinked && template.kind != TemplateKind.chapter;

    if (canLinked) {
      setState(() => _modeTemplate = template);
      return;
    }

    await _finishPick(template, TemplatePickMode.snapshot);
  }

  /// Закрыть пикер выбранным шаблоном и режимом вставки.
  Future<void> _finishPick(TemplateItem template, TemplatePickMode mode) async {
    // Определяем, был ли шаблон в глобальном списке (для последующего
    // pinToQuest). Если questId не задан — это уже глобальный контекст,
    // wasGlobal не имеет смысла, но ставим true для единообразия.
    bool wasGlobal = true;
    if (widget.questId != null) {
      try {
        final quest = await ref.read(
          questTemplatesProvider(widget.questId!).future,
        );
        wasGlobal = !quest.any((t) => t.id == template.id);
      } catch (_) {}
    }

    if (!mounted) return;
    Navigator.pop(
      context,
      TemplatePickResult(template: template, mode: mode, wasGlobal: wasGlobal),
    );
  }

  /// Шаг «как вставлять» внутри шита.
  ///
  /// Раньше здесь открывался AlertDialog поверх bottom sheet: на Android его
  /// барьер перехватывал тапы, и «Копия» / «Связанный» / «Отмена» не
  /// нажимались (#14). Внутри одного шита отдельного барьера нет вовсе.
  Widget _buildModeChoice(TemplateItem template) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 4, bottom: 16),
              alignment: Alignment.center,
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              tr('Как вставить шаблон?'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr('Копия — независимый объект, его можно редактировать; изменения мастер-шаблона на него не повлияют.\n\nСвязанный — отображает актуальный мастер; когда вы измените шаблон, все связанные вхождения обновятся автоматически.'),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () => _finishPick(template, TemplatePickMode.snapshot),
              child: Text(tr('Копия')),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Colors.cyanAccent.withValues(alpha: 0.2),
                foregroundColor: Colors.cyanAccent,
              ),
              onPressed: () => _finishPick(template, TemplatePickMode.linked),
              child: Text(tr('Связанный')),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => setState(() => _modeTemplate = null),
              child: Text(tr('Отмена')),
            ),
          ],
        ),
      ),
    );
  }

  Future<TemplateScope?> _askWhereToImport(BuildContext context) {
    if (widget.questId == null) {
      return Future.value(TemplateScope.global);
    }
    return showAppDialog<TemplateScope>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          tr('Куда добавить шаблон?'),
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, TemplateScope.quest),
            child: Text(tr('В этот квест')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, TemplateScope.global),
            child: Text(tr('Глобально')),
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final TemplateItem template;
  final VoidCallback onTap;
  const _TemplateTile({required this.template, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = _kindColor(template.kind);
    return Material(
      color: const Color(0xFF222222),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: accent.withOpacity(0.4)),
                ),
                child: Icon(_kindIcon(template.kind), color: accent, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      template.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _badge(template.kind.displayName, accent),
                        if (template.category != null) ...[
                          const SizedBox(width: 6),
                          _badge(template.category!, Colors.white24),
                        ],
                      ],
                    ),
                    if (template.description != null &&
                        template.description!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        template.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: Colors.white24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.15),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );

  IconData _kindIcon(TemplateKind kind) {
    switch (kind) {
      case TemplateKind.node:
        return Icons.account_tree_rounded;
      case TemplateKind.row:
        return Icons.table_rows_rounded;
      case TemplateKind.column:
        return Icons.view_column_rounded;
      case TemplateKind.modal:
        return Icons.web_asset_rounded;
      case TemplateKind.content:
        return Icons.widgets_rounded;
      case TemplateKind.chapter:
        return Icons.book_rounded;
      case TemplateKind.multi:
        return Icons.dynamic_feed_rounded;
    }
  }

  Color _kindColor(TemplateKind kind) {
    switch (kind) {
      case TemplateKind.node:
        return Colors.cyanAccent;
      case TemplateKind.row:
        return Colors.orangeAccent;
      case TemplateKind.column:
        return Colors.purpleAccent;
      case TemplateKind.modal:
        return Colors.tealAccent;
      case TemplateKind.content:
        return Colors.lightBlueAccent;
      case TemplateKind.chapter:
        return Colors.greenAccent;
      case TemplateKind.multi:
        return Colors.amberAccent;
    }
  }
}
