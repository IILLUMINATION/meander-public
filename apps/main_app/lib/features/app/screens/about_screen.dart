// lib/screens/about_screen.dart
//
// О приложении — Material You / Material 3 редизайн.

import 'dart:convert';

import 'package:canvas_app/core/services/build_info_service.dart';
import 'package:canvas_app/core/services/talker_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

// ============================================================================
//  МОДЕЛИ ДАННЫХ
// ============================================================================

class TesterProfile {
  final String name;
  final String description;
  final String avatarAssetPath;

  TesterProfile({
    required this.name,
    required this.description,
    required this.avatarAssetPath,
  });

  factory TesterProfile.fromJson(Map<String, dynamic> json) {
    return TesterProfile(
      name: json['name'] as String,
      description: json['description'] as String,
      avatarAssetPath: json['avatarAssetPath'] as String,
    );
  }
}

class DonorProfile {
  final String name;
  final String message;

  DonorProfile({required this.name, required this.message});

  factory DonorProfile.fromJson(Map<String, dynamic> json) {
    return DonorProfile(
      name: json['name'] as String,
      message: json['message'] as String? ?? '',
    );
  }
}

class SocialLink {
  final String type;
  final String url;

  SocialLink({required this.type, required this.url});

  factory SocialLink.fromJson(Map<String, dynamic> json) {
    return SocialLink(type: json['type'] as String, url: json['url'] as String);
  }
}

class AboutScreenData {
  final List<String> changelog;
  final List<String> notes;
  final String developerName;
  final List<SocialLink> socials;
  final List<TesterProfile> testers;
  final List<DonorProfile> donors;
  final String aboutProject;

  AboutScreenData({
    required this.changelog,
    required this.notes,
    required this.developerName,
    required this.socials,
    required this.testers,
    required this.donors,
    required this.aboutProject,
  });

  factory AboutScreenData.fromJson(Map<String, dynamic> json) {
    return AboutScreenData(
      changelog: List<String>.from(json['changelog']),
      notes: List<String>.from(json['notes']),
      developerName: json['developerName'] as String,
      socials: (json['socials'] as List)
          .map((item) => SocialLink.fromJson(item))
          .toList(),
      testers: (json['testers'] as List)
          .map((item) => TesterProfile.fromJson(item))
          .toList(),
      donors: (json['donors'] as List? ?? [])
          .map((item) => DonorProfile.fromJson(item))
          .toList(),
      aboutProject: json['aboutProject'] as String,
    );
  }
}

// ============================================================================
//  ЭКРАН
// ============================================================================

class AboutScreen extends StatefulWidget {
  /// Позволяет подставить сведения о сборке в тестах. В приложении
  /// `AppBuildInfoService.load()` читает их из `--dart-define` или `.git`.
  final AppBuildInfo? buildInfo;

  const AboutScreen({super.key, this.buildInfo});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  Future<AboutScreenData>? _aboutDataFuture;
  bool _testersExpanded = false;
  String _appVersion = '…';
  late final AppBuildInfo _buildInfo;

  @override
  void initState() {
    super.initState();
    _buildInfo = widget.buildInfo ?? AppBuildInfoService.load();
    _aboutDataFuture = _loadAboutData();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = '${info.version} (${info.buildNumber})';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _appVersion = tr('неизвестно'));
    }
  }

  Future<AboutScreenData> _loadAboutData() async {
    final jsonString = await rootBundle.loadString(
      'assets/data/about_info.json',
    );
    final jsonMap = json.decode(jsonString);
    return AboutScreenData.fromJson(jsonMap);
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      // silent fail
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AdaptiveContent(
        maxWidth: 720,
        child: SafeArea(
          bottom: false,
          child: FutureBuilder<AboutScreenData>(
            future: _aboutDataFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      trf('Ошибка загрузки: {p0}', {'p0': snapshot.error}),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return Center(child: Text(tr('Нет данных')));
              }
              return _buildContent(context, snapshot.data!);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, AboutScreenData data) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverAppBar.large(
          title: Text(tr('О приложении')),
          // Прозрачная подложка пропускала контент списка сквозь крупный
          // заголовок — строки рисовались поверх него.
          backgroundColor: Theme.of(context).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),

        SliverToBoxAdapter(
          child: _VersionHeader(version: _appVersion, buildInfo: _buildInfo),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
        _Header(title: tr('Список изменений'), icon: Icons.auto_awesome_rounded),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _ChangelogItem(text: data.changelog[i]),
              childCount: data.changelog.length,
            ),
          ),
        ),

        if (data.notes.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          _Header(title: tr('Примечания'), icon: Icons.info_outline_rounded),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) =>
                    _ChangelogItem(text: data.notes[i], accent: Colors.amber),
                childCount: data.notes.length,
              ),
            ),
          ),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 32)),
        _Header(title: tr('О нас'), icon: Icons.group_rounded),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(
          child: _DeveloperSection(
            data: data,
            onSocialTap: (s) => _launchUrl(s.url),
          ),
        ),

        if (data.donors.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          _Header(title: tr('Донатёры'), icon: Icons.star_rounded),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(child: _DonorsSection(donors: data.donors)),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
        _Header(title: tr('Тестеры и помощники'), icon: Icons.favorite_rounded),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(
          child: _TestersSection(
            testers: data.testers,
            expanded: _testersExpanded,
            onToggle: () =>
                setState(() => _testersExpanded = !_testersExpanded),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 32)),
        _Header(title: tr('О проекте'), icon: Icons.lightbulb_outline_rounded),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(child: _AboutProject(text: data.aboutProject)),

        const SliverToBoxAdapter(child: SizedBox(height: 32)),
        _Header(title: tr('Поддержка'), icon: Icons.bug_report_rounded),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(child: _DebugSection()),

        const SliverPadding(padding: EdgeInsets.only(bottom: 64)),
      ],
    );
  }
}

// ============================================================================
//  ШАПКА С ВЕРСИЕЙ
// ============================================================================

class _VersionHeader extends StatelessWidget {
  final String version;
  final AppBuildInfo buildInfo;
  const _VersionHeader({required this.version, required this.buildInfo});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primaryContainer, scheme.tertiaryContainer],
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.surface.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.rocket_launch_rounded,
                color: scheme.onPrimaryContainer,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Текущая версия'),
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.onPrimaryContainer.withOpacity(0.8),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    version,
                    style: textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  if (buildInfo.isKnown) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${tr('Ветка')}: ${buildInfo.branch} · '
                      '${tr('Коммит')}: ${buildInfo.commit}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer.withOpacity(0.8),
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  ЗАГОЛОВОК СЕКЦИИ (Sliver)
// ============================================================================

class _Header extends StatelessWidget {
  final String title;
  final IconData icon;
  const _Header({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: scheme.onPrimaryContainer, size: 18),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  ПУНКТ ЧЕЙНДЖЛОГА
// ============================================================================

class _ChangelogItem extends StatelessWidget {
  final String text;
  final Color? accent;
  const _ChangelogItem({required this.text, this.accent});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = accent ?? scheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 12),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  СЕКЦИЯ РАЗРАБОТЧИКА + СОЦСЕТИ
// ============================================================================

class _DeveloperSection extends StatelessWidget {
  final AboutScreenData data;
  final ValueChanged<SocialLink> onSocialTap;
  const _DeveloperSection({required this.data, required this.onSocialTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.person_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Разработчик и дизайнер'),
                        style: textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        data.developerName,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (data.socials.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: data.socials
                  .map(
                    (s) => _SocialChip(social: s, onTap: () => onSocialTap(s)),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _SocialChip extends StatelessWidget {
  final SocialLink social;
  final VoidCallback onTap;
  const _SocialChip({required this.social, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    IconData icon;
    Color color;
    String label;
    switch (social.type) {
      case 'telegram':
        icon = Icons.telegram_rounded;
        color = const Color(0xFF2AABEE);
        label = 'Telegram';
        break;
      case 'youtube':
        icon = Icons.smart_display_rounded;
        color = const Color(0xFFFF0000);
        label = 'YouTube';
        break;
      case 'github':
        icon = Icons.code_rounded;
        color = const Color(0xFF24292F);
        label = 'GitHub';
        break;
      case 'discord':
        icon = Icons.forum_rounded;
        color = const Color(0xFF5865F2);
        label = 'Discord';
        break;
      default:
        icon = Icons.link_rounded;
        color = scheme.primary;
        label = tr('Ссылка');
    }

    return Material(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  СЕКЦИЯ ДОНАТЁРОВ
// ============================================================================

class _DonorsSection extends StatelessWidget {
  final List<DonorProfile> donors;
  const _DonorsSection({required this.donors});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    const gold = Color(0xFFFFB300);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: gold.withOpacity(0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: gold.withOpacity(0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: donors
              .map(
                (d) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.star_rounded, color: gold, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface,
                              height: 1.4,
                            ),
                            children: [
                              TextSpan(
                                text: d.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              if (d.message.isNotEmpty)
                                TextSpan(
                                  text: ' — ${d.message}',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

// ============================================================================
//  СЕКЦИЯ ТЕСТЕРОВ
// ============================================================================

class _TestersSection extends StatelessWidget {
  final List<TesterProfile> testers;
  final bool expanded;
  final VoidCallback onToggle;

  const _TestersSection({
    required this.testers,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final hasMore = testers.length > 3;
    final visible = expanded ? testers : testers.take(3).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOut,
            child: Column(
              children: visible.map((t) => _TesterCard(tester: t)).toList(),
            ),
          ),
          if (hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: onToggle,
                icon: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: Text(
                  expanded ? tr('Скрыть') : trf('Показать ещё {p0}', {'p0': testers.length - 3}),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TesterCard extends StatelessWidget {
  final TesterProfile tester;
  const _TesterCard({required this.tester});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: scheme.surfaceContainerHighest,
            child: ClipOval(
              child: Image.asset(
                tester.avatarAssetPath,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.person_rounded, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tester.name,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tester.description,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  О ПРОЕКТЕ
// ============================================================================

class _AboutProject extends StatelessWidget {
  final String text;
  const _AboutProject({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurface,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  ОТЛАДКА
// ============================================================================

class _DebugSection extends StatelessWidget {
  const _DebugSection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            ListTile(
              leading: Icon(Icons.terminal_rounded, color: scheme.primary),
              title: Text(tr('Консоль разработчика')),
              subtitle: Text(tr('Просмотр логов приложения')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TalkerScreen(talker: talker),
                  ),
                );
              },
            ),
            Divider(
              height: 1,
              indent: 60,
              color: scheme.outlineVariant.withOpacity(0.4),
            ),
            ListTile(
              leading: Icon(Icons.ios_share_rounded, color: scheme.primary),
              title: Text(tr('Отправить логи')),
              subtitle: Text(tr('Для сообщения об ошибке')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => TalkerExportService.exportAndShareLogs(context),
            ),
          ],
        ),
      ),
    );
  }
}
