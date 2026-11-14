import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/date_format.dart';
import 'package:canvas_app/features/support/models/support_models.dart';
import 'package:canvas_app/features/support/providers/support_provider.dart';
import 'package:canvas_app/features/support/screens/support_ticket_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Инбокс команды: обращения пользователей.
class SupportInboxScreen extends ConsumerWidget {
  const SupportInboxScreen({super.key});

  static const List<String> _filters = ['open', 'answered', 'closed', 'all'];

  static String filterTitle(String filter) => switch (filter) {
    'open' => tr('Ждут ответа'),
    'answered' => tr('Отвечено'),
    'closed' => tr('Закрытые'),
    _ => tr('Все'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(supportInboxProvider);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Text(tr('Обращения')),
        actions: [
          IconButton(
            onPressed: () => ref.read(supportInboxProvider.notifier).load(),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: tr('Обновить'),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final filter in _filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      key: ValueKey('inbox-filter-$filter'),
                      label: Text(filterTitle(filter)),
                      selected: state.filter == filter,
                      onSelected: (_) => ref
                          .read(supportInboxProvider.notifier)
                          .load(filter: filter),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AdaptiveContent(
              maxWidth: 860,
              child: _body(context, ref, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    SupportInboxState state,
  ) {
    final scheme = Theme.of(context).colorScheme;
    if (state.isLoading && state.tickets.isEmpty) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }
    if (state.tickets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.inbox_rounded,
                size: 44,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                state.filter == 'open'
                    ? tr('Новых обращений нет')
                    : tr('Здесь пусто'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (state.error != null) ...[
                const SizedBox(height: 6),
                Text(
                  state.error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: state.tickets.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final ticket = state.tickets[index];
        return _TicketRow(
          ticket: ticket,
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SupportTicketScreen(ticketId: ticket.id),
              ),
            );
            ref.read(supportInboxProvider.notifier).load();
          },
        );
      },
    );
  }
}

class _TicketRow extends StatelessWidget {
  const _TicketRow({required this.ticket, required this.onTap});

  final SupportTicket ticket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final statusColor = switch (ticket.status) {
      'open' => scheme.error,
      'answered' => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };

    return Material(
      color: ticket.unread > 0
          ? scheme.surfaceContainerHigh
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CosmeticAvatar(
                frame: null,
                avatarUrl: ticket.userAvatarUrl,
                radius: 20,
                placeholderColor: scheme.surfaceContainerHighest,
                fallback: Text(
                  (ticket.userName ?? '?').characters.first.toUpperCase(),
                  style: textTheme.labelLarge,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            ticket.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: ticket.unread > 0
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          ticket.lastMessageAt == null
                              ? ''
                              : formatRelativeTime(ticket.lastMessageAt!),
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ticket.userName ?? '',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            ticket.statusTitle,
                            style: textTheme.labelSmall?.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          ticket.categoryTitle,
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        if (ticket.unread > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.error,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${ticket.unread}',
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onError,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Точка входа для админ-панели: одна строка со счётчиком.
class SupportInboxTile extends ConsumerWidget {
  const SupportInboxTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(
      supportInboxProvider.select((state) => state.unreadTotal),
    );
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: const ValueKey('support-inbox-tile'),
      leading: Icon(Icons.support_agent_rounded, color: scheme.primary),
      title: Text(tr('Обращения в поддержку')),
      subtitle: Text(
        unread == 0 ? tr('Нет новых') : trf('Новых: {p0}', {'p0': unread}),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SupportInboxScreen()),
      ),
    );
  }
}