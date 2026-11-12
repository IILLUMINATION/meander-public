import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';

const String _playListingUrl =
    'https://play.google.com/store/apps/details?id=com.IILLUMINAT.meadner';

class UpdateScreen extends StatelessWidget {
  final String version;
  final String changelog;
  final String downloadUrl;
  final bool isCritical;

  const UpdateScreen({
    super.key,
    required this.version,
    required this.changelog,
    required this.downloadUrl,
    this.isCritical = false,
  });

  /// Куда ведёт кнопка «Скачать». Android всегда берёт листинг в Play —
  /// серверный `download_url` для него это просто сайт. Остальным платформам
  /// некуда идти, если админ прислал пустую или не-ссылку: `_target == null`,
  /// и экран обязан оставить выход (см. «Позже» ниже).
  Uri? get _target {
    if (Platform.isAndroid) return Uri.parse(_playListingUrl);
    final uri = Uri.tryParse(downloadUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  Future<void> _openDownload(BuildContext context) async {
    final uri = _target;
    if (uri == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf(
                'Ссылка на загрузку не задана — зайдите на {p0}',
                {'p0': AppConfig.siteHost},
              ),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!context.mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Не удалось открыть ссылку')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!isCritical) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final lines = changelog
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();

    final iconBg = isCritical ? scheme.errorContainer : scheme.primaryContainer;
    final iconFg = isCritical
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;

    return PopScope(
      canPop: !isCritical || _target == null,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: iconBg,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(
                        isCritical
                            ? Icons.warning_rounded
                            : Icons.system_update_rounded,
                        color: iconFg,
                        size: 40,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      isCritical
                          ? tr('Обязательное обновление')
                          : tr('Доступно обновление'),
                      textAlign: TextAlign.center,
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      trf('Версия {version}', {'version': version}),
                      style: textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              if (lines.isNotEmpty)
                Expanded(
                  flex: 2,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: lines
                          .map(
                            (line) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: scheme.primary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      line.trim(),
                                      style: textTheme.bodyMedium?.copyWith(
                                        color: scheme.onSurface,
                                        height: 1.5,
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
                )
              else
                const Expanded(flex: 2, child: SizedBox.shrink()),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton(
                        onPressed: () => _openDownload(context),
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          tr('Скачать'),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ),
                    ),
                    // Обязательное обновление обычно не-dismissнуть. Но если
                    // идти некуда (ссылки нет), экран-ловушка блокирует
                    // приложение целиком — в этом случае выход оставляем.
                    if (!isCritical || _target == null) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.onSurfaceVariant,
                            side: BorderSide(color: scheme.outlineVariant),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            tr('Позже'),
                            style: TextStyle(fontSize: 17),
                          ),
                        ),
                      ),
                    ],
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
