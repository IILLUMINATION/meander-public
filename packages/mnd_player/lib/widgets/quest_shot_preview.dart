import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mnd_player/utils/quest_shot.dart';

/// Что автор выбрал в диалоге снимка.
enum QuestShotAction { save, export }

/// Итог диалога: действие и готовый PNG (пересобирать не нужно).
class QuestShotResult {
  const QuestShotResult({
    required this.action,
    required this.png,
    required this.frame,
  });

  final QuestShotAction action;
  final Uint8List png;
  final QuestShotFrame frame;
}

/// Сборка карточки под выбранную рамку. Диалог зовёт её при каждой смене
/// рамки: превью должно показывать ровно то, что уйдёт в файл.
typedef QuestShotComposer = Future<Uint8List> Function(QuestShotFrame frame);

/// Показать превью снимка перед сохранением.
///
/// Раньше пункт меню сразу клал PNG в скриншоты квеста: автор не видел кадр
/// до сохранения и не мог забрать его наружу. Теперь кадр сначала
/// показывается, рамка выбирается тут же, а дальше — «в скриншоты» или
/// «экспортировать».
Future<QuestShotResult?> showQuestShotPreview(
  BuildContext context, {
  required QuestShotComposer compose,
  QuestShotFrame initialFrame = QuestShotFrame.phone,
  bool canExport = true,
}) {
  return showDialog<QuestShotResult>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _QuestShotPreviewDialog(
      compose: compose,
      initialFrame: initialFrame,
      canExport: canExport,
    ),
  );
}

class _QuestShotPreviewDialog extends StatefulWidget {
  const _QuestShotPreviewDialog({
    required this.compose,
    required this.initialFrame,
    required this.canExport,
  });

  final QuestShotComposer compose;
  final QuestShotFrame initialFrame;
  final bool canExport;

  @override
  State<_QuestShotPreviewDialog> createState() =>
      _QuestShotPreviewDialogState();
}

class _QuestShotPreviewDialogState extends State<_QuestShotPreviewDialog> {
  late QuestShotFrame _frame = widget.initialFrame;
  Uint8List? _png;
  bool _busy = true;
  String? _error;

  /// Номер запроса: быстрые клики по рамкам не должны перерисовывать
  /// превью устаревшим кадром.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _recompose();
  }

  Future<void> _recompose() async {
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final png = await widget.compose(_frame);
      if (!mounted || request != _request) return;
      setState(() {
        _png = png;
        _busy = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось собрать снимок';
      });
    }
  }

  void _selectFrame(QuestShotFrame frame) {
    if (frame == _frame) return;
    setState(() => _frame = frame);
    _recompose();
  }

  void _finish(QuestShotAction action) {
    final png = _png;
    if (png == null) return;
    Navigator.of(context).pop(
      QuestShotResult(action: action, png: png, frame: _frame),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: size.height * 0.92,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Icon(Icons.photo_camera_rounded, color: scheme.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Снимок сцены',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildPreview(scheme),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final frame in QuestShotFrame.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(frame.label),
                          selected: _frame == frame,
                          onSelected: (_) => _selectFrame(frame),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  if (widget.canExport) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _png == null || _busy
                            ? null
                            : () => _finish(QuestShotAction.export),
                        icon: const Icon(Icons.ios_share_rounded, size: 18),
                        label: const Text('Экспортировать'),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _png == null || _busy
                          ? null
                          : () => _finish(QuestShotAction.save),
                      icon: const Icon(
                        Icons.add_photo_alternate_rounded,
                        size: 18,
                      ),
                      label: const Text('В скриншоты'),
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

  Widget _buildPreview(ColorScheme scheme) {
    final png = _png;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (png != null)
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.memory(
              png,
              gaplessPlayback: true,
              fit: BoxFit.contain,
              width: double.infinity,
            ),
          )
        else
          Container(
            height: 220,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        if (_busy)
          Container(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(),
          ),
        if (_error != null)
          Positioned(
            bottom: 12,
            child: Text(
              _error!,
              style: TextStyle(color: scheme.error),
            ),
          ),
      ],
    );
  }
}
