import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/features/editor/providers/node_provider.dart';
import 'package:canvas_app/features/editor/screens/node_content/widgets/node_content_settings_widgets.dart';
import 'package:canvas_app/features/editor/screens/node_selection_screen.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Заполнители «действия по умолчанию»: они оседают и в настройках ноды, и в
/// её файле, поэтому переводим только витрину. Настоящее имя узла автора
/// проходит как есть.
String _displayDefaultNodeName(String value) {
  return switch (value) {
    'Не выбрана' => tr('Не выбрана'),
    'Нода не найдена' => tr('Нода не найдена'),
    _ => value,
  };
}

/// Результат редактирования настроек ноды. Возвращается через Navigator.pop.
class NodeSettingsResult {
  final String? backgroundAssetId;
  final String? backgroundAssetName;
  final String? backgroundVideoAssetId;
  final String? backgroundVideoAssetName;
  final double videoVolume;
  final bool videoLoop;
  final bool videoMuted;
  final String videoFit;
  final double?
  backgroundBlur; // null = как в скрипте (дефолт 10), 0 = без размытия
  final String? backgroundAudioId;
  final String? backgroundAudioName;
  final double audioVolume;
  final double? itemSpacing;
  final bool? imageRoundedCorners;
  final String transitionMode;
  final bool timerEnabled;
  final bool timerHidden;
  final String timerDurationText;
  final String? defaultActionNodeId;
  final String defaultActionNodeName;

  const NodeSettingsResult({
    required this.backgroundAssetId,
    this.backgroundAssetName,
    required this.backgroundVideoAssetId,
    this.backgroundVideoAssetName,
    required this.videoVolume,
    required this.videoLoop,
    required this.videoMuted,
    required this.videoFit,
    required this.backgroundBlur,
    required this.backgroundAudioId,
    this.backgroundAudioName,
    required this.audioVolume,
    required this.itemSpacing,
    required this.imageRoundedCorners,
    required this.transitionMode,
    required this.timerEnabled,
    required this.timerHidden,
    required this.timerDurationText,
    required this.defaultActionNodeId,
    required this.defaultActionNodeName,
  });
}

class NodeSettingsScreen extends ConsumerStatefulWidget {
  final String questId;
  final String nodeId;

  // Initial values (snapshot from NodeContentScreen)
  final String? initialBackgroundId;
  final String? initialBackgroundName;
  final String? initialBackgroundVideoId;
  final String? initialBackgroundVideoName;
  final double initialVideoVolume;
  final bool initialVideoLoop;
  final bool initialVideoMuted;
  final String initialVideoFit;
  final double? initialBackgroundBlur;
  final String? initialAudioId;
  final String? initialAudioName;
  final double initialAudioVolume;
  final double? initialItemSpacing;
  final bool? initialImageRoundedCorners;
  final String initialTransitionMode;
  final bool initialTimerEnabled;
  final bool initialTimerHidden;
  final String initialTimerDurationText;
  final String? initialDefaultActionNodeId;
  final String initialDefaultActionNodeName;

  /// Автосохранение: правки сразу уходят ноде, без выхода из вкладки.
  final ValueChanged<NodeSettingsResult>? onChanged;

  const NodeSettingsScreen({
    super.key,
    required this.questId,
    required this.nodeId,
    required this.initialBackgroundId,
    this.initialBackgroundName,
    required this.initialBackgroundVideoId,
    this.initialBackgroundVideoName,
    required this.initialVideoVolume,
    required this.initialVideoLoop,
    required this.initialVideoMuted,
    required this.initialVideoFit,
    required this.initialBackgroundBlur,
    required this.initialAudioId,
    this.initialAudioName,
    required this.initialAudioVolume,
    required this.initialItemSpacing,
    required this.initialImageRoundedCorners,
    required this.initialTransitionMode,
    required this.initialTimerEnabled,
    required this.initialTimerHidden,
    required this.initialTimerDurationText,
    required this.initialDefaultActionNodeId,
    required this.initialDefaultActionNodeName,
    this.onChanged,
  });

  @override
  ConsumerState<NodeSettingsScreen> createState() => _NodeSettingsScreenState();
}

class _NodeSettingsScreenState extends ConsumerState<NodeSettingsScreen> {
  late String? _bgId;
  late String? _bgName;
  late String? _bgVideoId;
  late String? _bgVideoName;
  late double _videoVolume;
  late bool _videoLoop;
  late bool _videoMuted;
  late String _videoFit;
  late double? _blur;
  late String? _audioId;
  late String? _audioName;
  late double _audioVolume;
  late double? _itemSpacing;
  late bool? _rounded;
  late String _transitionMode;
  late bool _timerEnabled;
  late bool _timerHidden;
  late TextEditingController _timerController;
  late String? _defaultNodeId;
  late String _defaultNodeName;

  bool _isDirty = false;
  String? _lastAutosave;

  @override
  void initState() {
    super.initState();
    _bgId = widget.initialBackgroundId;
    _bgName = widget.initialBackgroundName;
    _bgVideoId = widget.initialBackgroundVideoId;
    _bgVideoName = widget.initialBackgroundVideoName;
    _videoVolume = widget.initialVideoVolume;
    _videoLoop = widget.initialVideoLoop;
    _videoMuted = widget.initialVideoMuted;
    _videoFit = widget.initialVideoFit;
    _blur = widget.initialBackgroundBlur;
    _audioId = widget.initialAudioId;
    _audioName = widget.initialAudioName;
    _audioVolume = widget.initialAudioVolume;
    _itemSpacing = widget.initialItemSpacing;
    _rounded = widget.initialImageRoundedCorners;
    _transitionMode = widget.initialTransitionMode;
    _timerEnabled = widget.initialTimerEnabled;
    _timerHidden = widget.initialTimerHidden;
    _timerController = TextEditingController(
      text: widget.initialTimerDurationText,
    );
    _timerController.addListener(_onTimerTextChanged);
    _defaultNodeId = widget.initialDefaultActionNodeId;
    _defaultNodeName = widget.initialDefaultActionNodeName;
    _lastAutosave = _snapshot(_buildResult());
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleAutosave();
  }

  void _onTimerTextChanged() {
    _markDirty();
    _scheduleAutosave();
  }

  void _scheduleAutosave() => _emitAutosave();

  String _snapshot(NodeSettingsResult result) => [
    result.backgroundAssetId,
    result.backgroundAssetName,
    result.backgroundVideoAssetId,
    result.backgroundVideoAssetName,
    result.videoVolume,
    result.videoLoop,
    result.videoMuted,
    result.videoFit,
    result.backgroundBlur,
    result.backgroundAudioId,
    result.backgroundAudioName,
    result.audioVolume,
    result.itemSpacing,
    result.imageRoundedCorners,
    result.transitionMode,
    result.timerEnabled,
    result.timerHidden,
    result.timerDurationText,
    result.defaultActionNodeId,
    result.defaultActionNodeName,
  ].join('\u0000');

  void _emitAutosave() {
    final onChanged = widget.onChanged;
    if (onChanged == null || !_isDirty) return;
    final result = _buildResult();
    final snapshot = _snapshot(result);
    if (snapshot == _lastAutosave) return;
    _lastAutosave = snapshot;
    onChanged(result);
  }

  @override
  void dispose() {
    _timerController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  NodeSettingsResult _buildResult() => NodeSettingsResult(
    backgroundAssetId: _bgId,
    backgroundAssetName: _bgName,
    backgroundVideoAssetId: _bgVideoId,
    backgroundVideoAssetName: _bgVideoName,
    videoVolume: _videoVolume,
    videoLoop: _videoLoop,
    videoMuted: _videoMuted,
    videoFit: _videoFit,
    backgroundBlur: _blur,
    backgroundAudioId: _audioId,
    backgroundAudioName: _audioName,
    audioVolume: _audioVolume,
    itemSpacing: _itemSpacing,
    imageRoundedCorners: _rounded,
    transitionMode: _transitionMode,
    timerEnabled: _timerEnabled,
    timerHidden: _timerHidden,
    timerDurationText: _timerController.text,
    defaultActionNodeId: _defaultNodeId,
    defaultActionNodeName: _defaultNodeName,
  );

  Future<void> _popWithResult() async {
    // Всегда возвращаем результат — автосохранение на выходе
    Navigator.pop(context, _buildResult());
  }

  Future<void> _pickBackground() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (context) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _bgId = result.name;
        _bgName = result.friendlyName;
      });
      _markDirty();
    }
  }

  Future<void> _pickBackgroundVideo() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (context) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['video'],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _bgVideoId = result.name;
        _bgVideoName = result.friendlyName;
      });
      _markDirty();
    }
  }

  Future<void> _pickAudio() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (context) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['audio'],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _audioId = result.name;
        _audioName = result.friendlyName;
      });
      _markDirty();
    }
  }

  Future<void> _selectDefaultNode() async {
    final selectedNodeId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => NodeSelectionScreen(
          questId: widget.questId,
          currentNodeId: widget.nodeId,
          selectedNodeId: _defaultNodeId,
        ),
      ),
    );
    if (selectedNodeId != null && mounted) {
      try {
        final allNodes = await ref.read(
          allQuestNodesProvider(widget.questId).future,
        );
        final target = allNodes
            .where((n) => n.id == selectedNodeId)
            .firstOrNull;
        setState(() {
          _defaultNodeId = selectedNodeId;
          _defaultNodeName = target?.title ?? 'Нода не найдена';
        });
      } catch (_) {
        setState(() {
          _defaultNodeId = selectedNodeId;
          _defaultNodeName = selectedNodeId;
        });
      }
      _markDirty();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _popWithResult();
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          title: Text(
            tr('Настройки ноды'),
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          backgroundColor: scheme.surface,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _popWithResult,
          ),
        ),
        body: AdaptiveContent(
          maxWidth: 720,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              // --- Фон ---
              Text(
                tr('ФОН'),
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              ResourceSelectorWidget(
                label: tr('ФОНОВОЕ ИЗОБРАЖЕНИЕ'),
                selectedResourceName: _bgName,
                onTap: _pickBackground,
                onClear: () {
                  setState(() {
                    _bgId = null;
                    _bgName = null;
                  });
                  _markDirty();
                },
              ),
              const SizedBox(height: 8),
              ResourceSelectorWidget(
                label: tr('ФОНОВОЕ ВИДЕО'),
                selectedResourceName: _bgVideoName,
                onTap: _pickBackgroundVideo,
                onClear: () {
                  setState(() {
                    _bgVideoId = null;
                    _bgVideoName = null;
                  });
                  _markDirty();
                },
              ),
              if (_bgVideoId != null) ...[
                const SizedBox(height: 8),
                // Material вместо Container(color: …): ListTile-family рисует
                // фон и ink на ближайшем Material-предке, поэтому краска
                // промежуточного box'а глушила подсветку нажатия (718 строк
                // assertion в crash_log за 04–09 октября).
                Material(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: SwitchListTile(
                                title: Text(
                                  tr('Зациклить'),
                                  style: TextStyle(fontSize: 13),
                                ),
                                value: _videoLoop,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                onChanged: (v) {
                                  setState(() => _videoLoop = v);
                                  _markDirty();
                                },
                              ),
                            ),
                            Expanded(
                              child: SwitchListTile(
                                title: Text(
                                  tr('Без звука'),
                                  style: TextStyle(fontSize: 13),
                                ),
                                value: _videoMuted,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                onChanged: (v) {
                                  setState(() => _videoMuted = v);
                                  _markDirty();
                                },
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Text(
                              tr('Громкость'),
                              style: TextStyle(fontSize: 13),
                            ),
                            Expanded(
                              child: Slider(
                                value: _videoVolume,
                                min: 0,
                                max: 1,
                                divisions: 10,
                                label: '${(_videoVolume * 100).round()}%',
                                onChanged: (v) =>
                                    setState(() => _videoVolume = v),
                                onChangeEnd: (_) => _markDirty(),
                              ),
                            ),
                          ],
                        ),
                        // Плеер умел это давно (`_videoFitOf` в game_screen.dart),
                        // но редактор поле никогда не писал — подгонка фона была
                        // доступна только ручной правкой JSON.
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          value: _videoFit,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: tr('Вписывание'),
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'cover',
                              child: Text(
                                tr('Cover — заполнить, край срежется'),
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'contain',
                              child: Text(
                                tr('Contain — целиком, с полями'),
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'fill',
                              child: Text(
                                tr('Fill — растянуть по экрану'),
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _videoFit = v ?? 'cover');
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // --- Размытие ---
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.blur_on, color: scheme.primary, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          tr('Размытие фона'),
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        Switch(
                          value: _blur != null,
                          onChanged: (v) {
                            setState(() {
                              if (v) {
                                _blur = 10.0;
                              } else {
                                _blur = null;
                              }
                            });
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                    if (_blur != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(tr('Сила'), style: TextStyle(fontSize: 12)),
                          Expanded(
                            child: Slider(
                              value: _blur!.clamp(0.0, 20.0),
                              min: 0,
                              max: 20,
                              divisions: 20,
                              label: _blur!.toStringAsFixed(0),
                              onChanged: (v) => setState(() => _blur = v),
                              onChangeEnd: (_) => _markDirty(),
                            ),
                          ),
                          Text(
                            '${_blur!.toStringAsFixed(0)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      Text(
                        tr('0 = без размытия, 10 = по умолчанию'),
                        style: TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tr('Когда выключено — управляется скриптом (блок "Размытие"). Включите и поставьте 0 чтобы полностью убрать блюр.'),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 4),
                      Text(
                        tr('Выключено: используется значение из скрипта или 10 по умолчанию. Включите чтобы задать своё (0 = без размытия).'),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // --- Аудио ---
              _buildAudioSection(),
              const SizedBox(height: 16),
              // --- Таймер ---
              _buildTimerSection(scheme),
              const SizedBox(height: 16),
              // --- Оформление ---
              Text(
                tr('ОФОРМЛЕНИЕ'),
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.format_line_spacing,
                          color: scheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            tr('Отступ между элементами'),
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        Switch(
                          value: _itemSpacing != null,
                          onChanged: (v) {
                            setState(() => _itemSpacing = v ? 24.0 : null);
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                    Text(
                      _itemSpacing == null
                          ? tr('По умолчанию (24 px). Для кастомных зазоров используйте элемент «Отступ».')
                          : trf('Своё значение: {p0} px', {'p0': _itemSpacing!.round()}),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    if (_itemSpacing != null)
                      Slider(
                        value: _itemSpacing!.clamp(0.0, 48.0),
                        min: 0.0,
                        max: 48.0,
                        divisions: 48,
                        label: '${_itemSpacing!.round()} px',
                        onChanged: (v) => setState(() => _itemSpacing = v),
                        onChangeEnd: (_) => _markDirty(),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.rounded_corner_rounded,
                      color: scheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('Скругление углов картинок'),
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            _rounded == false
                                ? tr('Отключено для всех')
                                : tr('По умолчанию (скруглять)'),
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _rounded != false,
                      onChanged: (v) {
                        setState(() => _rounded = v ? null : false);
                        _markDirty();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.animation_rounded,
                      color: scheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('Стиль перехода в эту ноду'),
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            tr('Переопределяет глобальный режим квеста'),
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _transitionMode,
                      underline: const SizedBox.shrink(),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(tr('Как в квесте')),
                        ),
                        DropdownMenuItem(
                          value: 'none',
                          child: Text(tr('Без анимации')),
                        ),
                        DropdownMenuItem(
                          value: 'fade',
                          child: Text(tr('Затухание')),
                        ),
                        DropdownMenuItem(
                          value: 'dark',
                          child: Text(tr('Затемнение')),
                        ),
                        DropdownMenuItem(
                          value: 'page',
                          child: Text(tr('Перелистывание')),
                        ),
                        DropdownMenuItem(value: 'slide', child: Text(tr('Сдвиг'))),
                        DropdownMenuItem(
                          value: 'slideUp',
                          child: Text(tr('Подъём')),
                        ),
                        DropdownMenuItem(value: 'zoom', child: Text(tr('Масштаб'))),
                        DropdownMenuItem(
                          value: 'blur',
                          child: Text(tr('Размытие')),
                        ),
                        DropdownMenuItem(value: 'wipe', child: Text(tr('Шторка'))),
                      ],
                      onChanged: (v) {
                        setState(() => _transitionMode = v ?? '');
                        _markDirty();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _popWithResult,
                icon: const Icon(Icons.check_rounded),
                label: Text(tr('Готово — сохранить')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioSection() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.music_note_rounded,
                color: scheme.onSurfaceVariant,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                tr('Фоновый звук ноды'),
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              if (_audioId != null)
                IconButton(
                  icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
                  onPressed: () {
                    setState(() {
                      _audioId = null;
                      _audioName = null;
                    });
                    _markDirty();
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
              else
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickAudio,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _audioName ?? tr('Не выбрано (будет играть музыка главы)'),
                style: TextStyle(
                  color: _audioName != null
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (_audioId != null) ...[
            const SizedBox(height: 16),
            Text(
              tr('Громкость'),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            Row(
              children: [
                Icon(
                  Icons.volume_down,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                Expanded(
                  child: Slider(
                    value: _audioVolume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (val) => setState(() => _audioVolume = val),
                    onChangeEnd: (_) => _markDirty(),
                  ),
                ),
                Icon(Icons.volume_up, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  '${(_audioVolume * 100).toInt()}%',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTimerSection(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.timer_outlined,
                  color: scheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  tr('Таймер выбора'),
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              Switch(
                value: _timerEnabled,
                onChanged: (v) {
                  setState(() => _timerEnabled = v);
                  _markDirty();
                },
              ),
            ],
          ),
          if (_timerEnabled) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _timerController,
              style: TextStyle(color: scheme.onSurface),
              cursorColor: scheme.primary,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr('Время (сек)'),
                labelStyle: TextStyle(color: scheme.onSurfaceVariant),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: Icon(
                  Icons.access_time,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _selectDefaultNode,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.call_missed_outgoing,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr('Действие по умолчанию:'),
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _displayDefaultNodeName(_defaultNodeName),
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: scheme.onSurfaceVariant,
                        size: 14,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: SwitchListTile(
                value: _timerHidden,
                onChanged: (v) {
                  setState(() => _timerHidden = v);
                  _markDirty();
                },
                title: Text(
                  tr('Скрыть таймер'),
                  style: TextStyle(color: scheme.onSurface, fontSize: 14),
                ),
                subtitle: Text(
                  tr('Таймер сработает, но без отсчёта'),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                secondary: Icon(
                  Icons.visibility_off_outlined,
                  color: scheme.onSurfaceVariant,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
