import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ReportDialog extends ConsumerStatefulWidget {
  final String reportedType; // 'quest', 'review', 'user'
  final String reportedId;
  final String? reportedTitle; // Для отображения в диалоге

  const ReportDialog({
    super.key,
    required this.reportedType,
    required this.reportedId,
    this.reportedTitle,
  });

  @override
  ConsumerState<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends ConsumerState<ReportDialog> {
  String? _selectedReason;
  final TextEditingController _descriptionController = TextEditingController();
  bool _isSubmitting = false;

  /// `$1` — причина как её хранит и фильтрует модерация, `$2` — что человек
  /// видит в списке. Значение уходит на сервер русским, иначе жалобы перестали
  /// бы сходиться с тем, что уже лежит в `reports.reason`.
  final List<(String, String)> _reasons = [
    ('Спам', tr('Спам')),
    ('Неподходящий контент', tr('Неподходящий контент')),
    ('Оскорбления', tr('Оскорбления')),
    ('Мошенничество', tr('Мошенничество')),
    ('Нарушение авторских прав', tr('Нарушение авторских прав')),
    ('Другое', tr('Другое')),
  ];

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submitReport() async {
    if (_selectedReason == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Пожалуйста, выберите причину жалобы')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!await ensureAccount(
      context,
      why: tr(
        'Жалобы разбирает модерация, а она видит обращения только от авторов с аккаунтом. Войдите на вкладке «Вход» — и кнопка заработает.',
      ),
    )) {
      return;
    }
    if (!mounted) return;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final api = ref.read(apiServiceProvider);

      await api.post(
        'reports',
        body: {
          'reported_type': widget.reportedType,
          'reported_id': widget.reportedId,
          'reason': _selectedReason,
          'description': _descriptionController.text.isNotEmpty
              ? _descriptionController.text
              : null,
        },
      );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Жалоба отправлена. Спасибо!')),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  String _getTitle() {
    switch (widget.reportedType) {
      case 'quest':
        return tr('Пожаловаться на квест');
      case 'review':
        return tr('Пожаловаться на отзыв');
      case 'user':
        return tr('Пожаловаться на пользователя');
      case 'message':
        return tr('Пожаловаться на сообщение');
      default:
        return tr('Пожаловаться');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: scheme.surfaceContainerHigh,
      title: Text(_getTitle(), style: TextStyle(color: scheme.onSurface)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.reportedTitle != null) ...[
              Text(
                widget.reportedTitle!,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              tr('Причина жалобы:'),
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ..._reasons.map(
              (reason) => RadioListTile<String>(
                title: Text(
                  reason.$2,
                  style: TextStyle(color: scheme.onSurface),
                ),
                value: reason.$1,
                groupValue: _selectedReason,
                onChanged: (value) {
                  setState(() {
                    _selectedReason = value;
                  });
                },
                activeColor: scheme.error,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr('Дополнительная информация (необязательно):'),
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              style: TextStyle(color: scheme.onSurface),
              maxLines: 3,
              decoration: InputDecoration(
                hintText: tr('Опишите проблему подробнее...'),
                hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: Text(
            tr('Отмена'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submitReport,
          style: ElevatedButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          child: _isSubmitting
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(scheme.onError),
                  ),
                )
              : Text(tr('Отправить')),
        ),
      ],
    );
  }
}
