import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:canvas_app/shared/entity_links/meander_entity.dart';
import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:canvas_app/shared/widgets/image_sizing.dart';

class AppMarkdown {
  /// Тап по ссылке внутри текста. Без этого markdown-виджет любой адрес отдаёт
  /// системному viewer — и человек уезжает в браузер за квестом, который уже
  /// открыт в этом же приложении.
  static void openLink(String url) {
    if (pointsToMeander(url)) {
      DeepLinkService().openUrl(url);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Кэш конфигурации: одна на пару (ColorScheme, TextTheme).
  ///
  /// `getConfig` вызывается из `build` каждого поста и комментария, создавая
  /// десяток конфигов, `TextStyle` и `BoxDecoration` на каждый вызов. Тема за
  /// время жизни экрана не меняется, поэтому хватает identity-ключа.
  static final Map<_ConfigKey, MarkdownConfig> _configCache =
      <_ConfigKey, MarkdownConfig>{};

  static MarkdownConfig getConfig(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Ширина декодирования картинок — часть конфига, поэтому она входит в
    // ключ: после поворота экрана или ресайза окна кэш не отдаёт конфиг со
    // старой шириной (иначе картинки декодировались бы под прежний экран).
    final imagePixels = _imagePixelWidth(context);
    final key = _ConfigKey(scheme, textTheme, imagePixels);
    final cached = _configCache[key];
    if (cached != null) return cached;
    final config = _buildConfig(scheme, textTheme, imagePixels);
    if (_configCache.length >= 8) _configCache.remove(_configCache.keys.first);
    _configCache[key] = config;
    return config;
  }

  /// Ширина декодирования картинок из markdown, в физических пикселях.
  ///
  /// Без `memCacheWidth` `CachedNetworkImage` декодирует фото в исходном
  /// разрешении: 12 Мп — это ~48 МБ на кадр и загрузка той же текстуры в GPU
  /// на каждом появлении в кадре. Ширина экрана (с DPR) — верхняя граница
  /// того, что вообще может быть видно.
  static int _imagePixelWidth(BuildContext context) =>
      imageDecodeWidth(context, max: 1440);

  static MarkdownConfig _buildConfig(
    ColorScheme scheme,
    TextTheme textTheme,
    int imagePixels,
  ) {
    return MarkdownConfig(
      configs: [
        PConfig(
          textStyle:
              textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                height: 1.45,
                fontSize: 14.5,
              ) ??
              TextStyle(color: scheme.onSurface, fontSize: 14.5, height: 1.45),
        ),
        CodeConfig(
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: scheme.onSecondaryContainer,
            backgroundColor: scheme.secondaryContainer.withOpacity(0.5),
          ),
        ),
        PreConfig(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: scheme.onSurface,
          ),
        ),
        BlockquoteConfig(
          textColor: scheme.onSurfaceVariant,
          sideColor: scheme.primary,
          sideWith: 3.0,
          padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
          margin: const EdgeInsets.symmetric(vertical: 8),
        ),
        LinkConfig(
          style: TextStyle(
            color: scheme.primary,
            decoration: TextDecoration.underline,
          ),
          onTap: openLink,
        ),
        ListConfig(
          marker: (isOrdered, depth, index) {
            if (isOrdered) {
              return Text(
                '${index + 1}. ',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Icon(
                Icons.circle,
                size: 6,
                color: scheme.onSurfaceVariant,
              ),
            );
          },
          marginBottom: 4,
          marginLeft: 16,
        ),
        CheckBoxConfig(
          builder: (checked) => Padding(
            padding: const EdgeInsets.only(top: 2, right: 4),
            child: Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: scheme.onSurface,
            ),
          ),
        ),
        ImgConfig(
          builder: (url, attributes) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  memCacheWidth: imagePixels,
                  placeholder: (_, __) => Container(
                    height: 200,
                    color: scheme.surfaceContainerHighest,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    height: 100,
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Ключ кэша конфигурации: тема меняется редко, а identity сравнивается дёшево.
class _ConfigKey {
  const _ConfigKey(this.scheme, this.textTheme, this.imagePixels);

  final ColorScheme scheme;
  final TextTheme textTheme;

  /// Ширина декодирования картинок: зависит от размера экрана, не от темы.
  final int imagePixels;

  @override
  bool operator ==(Object other) =>
      other is _ConfigKey &&
      identical(other.scheme, scheme) &&
      identical(other.textTheme, textTheme) &&
      other.imagePixels == imagePixels;

  @override
  int get hashCode => Object.hash(
    identityHashCode(scheme),
    identityHashCode(textTheme),
    imagePixels,
  );
}

/// Markdown-блок, который не переразбирается на каждом `build`.
///
/// `MarkdownBlock` из пакета — `StatelessWidget`: он вызывает
/// `MarkdownGenerator.buildWidgets` прямо в `build`, то есть полный разбор
/// текста на каждую перестройку. В ленте это происходит и при скролле
/// (элементы пересоздаются), и на каждое событие сокета (лайк где-то на
/// платформе перестраивает видимые посты). Готовое дерево виджетов зависит
/// только от текста и конфигурации, поэтому его можно переиспользовать.
class AppMarkdownBlock extends StatelessWidget {
  const AppMarkdownBlock({
    super.key,
    required this.data,
    required this.config,
    this.selectable = true,
  });

  final String data;
  final MarkdownConfig config;
  final bool selectable;

  /// Предел кэша: при переполнении очищаем целиком, чтобы память не росла
  /// вместе с числом просмотренных постов.
  static const int _cacheLimit = 160;
  static final Map<_BlockKey, List<Widget>> _cache = <_BlockKey, List<Widget>>{};

  static List<Widget> _widgetsFor(String data, MarkdownConfig config) {
    final key = _BlockKey(data, config);
    final cached = _cache[key];
    if (cached != null) return cached;
    final built = MarkdownGenerator().buildWidgets(data, config: config);
    if (_cache.length >= _cacheLimit) _cache.clear();
    _cache[key] = built;
    return built;
  }

  /// Сбросить кэш: сменилась тема или набор строк (например, после правки).
  static void clearCache() => _cache.clear();

  @override
  Widget build(BuildContext context) {
    final widgets = _widgetsFor(data, config);
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
    return selectable ? SelectionArea(child: column) : column;
  }
}

class _BlockKey {
  const _BlockKey(this.data, this.config);

  final String data;
  final MarkdownConfig config;

  @override
  bool operator ==(Object other) =>
      other is _BlockKey &&
      other.data == data &&
      identical(other.config, config);

  @override
  int get hashCode => Object.hash(data, identityHashCode(config));
}
