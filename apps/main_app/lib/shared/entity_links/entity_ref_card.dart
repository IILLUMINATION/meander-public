import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/features/market/screens/quest_market_details_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:canvas_app/shared/entity_links/meander_entity.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// Человек, на которого ссылка хочет показать карточку.
///
/// Разбор свой, а не `UserProfile.fromJson`: тот требует `created_at` и `id` и
/// падает на ответе без них, а карточке нужны четыре поля. Молчание лучше
/// падения — ссылка не обязана быть живой.
class LinkedProfile {
  const LinkedProfile({
    required this.name,
    this.avatarUrl,
    this.equipped = EquippedCosmetics.none,
    this.isVerified = false,
  });

  final String name;
  final String? avatarUrl;
  final EquippedCosmetics equipped;
  final bool isVerified;

  static const notFound = LinkedProfile(name: '');

  bool get exists => name.isNotEmpty;

  static LinkedProfile fromJson(Map<dynamic, dynamic> json) => LinkedProfile(
    name: (json['full_name'] ?? '').toString().trim(),
    avatarUrl: json['avatar_url']?.toString(),
    equipped: EquippedCosmetics.fromJson(json['cosmetics']),
    isVerified: json['is_verified'] == true,
  );
}

final linkedProfileProvider = FutureProvider.autoDispose
    .family<LinkedProfile, String>((ref, userId) async {
      final api = ref.watch(apiServiceProvider);
      try {
        final response = await api.get('profiles/$userId');
        if (response is Map) return LinkedProfile.fromJson(response);
      } catch (_) {
        // Профиля может и не быть: ссылка старше человека или аккаунт удалили.
      }
      return LinkedProfile.notFound;
    });

/// Тип по голому uuid. У квеста, человека и поста один и тот же формат id,
/// поэтому единственный честный способ — спросить бэкенды там, где они есть.
final unknownEntityProvider = FutureProvider.autoDispose
    .family<MeanderEntityKind, String>((ref, id) async {
      final api = ref.read(apiServiceProvider);
      try {
        final quest = await api.get('quests/$id');
        if (quest is Map && (quest['id'] ?? quest['title']) != null) {
          return MeanderEntityKind.quest;
        }
      } catch (_) {}
      try {
        final profile = await api.get('profiles/$id');
        if (profile is Map && (profile['full_name'] ?? '').toString().isNotEmpty) {
          return MeanderEntityKind.profile;
        }
      } catch (_) {}
      return MeanderEntityKind.post;
    });

/// Ссылка на квест, человека или пост, ставшая карточкой.
///
/// Это не украшение: до неё такой текст был адресом, по которому приложение
/// уезжало в браузер, а голый uuid вообще нельзя было нажать.
class MeanderEntityCard extends ConsumerWidget {
  const MeanderEntityCard({super.key, required this.entity});

  final MeanderEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (entity.kind == MeanderEntityKind.unknown) {
      return _UnknownEntityCard(id: entity.id);
    }
    return switch (entity.kind) {
      MeanderEntityKind.quest => _QuestCard(questId: entity.id),
      MeanderEntityKind.profile => _ProfileCard(userId: entity.id),
      MeanderEntityKind.post => _PostCard(postId: entity.id),
      MeanderEntityKind.unknown => const SizedBox.shrink(),
    };
  }
}

/// Голый uuid: пока резолвер не скажет, человек это, квест или пост, карточка
/// не врет про тип — иначе под «Квестом» откроется профиль.
class _UnknownEntityCard extends ConsumerWidget {
  const _UnknownEntityCard({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(unknownEntityProvider(id));
    return kind.when(
      loading: () => _Frame(
        label: tr('Ссылка'),
        onTap: null,
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      error: (_, _) => _missing(context, label: tr('Ссылка')),
      data: (resolved) =>
          MeanderEntityCard(entity: MeanderEntity(kind: resolved, id: id)),
    );
  }
}

class _QuestCard extends ConsumerWidget {
  const _QuestCard({required this.questId});

  final String questId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Тот же провайдер, что у загрузчика: открыв карточку, человек идёт по
    // уже загруженному квесту, а не ждёт второй запрос.
    final quest = ref.watch(marketQuestProvider(questId));

    return quest.when(
      loading: () => _Frame(label: tr('Квест'), onTap: null, child: _skeleton()),
      error: (_, _) => _missing(context, label: tr('Квест')),
      data: (data) => _Frame(
        label: tr('Квест'),
        onTap: () => _pushQuest(context, questId),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Thumb(url: data.previewImageUrl, icon: Icons.menu_book_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if ((data.authorName ?? '').isNotEmpty)
                        data.authorName!,
                      if (data.downloadsCount > 0)
                        trf('{n} скачив.', {'n': data.downloadsCount}),
                      if (data.averageRating > 0)
                        trf('рейтинг {rating}', {
                          'rating': data.averageRating.toStringAsFixed(1),
                        }),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: scheme.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(linkedProfileProvider(userId));

    return profile.when(
      loading: () => _Frame(label: tr('Профиль'), onTap: null, child: _skeleton()),
      error: (_, _) => _missing(context, label: tr('Профиль')),
      data: (data) {
        if (!data.exists) return _missing(context, label: tr('Профиль'));
        return _Frame(
          label: tr('Профиль'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ProfileScreen(userId: userId)),
          ),
          child: Row(
            children: [
              CosmeticAvatar(
                frame: cosmeticById(data.equipped.avatarFrame),
                radius: 20,
                avatarUrl: data.avatarUrl,
                placeholderColor: scheme.surfaceContainerHighest,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CosmeticNameText(
                  name: data.name,
                  def: cosmeticById(data.equipped.nameStyle),
                  maxLines: 1,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (data.isVerified)
                Icon(
                  Icons.verified_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Пост: отдельного «лёгкого» ответа у бэка нет, зато есть загрузчик, который
/// сам достанет пост и покажет тред. Карточка честно говорит, куда ведёт.
class _PostCard extends ConsumerWidget {
  const _PostCard({required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _Frame(
      label: tr('Пост'),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PostLinkLoaderScreen(postId: postId)),
      ),
      child: Row(
        children: [
          const _Thumb(url: null, icon: Icons.mode_comment_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tr('Пост в сообществе'),
              maxLines: 2,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: scheme.onSurfaceVariant,
            size: 20,
          ),
        ],
      ),
    );
  }
}

void _pushQuest(BuildContext context, String questId) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => MarketQuestLoaderScreen(questId: questId),
    ),
  );
}

/// Куда ведёт ссылка: своя страница открывается приложением. До этого любой
/// адрес уходил в системный viewer, и человек терял приложение посреди поста.
void openMeanderEntity(BuildContext context, MeanderEntity entity) {
  switch (entity.kind) {
    case MeanderEntityKind.quest:
      _pushQuest(context, entity.id);
    case MeanderEntityKind.profile:
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileScreen(userId: entity.id),
        ),
      );
    case MeanderEntityKind.post:
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PostLinkLoaderScreen(postId: entity.id),
        ),
      );
    case MeanderEntityKind.unknown:
      break;
  }
}

class _Frame extends StatelessWidget {
  const _Frame({
    required this.label,
    required this.child,
    required this.onTap,
  });

  final String label;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 6),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url, required this.icon});

  final String? url;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = url;
    Widget placeholder() => Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
    );

    if (link == null || link.isEmpty) return placeholder();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: link,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder(),
        errorWidget: (_, _, _) => placeholder(),
      ),
    );
  }
}

Widget _skeleton() => const SizedBox(height: 40);

Widget _missing(BuildContext context, {required String label}) => _Frame(
  label: label,
  onTap: null,
  child: Text(
    trf('{label} больше недоступен', {'label': label}),
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  ),
);

/// Текст с карточками вместо ссылок — для поверхностей, где пользовательское
/// сообщение рисуется обычным `Text` (описание квеста, обзор, био, сообщение).
class MeanderEntityText extends StatelessWidget {
  const MeanderEntityText({
    super.key,
    required this.data,
    this.style,
    this.selectable = false,
    this.maxLines,
    this.overflow,
  });

  final String data;
  final TextStyle? style;
  final bool selectable;

  /// Ограничение строкой работает, пока в тексте нет карточек: сворачивать
  /// карточку в многоточие нельзя, она либо видна, либо её нет.
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final segments = splitMeanderEntities(data);
    if (!segments.any((segment) => segment.isEntity)) {
      return selectable
          ? SelectableText(data, style: style, maxLines: maxLines)
          : Text(data, style: style, maxLines: maxLines, overflow: overflow);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in segments)
          if (segment.isEntity)
            MeanderEntityCard(entity: segment.entity!)
          else if (segment.text.trim().isNotEmpty)
            Text(segment.text, style: style),
      ],
    );
  }
}

/// То же для markdown (посты, комментарии, предпросмотр редактора): текст
/// режется по ссылкам, и каждый кусок верстится отдельно.
///
/// `MarkdownBlock` — это колонка блочных виджетов, так что встроить карточку
/// внутрь абзаца нельзя; карточка становится блоком под своим абзацем, как
/// линк-флэр в других соцсетях.
/// Ссылка внутри строки текста — для пузырей переписки и других мест, где
/// карточка-блок разрушила бы вёрстку (пузырь раскрашен, и тёмная рамка
/// внутри него выглядела бы чужеродной). Слово остаётся словом, но нажимается.
class MeanderEntityLinkText extends ConsumerWidget {
  const MeanderEntityLinkText({
    super.key,
    required this.data,
    this.style,
    this.selectable = false,
  });

  final String data;
  final TextStyle? style;
  final bool selectable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final segments = splitMeanderEntities(data);
    if (!segments.any((segment) => segment.isEntity)) {
      return selectable
          ? SelectableText(data, style: style)
          : Text(data, style: style);
    }

    final scheme = Theme.of(context).colorScheme;
    final linkStyle = (style ?? const TextStyle()).copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
    );

    final spans = <InlineSpan>[];
    for (final segment in segments) {
      if (!segment.isEntity) {
        spans.add(TextSpan(text: segment.text, style: style));
        continue;
      }
      final entity = segment.entity!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InlineEntityLink(entity: entity, style: linkStyle),
        ),
      );
    }

    return Text.rich(TextSpan(children: spans));
  }
}

/// Одна ссылка внутри строки: тип дотягивается резолвером только в момент
/// тапа, иначе каждый голый uuid в переписке стоил бы запроса к бэкенду.
class _InlineEntityLink extends ConsumerStatefulWidget {
  const _InlineEntityLink({required this.entity, required this.style});

  final MeanderEntity entity;
  final TextStyle style;

  @override
  ConsumerState<_InlineEntityLink> createState() => _InlineEntityLinkState();
}

class _InlineEntityLinkState extends ConsumerState<_InlineEntityLink> {
  bool _resolving = false;

  Future<void> _open() async {
    var entity = widget.entity;
    if (entity.kind == MeanderEntityKind.unknown) {
      setState(() => _resolving = true);
      try {
        final kind = await ref.read(
          unknownEntityProvider(entity.id).future,
        );
        entity = MeanderEntity(kind: kind, id: entity.id);
      } finally {
        if (mounted) setState(() => _resolving = false);
      }
    }
    if (!mounted) return;
    openMeanderEntity(context, entity);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _resolving ? null : _open,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Text(
          _resolving ? '…' : _label(context),
          style: widget.style,
        ),
      ),
    );
  }

  String _label(BuildContext context) {
    final word = switch (widget.entity.kind) {
      MeanderEntityKind.quest => tr('квест'),
      MeanderEntityKind.profile => tr('профиль'),
      MeanderEntityKind.post => tr('пост'),
      MeanderEntityKind.unknown => tr('ссылка'),
    };
    return '$word · ${widget.entity.id.substring(0, 8)}';
  }
}

class MeanderEntityMarkdown extends StatelessWidget {
  const MeanderEntityMarkdown({super.key, required this.data, this.config});

  final String data;

  /// Конфигурация текста: по умолчанию общая тема приложения, экран может
  /// передать свою (например, уже вычисленную для свёрнутого состояния).
  final MarkdownConfig? config;

  @override
  Widget build(BuildContext context) {
    final markdownConfig = config ?? AppMarkdown.getConfig(context);
    Widget renderText(String chunk) =>
        AppMarkdownBlock(data: chunk, config: markdownConfig);

    final segments = splitMeanderEntities(data);
    if (!segments.any((segment) => segment.isEntity)) {
      return renderText(data);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in segments)
          if (segment.isEntity)
            MeanderEntityCard(entity: segment.entity!)
          else if (segment.text.trim().isNotEmpty)
            renderText(segment.text),
      ],
    );
  }
}
