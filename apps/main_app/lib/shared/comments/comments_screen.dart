import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';

/// Экран комментариев: шапка с постом, прокручиваемый список комментариев и
/// поле ввода внизу.
///
/// Одна оболочка на все обсуждения — сообщество, каналы, форумы. Отличается
/// только содержимое: экран отдаёт шапку, слойжены списка и своё поле ввода,
/// поэтому «Комментарии» везде выглядят и ведут себя одинаково, а не двумя
/// разными экранами и шторкой.
class CommentsScreen extends StatelessWidget {
  const CommentsScreen({
    super.key,
    required this.header,
    required this.slivers,
    required this.composer,
    this.onRefresh,
    this.actions,
  });

  /// Что комментируют: превью поста, топика или поста канала.
  final Widget header;

  /// Содержимое списка: слойжены комментариев, пустое состояние, ошибка.
  final List<Widget> slivers;

  /// Поле ввода внизу экрана.
  final Widget composer;

  /// Обновление жестом сверху вниз. `null` — без RefreshIndicator.
  final Future<void> Function()? onRefresh;

  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scrollView = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: header),
        SliverToBoxAdapter(
          child: Divider(height: 1, color: scheme.outlineVariant),
        ),
        ...slivers,
      ],
    );

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(
          tr('Комментарии'),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 1,
        actions: actions,
      ),
      body: AdaptiveContent(
        maxWidth: 760,
        child: Column(
          children: [
            Expanded(
              child: onRefresh == null
                  ? scrollView
                  : RefreshIndicator(onRefresh: onRefresh!, child: scrollView),
            ),
            composer,
          ],
        ),
      ),
    );
  }
}