import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/theme/banner_presets.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/models/user_profile_model.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

// ============================================================================
//  BANNER (обложка профиля) — фоновый decoration по пресету
//
//  Выбор фона переехал в витрину оформления (cosmetics_screen.dart): там
//  пресеты — обычные предметы каталога, а не отдельный sheet.
// ============================================================================

/// Возвращает Decoration для шапки профиля: либо из выбранного пресета,
/// либо дефолтный градиент из текущей темы.
BoxDecoration profileBannerDecoration(
  BuildContext context, {
  ProfileBannerStyle? style,
  BorderRadiusGeometry? borderRadius,
}) {
  final scheme = Theme.of(context).colorScheme;
  final preset = bannerPresetById(style?.id);
  final radius = borderRadius ?? BorderRadius.circular(24);

  if (preset != null) {
    return BoxDecoration(borderRadius: radius, gradient: preset.toGradient());
  }
  return BoxDecoration(
    borderRadius: radius,
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        scheme.primaryContainer,
        scheme.tertiaryContainer.withOpacity(0.7),
      ],
    ),
  );
}

// ============================================================================
//  SOCIAL LINKS — ряд кнопок + редактор
// ============================================================================

/// Описание платформы соцсети для UI.
class SocialPlatform {
  final String id;
  final String label;
  final IconData icon;
  final Color color;
  final String hint;

  const SocialPlatform({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
    required this.hint,
  });
}

// Геттер, а не final-таблица: список строится под текущий язык, иначе
// переключение языка не перекрасило бы эти подписи.
List<SocialPlatform> get kSocialPlatforms => [
  SocialPlatform(
    id: 'telegram',
    label: 'Telegram',
    icon: Icons.send_rounded,
    color: Color(0xFF2AABEE),
    hint: 'https://t.me/your_name',
  ),
  SocialPlatform(
    id: 'youtube',
    label: 'YouTube',
    icon: Icons.play_circle_rounded,
    color: Color(0xFFE53935),
    hint: 'https://youtube.com/@channel',
  ),
  SocialPlatform(
    id: 'vk',
    label: 'VK',
    icon: Icons.group_rounded,
    color: Color(0xFF4A76A8),
    hint: 'https://vk.com/your_name',
  ),
  SocialPlatform(
    id: 'instagram',
    label: 'Instagram',
    icon: Icons.camera_alt_rounded,
    color: Color(0xFFE4405F),
    hint: 'https://instagram.com/your_name',
  ),
  SocialPlatform(
    id: 'x',
    label: 'X (Twitter)',
    icon: Icons.alternate_email_rounded,
    color: Color(0xFF1DA1F2),
    hint: 'https://x.com/your_name',
  ),
  SocialPlatform(
    id: 'github',
    label: 'GitHub',
    icon: Icons.code_rounded,
    color: Color(0xFF24292E),
    hint: 'https://github.com/your_name',
  ),
  SocialPlatform(
    id: 'boosty',
    label: 'Boosty',
    icon: Icons.volunteer_activism_rounded,
    color: Color(0xFFFF7043),
    hint: 'https://boosty.to/your_name',
  ),
  SocialPlatform(
    id: 'discord',
    label: 'Discord',
    icon: Icons.chat_rounded,
    color: Color(0xFF5865F2),
    hint: 'https://discord.gg/...',
  ),
  SocialPlatform(
    id: 'tiktok',
    label: 'TikTok',
    icon: Icons.music_note_rounded,
    color: Color(0xFF010101),
    hint: 'https://tiktok.com/@your_name',
  ),
  SocialPlatform(
    id: 'website',
    label: tr('Сайт'),
    icon: Icons.public_rounded,
    color: Color(0xFF4CAF50),
    hint: 'https://your.site',
  ),
];

SocialPlatform socialPlatformById(String id) {
  for (final p in kSocialPlatforms) {
    if (p.id == id) return p;
  }
  // fallback
  return SocialPlatform(
    id: 'website',
    label: tr('Ссылка'),
    icon: Icons.link_rounded,
    color: Color(0xFF607D8B),
    hint: 'https://...',
  );
}

/// Горизонтальный ряд иконок-кнопок соцсетей пользователя.
class SocialLinksRow extends StatelessWidget {
  final List<SocialLink> links;

  const SocialLinksRow({super.key, required this.links});

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const SizedBox.shrink();
    // Компактные круглые иконки вместо цветных пилюль с подписями:
    // четыре соцсети занимали две строки и весили больше, чем имя и био.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: links.map((link) {
        final platform = socialPlatformById(link.platform);
        return Tooltip(
          message: platform.label,
          child: Material(
            color: platform.color.withValues(alpha: 0.12),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () async {
                final uri = Uri.tryParse(link.url);
                if (uri == null) return;
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(platform.icon, color: platform.color, size: 18),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Bottom-sheet для редактирования соцсетей.
Future<void> showSocialLinksEditor({
  required BuildContext context,
  required WidgetRef ref,
  required String userId,
  required List<SocialLink> current,
}) async {
  await showAdaptiveSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        _SocialLinksEditorSheet(ref: ref, userId: userId, current: current),
  );
}

class _SocialLinksEditorSheet extends StatefulWidget {
  final WidgetRef ref;
  final String userId;
  final List<SocialLink> current;

  const _SocialLinksEditorSheet({
    required this.ref,
    required this.userId,
    required this.current,
  });

  @override
  State<_SocialLinksEditorSheet> createState() =>
      _SocialLinksEditorSheetState();
}

class _SocialLinksEditorSheetState extends State<_SocialLinksEditorSheet> {
  late List<SocialLink> _items;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _items = List<SocialLink>.from(widget.current);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.link_rounded, color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  tr('Соцсети'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  tr('У вас пока нет добавленных ссылок.'),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < _items.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _SocialEditRow(
                            platform: socialPlatformById(_items[i].platform),
                            url: _items[i].url,
                            onPlatformChange: (newId) {
                              setState(() {
                                _items[i] = _items[i].copyWith(platform: newId);
                              });
                            },
                            onUrlChange: (newUrl) {
                              _items[i] = _items[i].copyWith(url: newUrl);
                            },
                            onDelete: () => setState(() => _items.removeAt(i)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _items.length >= 8
                    ? null
                    : () {
                        setState(() {
                          _items.add(
                            const SocialLink(platform: 'telegram', url: ''),
                          );
                        });
                      },
                icon: const Icon(Icons.add_rounded),
                label: Text(tr('Добавить ссылку')),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isSaving
                    ? null
                    : () async {
                        final clean = _items
                            .where((e) => e.url.trim().isNotEmpty)
                            .map((e) => e.copyWith(url: e.url.trim()))
                            .toList();
                        setState(() => _isSaving = true);
                        try {
                          await widget.ref
                              .read(apiServiceProvider)
                              .post(
                                'profiles/me',
                                body: {
                                  'social_links': clean
                                      .map((e) => e.toJson())
                                      .toList(),
                                },
                              );
                          widget.ref.invalidate(
                            userProfileProvider(widget.userId),
                          );
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) {
                            setState(() => _isSaving = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  trf('Ошибка: {p0}', {'p0': friendlyError(e)}),
                                ),
                              ),
                            );
                          }
                        }
                      },
                icon: _isSaving
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(tr('Сохранить')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SocialEditRow extends StatefulWidget {
  final SocialPlatform platform;
  final String url;
  final ValueChanged<String> onPlatformChange;
  final ValueChanged<String> onUrlChange;
  final VoidCallback onDelete;

  const _SocialEditRow({
    required this.platform,
    required this.url,
    required this.onPlatformChange,
    required this.onUrlChange,
    required this.onDelete,
  });

  @override
  State<_SocialEditRow> createState() => _SocialEditRowState();
}

class _SocialEditRowState extends State<_SocialEditRow> {
  late final TextEditingController _ctrl;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.url);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _SocialEditRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && _ctrl.text != widget.url) {
      _ctrl.text = widget.url;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: tr('Платформа'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            onSelected: widget.onPlatformChange,
            itemBuilder: (_) => kSocialPlatforms
                .map(
                  (p) => PopupMenuItem(
                    value: p.id,
                    child: Row(
                      children: [
                        Icon(p.icon, color: p.color, size: 18),
                        const SizedBox(width: 10),
                        Text(p.label),
                      ],
                    ),
                  ),
                )
                .toList(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: widget.platform.color.withOpacity(0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.platform.icon,
                color: widget.platform.color,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              focusNode: _focusNode,
              controller: _ctrl,
              onChanged: widget.onUrlChange,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.platform.hint,
                hintStyle: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.delete_outline_rounded,
              color: scheme.error,
              size: 20,
            ),
            tooltip: tr('Удалить'),
            onPressed: widget.onDelete,
          ),
        ],
      ),
    );
  }
}
