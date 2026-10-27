import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

import '../models/guide.dart';
import '../services/guide_content_loader.dart';
import '../services/guide_progress_store.dart';
import '../widgets/guide_shot_view.dart';
import '../widgets/guide_video_player.dart';

/// Отдельный экран гайда: видео, схемы со стрелками и статья.
///
/// Всё содержимое приходит из бандла (`assets/guides/…`), поэтому гайд
/// открывается без сети. Язык берётся из того же переключателя, что и весь
/// интерфейс: если перевода гайда ещё нет, загрузчик отдаёт английский.
class GuideScreen extends StatefulWidget {
  final GuideInfo info;

  /// Готовый контент — для тестов и предпросмотра: экран не ходит в бандл.
  final GuideContent? initialContent;

  const GuideScreen({super.key, required this.info, this.initialContent});

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final PageController _pages = PageController();

  late Future<GuideContent?> _future;
  late String _languageCode;
  int _page = 0;
  bool _read = false;

  @override
  void initState() {
    super.initState();
    _languageCode = L10n.code;
    _future = _load();
    _loadRead();
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<GuideContent?> _load() {
    final initial = widget.initialContent;
    if (initial != null) return Future.value(initial);
    return GuideContentLoader.load(widget.info, _languageCode);
  }

  /// Язык мог смениться, пока экран открыт. Возвращаем актуальный future,
  /// не трогая состояние в `build`: `FutureBuilder` создаётся уже с ним.
  Future<GuideContent?> _content() {
    if (widget.initialContent == null && _languageCode != L10n.code) {
      _languageCode = L10n.code;
      _future = GuideContentLoader.load(widget.info, _languageCode);
      _page = 0;
    }
    return _future;
  }

  Future<void> _loadRead() async {
    final read = await GuideProgressStore.isRead(widget.info.id);
    if (!mounted) return;
    setState(() => _read = read);
  }

  Future<void> _finish() async {
    await GuideProgressStore.markRead(widget.info.id);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  void _retry() {
    GuideContentLoader.clearCache();
    setState(() {
      _languageCode = L10n.code;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Гайды'))),
      body: FutureBuilder<GuideContent?>(
        future: _content(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final content = snapshot.data;
          if (content == null) {
            return _GuideError(onRetry: _retry);
          }
          return _GuideBody(
            info: widget.info,
            content: content,
            pages: _pages,
            page: _page,
            read: _read,
            onPageChanged: (index) => setState(() => _page = index),
            onFinish: _finish,
          );
        },
      ),
    );
  }
}

class _GuideBody extends StatelessWidget {
  final GuideInfo info;
  final GuideContent content;
  final PageController pages;
  final int page;
  final bool read;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onFinish;

  const _GuideBody({
    required this.info,
    required this.content,
    required this.pages,
    required this.page,
    required this.read,
    required this.onPageChanged,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860;
        final padding = EdgeInsets.fromLTRB(16, 16, 16, 28);
        final header = _GuideHeader(info: info, content: content, read: read);
        final media = _GuideMedia(
          info: info,
          content: content,
          pages: pages,
          page: page,
          onPageChanged: onPageChanged,
        );
        final article = _GuideArticle(content: content);
        final finish = _FinishButton(read: read, onPressed: onFinish);

        if (wide) {
          return SingleChildScrollView(
            padding: padding,
            child: AdaptiveContent(
              maxWidth: 1180,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 6, child: media),
                      const SizedBox(width: 24),
                      Expanded(flex: 5, child: article),
                    ],
                  ),
                  const SizedBox(height: 24),
                  finish,
                ],
              ),
            ),
          );
        }

        return ListView(
          padding: padding,
          children: [
            header,
            const SizedBox(height: 16),
            media,
            const SizedBox(height: 20),
            article,
            const SizedBox(height: 20),
            finish,
          ],
        );
      },
    );
  }
}

class _GuideHeader extends StatelessWidget {
  final GuideInfo info;
  final GuideContent content;
  final bool read;

  const _GuideHeader({
    required this.info,
    required this.content,
    required this.read,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
              child: Text(
                content.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          content.summary,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _GuideTag(
              icon: Icons.cloud_off_rounded,
              text: tr('Офлайн'),
              accent: info.accent,
            ),
            if (info.videoAsset != null)
              _GuideTag(
                icon: Icons.play_circle_outline_rounded,
                text: tr('Видео'),
                accent: info.accent,
              ),
            _GuideTag(
              icon: Icons.schedule_rounded,
              text: trf('Чтение: {p0} мин', {'p0': content.minutes}),
              accent: info.accent,
            ),
            if (read)
              _GuideTag(
                icon: Icons.check_circle_rounded,
                text: tr('Гайд прочитан'),
                accent: info.accent,
              ),
          ],
        ),
      ],
    );
  }
}

class _GuideTag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color accent;

  const _GuideTag({
    required this.icon,
    required this.text,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: accent),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideMedia extends StatelessWidget {
  final GuideInfo info;
  final GuideContent content;
  final PageController pages;
  final int page;
  final ValueChanged<int> onPageChanged;

  const _GuideMedia({
    required this.info,
    required this.content,
    required this.pages,
    required this.page,
    required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    final videoAsset = info.videoAsset;
    final shots = content.shots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (videoAsset != null) ...[
          GuideVideoPlayer(assetPath: videoAsset, posterAsset: info.posterAsset),
          const SizedBox(height: 20),
        ],
        if (shots.isNotEmpty) ...[
          _SectionTitle(
            icon: Icons.image_outlined,
            text: tr('Схемы с подсказками'),
            accent: info.accent,
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return SizedBox(
                height: width * 10 / 16,
                child: PageView.builder(
                  controller: pages,
                  onPageChanged: onPageChanged,
                  itemCount: shots.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: GuideShotView(
                      shot: shots[index],
                      accent: info.accent,
                      stepIndex: index,
                      stepCount: shots.length,
                      showCaption: false,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _StepCaption(
            index: page,
            shot: shots[page.clamp(0, shots.length - 1)],
            count: shots.length,
            accent: info.accent,
          ),
          const SizedBox(height: 6),
          _StepNav(
            index: page,
            count: shots.length,
            accent: info.accent,
            onSelect: (index) {
              pages.animateToPage(
                index,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
              );
            },
          ),
        ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color accent;

  const _SectionTitle({
    required this.icon,
    required this.text,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: accent),
        const SizedBox(width: 8),
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _StepCaption extends StatelessWidget {
  final int index;
  final GuideShot shot;
  final int count;
  final Color accent;

  const _StepCaption({
    required this.index,
    required this.shot,
    required this.count,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Column(
        key: ValueKey(index),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            trf('Шаг {p0} из {p1}', {'p0': index + 1, 'p1': count}),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: accent,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            shot.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            shot.caption,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StepNav extends StatelessWidget {
  final int index;
  final int count;
  final Color accent;
  final ValueChanged<int> onSelect;

  const _StepNav({
    required this.index,
    required this.count,
    required this.accent,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        IconButton(
          onPressed: index > 0 ? () => onSelect(index - 1) : null,
          icon: const Icon(Icons.chevron_left_rounded),
          visualDensity: VisualDensity.compact,
          tooltip: tr('Назад'),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < count; i++)
                GestureDetector(
                  onTap: () => onSelect(i),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: i == index ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == index
                            ? accent
                            : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: index < count - 1 ? () => onSelect(index + 1) : null,
          icon: const Icon(Icons.chevron_right_rounded),
          visualDensity: VisualDensity.compact,
          tooltip: tr('Далее'),
        ),
      ],
    );
  }
}

class _GuideArticle extends StatelessWidget {
  final GuideContent content;

  const _GuideArticle({required this.content});

  @override
  Widget build(BuildContext context) {
    if (content.article.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.article_outlined,
          text: tr('Статья'),
          accent: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 10),
        MeanderEntityMarkdown(data: content.article),
      ],
    );
  }
}

class _FinishButton extends StatelessWidget {
  final bool read;
  final VoidCallback onPressed;

  const _FinishButton({required this.read, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(read ? Icons.check_rounded : Icons.check_circle_outline_rounded),
      label: Text(tr('Понятно')),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }
}

class _GuideError extends StatelessWidget {
  final VoidCallback onRetry;

  const _GuideError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              tr('Не удалось загрузить гайд'),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onRetry,
              child: Text(tr('Повторить')),
            ),
          ],
        ),
      ),
    );
  }
}
