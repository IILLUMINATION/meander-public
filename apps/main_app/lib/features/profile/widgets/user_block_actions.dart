import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/community/providers/community_feed_provider.dart';
import 'package:canvas_app/features/forums/providers/forum_provider.dart';
import 'package:canvas_app/features/market/providers/market_provider.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/wall/providers/wall_paginated_provider.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Блокировка автора из ленты и профиля, а не только из переписки.
///
/// Guideline 1.2: человек должен уметь убрать из своего интерфейса любого
/// автора, который ему встретился. Сервер уже не отдаёт посты и квесты
/// заблокированного, но открытые экраны держат старые списки в провайдерах —
/// поэтому после успешного запроса сбрасываем ленты и каталог.
Future<bool> confirmUserBlock(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required bool blocked,
  String? name,
}) async {
  if (!blocked) {
    final allowed = await ensureAccount(
      context,
      why: tr('Блокировка привязана к аккаунту: войдите, чтобы скрыть автора из лент.'),
    );
    if (!allowed || !context.mounted) return false;
  }

  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: scheme.surfaceContainerHigh,
      title: Text(
        blocked ? tr('Разблокировать автора?') : tr('Заблокировать автора?'),
        style: TextStyle(color: scheme.onSurface),
      ),
      content: Text(
        blocked
            ? tr('Их квесты и посты снова появятся в лентах.')
            : tr(
                'Их квесты и посты исчезнут из ваших лент. Разблокировать можно в «Чаты → Приватность».',
              ),
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(
            tr('Отмена'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: blocked ? scheme.primary : scheme.error,
            foregroundColor: blocked ? scheme.onPrimary : scheme.onError,
          ),
          child: Text(
            blocked ? tr('Разблокировать автора') : tr('Заблокировать автора'),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final notifier = ref.read(dmBlocksProvider.notifier);
  final error = blocked
      ? await notifier.unblock(userId)
      : await notifier.blockUser(userId, name: name);
  if (!context.mounted) return false;

  final messenger = ScaffoldMessenger.of(context);
  if (error != null) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(error.isEmpty ? tr('Не удалось изменить блокировку') : error),
        backgroundColor: scheme.error,
      ),
    );
    return false;
  }

  _dropCachedAuthorContent(ref);
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        blocked ? tr('Автор разблокирован') : tr('Автор заблокирован'),
      ),
      backgroundColor: scheme.primary,
    ),
  );
  return true;
}

/// Списки, куда уже успел попасть автор. Каталог сбрасываем целиком: он
/// собирается на сервере и после блокировки приходит без его квестов.
void _dropCachedAuthorContent(WidgetRef ref) {
  ref.invalidate(communityFeedProvider('all'));
  ref.invalidate(communityFeedProvider('following'));
  ref.invalidate(forumHotTopicsProvider);
  ref.invalidate(wallPaginatedProvider);
  ref.invalidate(marketQuestsProviderNew);
  ref.invalidate(marketQuestsProviderPopular);
  ref.invalidate(meanderRecommendsProvider);
  ref.invalidate(verifiedAuthorsQuestsProvider);
  ref.invalidate(undiscoveredQuestsProvider);
  ref.invalidate(searchQuestsProvider);
  ref.invalidate(filteredMarketQuestsProvider);
  ref.invalidate(marketRecentActivityProvider);
}
