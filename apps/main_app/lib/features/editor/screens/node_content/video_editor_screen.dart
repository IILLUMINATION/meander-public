import 'dart:async';

import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/expression_editor_screen.dart';
import 'package:canvas_app/features/resources/services/resource_providers.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

class VideoEditorScreen extends ConsumerStatefulWidget {
  final String questId;
  final ContentItem? existingItem;

  /// Стабильный id для нового видео: без него каждое автосохранение
  /// создавало бы новый элемент в ноде.
  final String? draftId;

  /// Автосохранение в родительскую вкладку без закрытия экрана.
  final ValueChanged<ContentItem>? onChanged;

  const VideoEditorScreen({
    super.key,
    required this.questId,
    this.existingItem,
    this.draftId,
    this.onChanged,
  });

  @override
  ConsumerState<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends ConsumerState<VideoEditorScreen> {
  String? _lastAutosave;
  late String _sourceType; // asset | url | youtube
  String? _resourcePath;
  final _urlCtrl = TextEditingController();
  String? _posterPath;

  bool _autoplay = true;
  bool _loop = false;
  bool _muted = false;
  bool _showControls = true;
  bool _allowFullscreen = true;
  bool _allowSeek = true;
  bool _blockProgress = false;
  String _fit = 'contain';
  double _volume = 1.0;
  final _startCtrl = TextEditingController();
  final _endCtrl = TextEditingController();
  double _borderRadius = 12;

  /// Формула скругления (`numericExprs['borderRadius']`): движок считает её
  /// при каждом изменении состояния, а число выше остаётся запасным значением
  /// и превью редактора.
  String _radiusExpr = '';

  @override
  void initState() {
    super.initState();
    final e = widget.existingItem;
    if (e != null) {
      _resourcePath = e.resourcePath;
      _urlCtrl.text = e.videoUrl ?? '';
      _posterPath = e.videoPosterPath;
      _autoplay = e.videoAutoplay ?? true;
      _loop = e.videoLoop ?? false;
      _muted = e.videoMuted ?? false;
      _showControls = e.videoShowControls ?? true;
      _allowFullscreen = e.videoAllowFullscreen ?? true;
      _allowSeek = e.videoAllowSeek ?? true;
      _blockProgress = e.videoBlockProgress ?? false;
      _fit = e.videoFit ?? 'contain';
      _volume = e.volume;
      _borderRadius = e.borderRadius ?? 12;
      _radiusExpr = e.numericExpr('borderRadius') ?? '';
      if (e.videoStartMs != null) _startCtrl.text = e.videoStartMs.toString();
      if (e.videoEndMs != null) _endCtrl.text = e.videoEndMs.toString();
      _sourceType =
          e.videoSourceType ??
          (e.videoUrl != null && e.videoUrl!.trim().isNotEmpty
              ? (e.isYoutubeVideo ? 'youtube' : 'url')
              : 'asset');
    } else {
      _sourceType = 'asset';
    }
    _lastAutosave = _snapshot(_buildItem());
    _urlCtrl.addListener(_scheduleAutosave);
    _startCtrl.addListener(_scheduleAutosave);
    _endCtrl.addListener(_scheduleAutosave);
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleAutosave();
  }

  void _scheduleAutosave() => _emitAutosave();

  String? _snapshot(ContentItem? item) => item?.toJson().toString();

  void _emitAutosave() {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    final item = _buildItem();
    final snapshot = _snapshot(item);
    if (snapshot == _lastAutosave) return;
    _lastAutosave = snapshot;
    if (item != null) onChanged(item);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    final res = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['video'],
        ),
      ),
    );
    if (res != null) {
      setState(() {
        _resourcePath = res.path;
        _sourceType = 'asset';
      });
    }
  }

  Future<void> _pickPoster() async {
    final res = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (res != null) {
      setState(() => _posterPath = res.path);
    }
  }

  ContentItem? _buildItem({bool notifyUser = false}) {
    String? videoUrl;
    String? resourcePath;
    String sourceType = _sourceType;
    if (_sourceType == 'asset') {
      if (_resourcePath == null || _resourcePath!.isEmpty) {
        if (notifyUser) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(tr('Выберите файл видео'))));
        }
        return null;
      }
      resourcePath = _resourcePath;
    } else {
      final url = _urlCtrl.text.trim();
      if (url.isEmpty) {
        if (notifyUser) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(tr('Введите ссылку'))));
        }
        return null;
      }
      videoUrl = url;
      // auto-detect youtube if needed
      if (sourceType == 'url' &&
          (url.contains('youtube.com') || url.contains('youtu.be'))) {
        sourceType = 'youtube';
      }
    }

    final startMs = int.tryParse(_startCtrl.text.trim());
    final endMs = int.tryParse(_endCtrl.text.trim());

    final item = ContentItem(
      id:
          widget.existingItem?.id ??
          widget.draftId ??
          const Uuid().v4(),
      type: 'video',
      resourcePath: resourcePath,
      videoUrl: videoUrl,
      videoSourceType: sourceType,
      videoPosterPath: _posterPath,
      videoAutoplay: _autoplay,
      videoLoop: _loop,
      videoMuted: _muted,
      videoShowControls: _showControls,
      videoAllowFullscreen: _allowFullscreen,
      videoAllowSeek: _allowSeek,
      videoFit: _fit,
      videoStartMs: startMs,
      videoEndMs: endMs,
      videoBlockProgress: _blockProgress,
      volume: _volume,
      borderRadius: _borderRadius,
      behaviours: widget.existingItem?.behaviours,
      scriptTriggers: widget.existingItem?.scriptTriggers,
      targetNodeId: widget.existingItem?.targetNodeId,
      // Формулы чужих полей редактор не ведёт — уносим как были.
      numericExprs: widget.existingItem?.numericExprs,
    );
    // Скругление — своё: пустая строка означает «формулу сняли», а не «не
    // знаю», поэтому с неё ключ убирается.
    return item.withNumericExpr('borderRadius', _radiusExpr);
  }

  void _save() {
    final item = _buildItem(notifyUser: true);
    if (item == null) return;
    Navigator.pop(context, item);
  }

  /// Файл для подписи: имя из библиотеки квеста, иначе имя файла без пути —
  /// `res/videos/1790024448511_<uuid>.mp4` в строке читается плохо.
  String _label(String? path, Map<String, String> names, String emptyText) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return emptyText;
    final bare = trimmed.split('/').last;
    final named = names[bare]?.trim();
    return (named == null || named.isEmpty) ? bare : named;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final names =
        ref.watch(questResourceNamesProvider(widget.questId)).valueOrNull ??
        const <String, String>{};
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existingItem == null ? tr('Добавить видео') : tr('Настройка видео'),
        ),
        actions: [
          FilledButton(onPressed: _save, child: Text(tr('Сохранить'))),
          const SizedBox(width: 8),
        ],
      ),
      body: AdaptiveContent(
        maxWidth: 720,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Source type
              Text(tr('Источник'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'asset',
                    label: Text(tr('Файл')),
                    icon: Icon(Icons.folder),
                  ),
                  ButtonSegment(
                    value: 'url',
                    label: Text(tr('Ссылка')),
                    icon: Icon(Icons.link),
                  ),
                  ButtonSegment(
                    value: 'youtube',
                    label: Text('YouTube'),
                    icon: Icon(Icons.play_circle),
                  ),
                ],
                selected: {_sourceType},
                onSelectionChanged: (s) =>
                    setState(() => _sourceType = s.first),
              ),
              const SizedBox(height: 12),
              if (_sourceType == 'asset') ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _label(_resourcePath, names, tr('Файл не выбран')),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(tr('res/videos/… — локальный файл квеста')),
                  trailing: FilledButton.tonal(
                    onPressed: _pickVideo,
                    child: Text(tr('Выбрать')),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _urlCtrl,
                  decoration: InputDecoration(
                    labelText: _sourceType == 'youtube'
                        ? tr('YouTube ссылка')
                        : tr('URL видео (mp4/webm)'),
                    hintText: _sourceType == 'youtube'
                        ? 'https://youtube.com/watch?v=…'
                        : 'https://example.com/video.mp4',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _sourceType == 'youtube'
                      ? tr('YouTube откроется как превью + кнопка «Открыть». Прямое воспроизведение зависит от ссылки.')
                      : tr('Поддерживаются прямые ссылки на mp4/webm. Проверьте CORS.'),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ],
              const Divider(height: 32),
              // Poster
              Text(
                tr('Постер (превью)'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _label(_posterPath, names, tr('Не выбран')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_posterPath != null)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _posterPath = null),
                      ),
                    FilledButton.tonal(
                      onPressed: _pickPoster,
                      child: Text(tr('Выбрать')),
                    ),
                  ],
                ),
              ),
              const Divider(height: 32),
              Text(
                tr('Воспроизведение'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SwitchListTile(
                title: Text(tr('Автоплей')),
                subtitle: Text(tr('Начать сразу при показе')),
                value: _autoplay,
                onChanged: (v) => setState(() => _autoplay = v),
              ),
              SwitchListTile(
                title: Text(tr('Зациклить')),
                value: _loop,
                onChanged: (v) => setState(() => _loop = v),
              ),
              SwitchListTile(
                title: Text(tr('Без звука')),
                value: _muted,
                onChanged: (v) => setState(() => _muted = v),
              ),
              SwitchListTile(
                title: Text(tr('Показывать контролы')),
                value: _showControls,
                onChanged: (v) => setState(() => _showControls = v),
              ),
              SwitchListTile(
                title: Text(tr('Разрешить фулскрин')),
                value: _allowFullscreen,
                onChanged: (v) => setState(() => _allowFullscreen = v),
              ),
              SwitchListTile(
                title: Text(tr('Разрешить перемотку')),
                value: _allowSeek,
                onChanged: (v) => setState(() => _allowSeek = v),
              ),
              SwitchListTile(
                title: Text(tr('Блокировать прогресс до конца')),
                subtitle: Text(
                  tr('Не показывать следующий контент пока видео не закончится'),
                ),
                value: _blockProgress,
                onChanged: (v) => setState(() => _blockProgress = v),
              ),
              const SizedBox(height: 12),
              Text(trf('Громкость {p0}%', {'p0': (_volume * 100).round()})),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 20,
                label: '${(_volume * 100).round()}%',
                onChanged: (v) => setState(() => _volume = v),
              ),
              const Divider(height: 32),
              Text(
                tr('Внешний вид'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _fit,
                decoration: InputDecoration(
                  labelText: tr('Вписывание'),
                  border: OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'contain',
                    child: Text(tr('Contain — вписать целиком')),
                  ),
                  DropdownMenuItem(
                    value: 'cover',
                    child: Text(tr('Cover — заполнить')),
                  ),
                  DropdownMenuItem(
                    value: 'fill',
                    child: Text(tr('Fill — растянуть')),
                  ),
                ],
                onChanged: (v) => setState(() => _fit = v ?? 'contain'),
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: tr('Скругление углов'),
                  border: OutlineInputBorder(),
                  suffixText: 'px',
                ),
                keyboardType: TextInputType.number,
                controller: TextEditingController(
                  text: _borderRadius.toStringAsFixed(0),
                ),
                onChanged: (v) => _borderRadius = double.tryParse(v) ?? 12,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _radiusExpr.isEmpty
                          ? tr('Формула скругления: не задана — используем число выше')
                          : trf('Формула скругления: {_radiusExpr}', {'_radiusExpr': _radiusExpr}),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (_radiusExpr.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: tr('Снять формулу'),
                      onPressed: () => setState(() => _radiusExpr = ''),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.functions, size: 18),
                    label: Text(tr('Формула')),
                    onPressed: () async {
                      final edited = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ExpressionEditorScreen(
                            initialValue: _radiusExpr,
                            questId: widget.questId,
                            title: tr('Формула скругления'),
                          ),
                        ),
                      );
                      // null — отмена, пустая строка — формула снята.
                      if (edited == null || !mounted) return;
                      setState(() => _radiusExpr = edited);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _startCtrl,
                      decoration: InputDecoration(
                        labelText: tr('Старт (мс)'),
                        hintText: '0',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _endCtrl,
                      decoration: InputDecoration(
                        labelText: tr('Конец (мс)'),
                        hintText: tr('пусто = до конца'),
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lightbulb, color: cs.primary, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          tr('Подсказки'),
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('• Для интерактивного кино поместите видео в стек и добавьте кнопки поверх с условием видимости.\n• Событие onVideoEnded можно обработать скриптом (behaviours) для автоперехода.\n• Фоновое видео настраивается в параметрах ноды (фон).'),
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }
}
