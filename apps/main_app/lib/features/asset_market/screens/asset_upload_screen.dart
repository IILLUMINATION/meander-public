import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/asset_market/providers/asset_provider.dart';
import 'package:canvas_app/features/music_library/providers/music_provider.dart';
import 'package:canvas_app/core/utils/error_text.dart';

class AssetUploadScreen extends ConsumerStatefulWidget {
  final String kind; // button_preset, background, sfx, font, music
  const AssetUploadScreen({super.key, required this.kind});
  @override
  ConsumerState<AssetUploadScreen> createState() => _AssetUploadScreenState();
}

class _AssetUploadScreenState extends ConsumerState<AssetUploadScreen> {
  final _title = TextEditingController();
  final _performer = TextEditingController();
  final _genre = TextEditingController();
  final _license = TextEditingController(text: 'CC-BY');
  final _desc = TextEditingController();
  File? _file;
  File? _cover;
  bool _isUploading = false;
  double _progress = 0;

  String get _kindLabel {
    switch (widget.kind) {
      case 'button_preset':
        return tr('Пресет кнопки');
      case 'background':
        return tr('Фон');
      case 'image':
        return tr('Изображение');
      case 'sfx':
        return tr('Звук');
      case 'font':
        return tr('Шрифт');
      case 'music':
        return tr('Музыка');
      default:
        return widget.kind;
    }
  }

  List<String> get _allowedExt {
    switch (widget.kind) {
      case 'button_preset':
        return ['json'];
      case 'font':
        return ['ttf', 'otf', 'woff', 'woff2'];
      case 'sfx':
        return ['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac'];
      case 'background':
      case 'image':
        return ['jpg', 'jpeg', 'png', 'webp'];
      case 'music':
        return ['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac'];
      default:
        return ['jpg', 'png', 'mp3', 'json', 'ttf'];
    }
  }

  String get _fileLabel {
    switch (widget.kind) {
      case 'button_preset':
        return tr('JSON пресет *');
      case 'font':
        return tr('Файл шрифта *');
      case 'sfx':
        return tr('Аудио файл *');
      case 'background':
        return tr('Изображение фона *');
      case 'music':
        return tr('Аудио файл *');
      default:
        return tr('Файл *');
    }
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExt,
    );
    if (res.isNotEmpty && res.first.path != null && mounted) {
      setState(() => _file = File(res.first.path!));
    }
  }

  Future<void> _pickCover() async {
    final res = await FilePicker.pickFiles(type: FileType.image);
    if (res.isNotEmpty && res.first.path != null && mounted) {
      setState(() => _cover = File(res.first.path!));
    }
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty ||
        _license.text.trim().isEmpty ||
        _file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Заполните обязательные поля и выберите файл')),
        ),
      );
      return;
    }
    if (widget.kind == 'music' && _performer.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Укажите исполнителя'))));
      return;
    }
    setState(() {
      _isUploading = true;
      _progress = 0.1;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token') ?? '';
      final isMusic = widget.kind == 'music';
      final uri = Uri.parse(
        isMusic ? '${AppConfig.apiUrl}/music' : '${AppConfig.apiUrl}/assets',
      );
      final req = http.MultipartRequest('POST', uri);
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      if (isMusic) {
        req.fields['title'] = _title.text.trim();
        req.fields['performer'] = _performer.text.trim();
        req.fields['genre'] = _genre.text.trim();
        req.fields['license'] = _license.text.trim();
        req.fields['description'] = _desc.text.trim();
        req.files.add(
          await http.MultipartFile.fromPath('musicFile', _file!.path),
        );
        if (_cover != null)
          req.files.add(
            await http.MultipartFile.fromPath('cover', _cover!.path),
          );
      } else {
        req.fields['kind'] = widget.kind;
        req.fields['title'] = _title.text.trim();
        req.fields['genre'] = _genre.text.trim();
        req.fields['license'] = _license.text.trim();
        req.fields['description'] = _desc.text.trim();
        req.files.add(
          await http.MultipartFile.fromPath('assetFile', _file!.path),
        );
        if (_cover != null)
          req.files.add(
            await http.MultipartFile.fromPath('cover', _cover!.path),
          );
      }
      if (mounted) setState(() => _progress = 0.3);
      final streamed = await req.send();
      if (mounted) setState(() => _progress = 0.7);
      final respStr = await streamed.stream.bytesToString();
      if (mounted) setState(() => _progress = 1.0);
      await Future.delayed(const Duration(milliseconds: 300));
      if (streamed.statusCode == 201) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('Отправлено на модерацию'))),
          );
          ref.invalidate(assetListProvider);
          ref.invalidate(musicTracksProvider);
          Navigator.pop(context, true);
        }
      } else if (streamed.statusCode == 429) {
        throw Exception(tr('Лимит 5/час'));
      } else if (streamed.statusCode == 409) {
        throw Exception(tr('Дубликат файла'));
      } else {
        throw Exception('HTTP ${streamed.statusCode}: $respStr');
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
          ),
        );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _performer.dispose();
    _genre.dispose();
    _license.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Text(
          tr('Новый ресурс'),
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _UploadIntroCard(kindLabel: _kindLabel, formats: _allowedExt),
                const SizedBox(height: 16),
                // File pickers
                _FilePickerTile(
                  label: _fileLabel,
                  file: _file,
                  allowed: _allowedExt.join(', '),
                  onPick: _pickFile,
                  onClear: () => setState(() => _file = null),
                ),
                const SizedBox(height: 12),
                // Превью отдельно нужно только для аудио/пресетов. Для фонов — сам файл и есть превью.
                if (widget.kind == 'music' || widget.kind == 'sfx') ...[
                  _FilePickerTile(
                    label: tr('Обложка (необязательно)'),
                    file: _cover,
                    allowed: 'jpg, png, webp',
                    onPick: _pickCover,
                    onClear: () => setState(() => _cover = null),
                  ),
                  const SizedBox(height: 12),
                ],
                if (widget.kind == 'button_preset') ...[
                  _FilePickerTile(
                    label: tr('Превью (картинка кнопки)'),
                    file: _cover,
                    allowed: 'jpg, png, webp',
                    onPick: _pickCover,
                    onClear: () => setState(() => _cover = null),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _title,
                  decoration: InputDecoration(
                    labelText: tr('Название *'),
                    hintText: tr('Например: Ночной город'),
                    border: OutlineInputBorder(),
                    filled: true,
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                if (widget.kind == 'music')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: _performer,
                      decoration: InputDecoration(
                        labelText: tr('Исполнитель *'),
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                  ),
                TextField(
                  controller: _genre,
                  decoration: InputDecoration(
                    labelText: widget.kind == 'font'
                        ? tr('Категория (Serif/Sans/Handwritten)')
                        : widget.kind == 'background'
                        ? tr('Жанр (Nature/Fantasy/Cyber)')
                        : tr('Жанр/тег'),
                    border: const OutlineInputBorder(),
                    filled: true,
                    hintText: widget.kind == 'button_preset'
                        ? 'Minimal, Fantasy...'
                        : 'Ambient, Horror...',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _license,
                  decoration: InputDecoration(
                    labelText: tr('Лицензия *'),
                    border: OutlineInputBorder(),
                    filled: true,
                    helperText: tr('Например CC-BY, CC-BY-SA, MIT'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _desc,
                  decoration: InputDecoration(
                    labelText: tr('Описание'),
                    border: OutlineInputBorder(),
                    filled: true,
                  ),
                  maxLines: 4,
                ),
                const SizedBox(height: 20),
                if (_isUploading) ...[
                  LinearProgressIndicator(
                    value: _progress > 0 && _progress < 1 ? _progress : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr('Загрузка...'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: _isUploading ? null : _submit,
                  icon: _isUploading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_upload_rounded),
                  label: Text(
                    _isUploading
                        ? tr('Загрузка...')
                        : tr('Отправить на модерацию'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  trf('Файл: {p0} • {p1}', {
                    'p0': _file != null
                        ? p.basename(_file!.path)
                        : tr('не выбран'),
                    'p1': _file != null
                        ? '${(_file!.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB'
                        : '',
                  }),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr(
                    'Максимальный размер файла — 100 MB. Аудио: MP3, WAV, OGG, M4A, FLAC, AAC.',
                  ),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (widget.kind == 'button_preset')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      tr(
                        'JSON должен содержать поля preset (corner/h/v/center assets). Пример смотри в редакторе пресетов.',
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (widget.kind == 'font')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      tr(
                        'Поддерживаются TTF/OTF/WOFF. После одобрения шрифт появится в выборе шрифтов.',
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UploadIntroCard extends StatelessWidget {
  final String kindLabel;
  final List<String> formats;

  const _UploadIntroCard({required this.kindLabel, required this.formats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.cloud_upload_rounded, color: scheme.onPrimary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trf('Загрузка: {kindLabel}', {'kindLabel': kindLabel}),
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('Ресурс уйдёт на модерацию после отправки.'),
                    style: TextStyle(
                      color: scheme.onPrimaryContainer.withOpacity(0.75),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    trf('Форматы: {p0}', {
                      'p0': formats.join(', ').toUpperCase(),
                    }),
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilePickerTile extends StatelessWidget {
  final String label;
  final File? file;
  final String allowed;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _FilePickerTile({
    required this.label,
    required this.file,
    required this.allowed,
    required this.onPick,
    required this.onClear,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasFile = file != null;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPick,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                hasFile
                    ? Icons.check_circle_rounded
                    : Icons.upload_file_rounded,
                color: hasFile ? Colors.green : scheme.onSurfaceVariant,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasFile
                          ? p.basename(file!.path)
                          : trf('Нажмите чтобы выбрать ({allowed})', {
                              'allowed': allowed,
                            }),
                      style: TextStyle(
                        color: hasFile
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant.withOpacity(0.7),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (hasFile)
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: onClear,
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant.withOpacity(0.5),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
