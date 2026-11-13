import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mnd_player/utils/file_storage.dart';

/// Картинка из каталога приложения по относительному пути.
///
/// Два отличия от «FutureBuilder прямо в build», который был в сетках:
/// 1. путь резолвится один раз на состояние — при перестройке родителя не
///    создаётся новый `Future` (это давало лишний кадр с заглушкой и мигание
///    на каждом ребилде);
/// 2. `cacheWidth` обязателен по смыслу: тайл сетки 48-280 px не должен
///    декодировать исходник 2000×2000 (≈16 МБ) в полном размере.
class LocalFileImage extends StatefulWidget {
  const LocalFileImage({
    super.key,
    required this.relativePath,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.width,
    this.height,
    this.placeholder,
    this.errorBuilder,
    this.checkExists = false,
  });

  /// Путь относительно каталога приложения (`FileStorage.getFilePath`).
  final String relativePath;
  final BoxFit fit;
  final int? cacheWidth;
  final double? width;
  final double? height;

  /// Что рисовать, пока путь резолвится.
  final Widget? placeholder;
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Проверять `existsSync` перед отрисовкой (нужно там, где заглушка «нет
  /// файла» отличается от заглушки «файла ещё нет»).
  final bool checkExists;

  @override
  State<LocalFileImage> createState() => _LocalFileImageState();
}

class _LocalFileImageState extends State<LocalFileImage> {
  late Future<String> _path = FileStorage.getFilePath(widget.relativePath);

  @override
  void didUpdateWidget(LocalFileImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.relativePath != widget.relativePath) {
      _path = FileStorage.getFilePath(widget.relativePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _path,
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path == null) {
          return widget.placeholder ?? const SizedBox.shrink();
        }
        final file = File(path);
        if (widget.checkExists && !file.existsSync()) {
          return widget.placeholder ?? const SizedBox.shrink();
        }
        return Image.file(
          file,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          width: widget.width,
          height: widget.height,
          errorBuilder: widget.errorBuilder,
        );
      },
    );
  }
}
