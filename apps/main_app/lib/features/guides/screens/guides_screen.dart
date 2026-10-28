import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/features/editor/workspace/editor_workspace_scope.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

import '../guide_catalog.dart';
import '../models/guide.dart';
import '../services/guide_content_loader.dart';
import '../services/guide_progress_store.dart';
import 'guide_screen.dart';

/// Каталог вшитых гайдов. Открывается из настроек, чтобы человек мог
/// перечитать объяснение в любой момент, а не только в момент первого
/// входа в раздел.
///
/// С [questId] экран живёт вкладкой воркспейса квеста: гайд открывается
/// соседней вкладкой, а не маршрутом поверх редактора.
class GuidesScreen extends StatefulWidget {
  final String? questId;

  const GuidesScreen({super.key, this.questId});

  @override
  State<GuidesScreen> createState() => _GuidesScreenState();
}

class _GuidesScreenState extends State<GuidesScreen> {
  late Future<List<_GuideCardData>> _future;
  late String _languageCode;
  bool _wasActive = true;

  @override
  void initState() {
    super.initState();
    _languageCode = L10n.code;
    _future = _load();
  }

  /// Вкладку каталога не пересоздают при переключении, поэтому отметки
  /// «прочитан» обновляем, когда она снова становится видимой.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = EditorDocumentContext.maybeOf(context)?.isActive ?? true;
    if (active && !_wasActive) {
      setState(() {
        _languageCode = L10n.code;
        _future = _load();
      });
    }
    _wasActive = active;
  }

  Future<List<_GuideCardData>> _load() async {
    final read = await GuideProgressStore.read();
    return Future.wait(
      GuideCatalog.all.map((info) async {
        final content = await GuideContentLoader.load(info, _languageCode);
        return _GuideCardData(
          info: info,
          content: content,
          read: read.contains(info.id),
        );
      }),
    );
  }

  Future<List<_GuideCardData>> _content() {
    if (_languageCode != L10n.code) {
      _languageCode = L10n.code;
      _future = _load();
    }
    return _future;
  }

  void _retry() {
    GuideContentLoader.clearCache();
    setState(() {
      _languageCode = L10n.code;
      _future = _load();
    });
  }

  Future<void> _open(_GuideCardData card) async {
    final content = card.content;
    if (content == null) return;
    final workspace = EditorWorkspaceScope.maybeOf(context);
    final questId = widget.questId;
    if (workspace != null && questId != null) {
      workspace.openDocument(
        EditorDocumentDescriptor.guide(
          questId,
          card.info.id,
          title: content.title,
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GuideScreen(info: card.info, initialContent: content),
      ),
    );
    if (!mounted) return;
    setState(() {
      _languageCode = L10n.code;
      _future = _load();
    });
  }

  /// Закрывает вкладку каталога; вне воркспейса — обычный pop маршрута.
  Future<void> _close() async {
    if (!mounted) return;
    final document = EditorDocumentContext.maybeOf(context);
    final workspace = EditorWorkspaceScope.maybeOf(context);
    if (document != null && workspace != null) {
      await workspace.closeDocument(document.id);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final embedded =
        EditorDocumentContext.maybeOf(context) != null &&
        EditorWorkspaceScope.maybeOf(context) != null;
    return Scaffold(
      appBar: AppBar(
        leading: embedded
            ? IconButton(
                tooltip: tr('Закрыть вкладку'),
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _close,
              )
            : null,
        title: Text(tr('Гайды')),
      ),
      body: FutureBuilder<List<_GuideCardData>>(
        future: _content(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final cards = snapshot.data ?? const <_GuideCardData>[];
          if (cards.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  tr('Не удалось загрузить гайд'),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return _GuidesBody(cards: cards, onOpen: _open, onRetry: _retry);
        },
      ),
    );
  }
}

class _GuideCardData {
  final GuideInfo info;
  final GuideContent? content;
  final bool read;

  const _GuideCardData({
    required this.info,
    required this.content,
    required this.read,
  });
}

class _GuidesBody extends StatelessWidget {
  final List<_GuideCardData> cards;
  final ValueChanged<_GuideCardData> onOpen;
  final VoidCallback onRetry;

  const _GuidesBody({
    required this.cards,
    required this.onOpen,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final broken = cards.any((card) => card.content == null);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      child: AdaptiveContent(
        maxWidth: 980,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('Офлайн-статьи, видео и схемы с подсказками'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            if (broken) ...[
              const SizedBox(height: 12),
              Material(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                child: ListTile(
                  leading: Icon(Icons.error_outline_rounded, color: scheme.error),
                  title: Text(tr('Не удалось загрузить гайд')),
                  trailing: TextButton(
                    onPressed: onRetry,
                    child: Text(tr('Повторить')),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final twoColumns = constraints.maxWidth >= 760;
                final width = twoColumns
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final card in cards)
                      SizedBox(
                        width: width,
                        child: _GuideCard(
                          card: card,
                          onTap: () => onOpen(card),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideCard extends StatelessWidget {
  final _GuideCardData card;
  final VoidCallback onTap;

  const _GuideCard({required this.card, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = card.content;
    final info = card.info;
    final enabled = content != null;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: info.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(info.icon, color: info.accent, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      content?.title ?? tr('Не удалось загрузить гайд'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (content != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        content.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (info.videoAsset != null)
                            _CardTag(
                              icon: Icons.play_circle_outline_rounded,
                              text: tr('Видео'),
                              accent: info.accent,
                            ),
                          if (content.shots.isNotEmpty)
                            _CardTag(
                              icon: Icons.image_outlined,
                              text: tr('Схемы'),
                              accent: info.accent,
                            ),
                          _CardTag(
                            icon: Icons.schedule_rounded,
                            text: trf(
                              'Чтение: {p0} мин',
                              {'p0': content.minutes},
                            ),
                            accent: info.accent,
                          ),
                          if (card.read)
                            _CardTag(
                              icon: Icons.check_circle_rounded,
                              text: tr('Гайд прочитан'),
                              accent: info.accent,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                enabled
                    ? Icons.chevron_right_rounded
                    : Icons.error_outline_rounded,
                color: enabled ? scheme.onSurfaceVariant : scheme.error,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardTag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color accent;

  const _CardTag({
    required this.icon,
    required this.text,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: accent),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
