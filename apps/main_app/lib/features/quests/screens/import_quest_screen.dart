import 'dart:io';

import 'package:canvas_app/core/importers/qst_importer.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/features/editor/providers/tag_provider.dart';
import 'package:canvas_app/features/editor/workspace/editor_document.dart';
import 'package:canvas_app/core/services/quest_data_guard.dart';
import 'package:canvas_app/features/editor/workspace/quest_editor_shell.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:canvas_app/core/utils/error_text.dart';

/// Диалог выбора типа импорта
class ImportDialog extends ConsumerWidget {
  const ImportDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dialog(
      backgroundColor: const Color(0xFF2A2A2A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00C853).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.file_upload,
                    color: Color(0xFF00C853),
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Импорт квеста'),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        tr('Выберите формат для импорта'),
                        style: TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _ImportOption(
              icon: Icons.description,
              iconColor: Colors.orange,
              title: 'URQ (.qst, .txt)',
              subtitle: tr('DOS/Windows текстовые квесты'),
              onTap: () => _importQst(context, ref),
            ),
            const SizedBox(height: 12),
            _ImportOption(
              icon: Icons.folder_open,
              iconColor: Colors.blue,
              title: 'Twine (HTML)',
              subtitle: tr('Квесты из Twine (Harlowe, SugarCube)'),
              onTap: () => _showNotImplemented(context),
              enabled: false,
            ),
            const SizedBox(height: 12),
            _ImportOption(
              icon: Icons.code,
              iconColor: Colors.purple,
              title: 'JSON',
              subtitle: tr('Meander JSON формат'),
              onTap: () => _showNotImplemented(context),
              enabled: false,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(tr('Отмена')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importQst(BuildContext context, WidgetRef ref) async {
    Navigator.pop(context);
    var loadingShown = false;

    try {
      final result = await _pickQstFile();
      if (result == null || result.isEmpty) return;

      final pickedPath = result.first.path;
      if (pickedPath == null) {
        _showErrorDialog(context, tr('Не удалось получить путь к файлу.'));
        return;
      }
      final file = File(pickedPath);

      // Показываем индикатор загрузки
      _showLoadingDialog(context);
      loadingShown = true;

      // Импортируем
      final importer = QstImporter();
      final importResult = await importer.importFile(file.path);

      Navigator.pop(context); // Закрываем индикатор

      if (!importResult.success) {
        _showErrorDialog(context, importResult.error!);
        return;
      }

      // Показываем результат
      _showImportResultDialog(context, importResult, ref);
    } catch (e) {
      if (loadingShown && context.mounted) Navigator.pop(context);
      _showErrorDialog(context, trf('Ошибка: {p0}', {'p0': friendlyError(e)}));
    }
  }

  Future<List<PlatformFile>?> _pickQstFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['qst', 'txt', 'urq'],
    );
    return files.isEmpty ? null : files;
  }

  void _showLoadingDialog(BuildContext context) {
    showAppDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Card(
          color: Color(0xFF2A2A2A),
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Color(0xFF00C853)),
                SizedBox(height: 16),
                Text(
                  tr('Импорт квеста...'),
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showErrorDialog(BuildContext context, String error) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.error, color: Colors.red),
            SizedBox(width: 12),
            Text(tr('Ошибка импорта')),
          ],
        ),
        content: Text(error, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showImportResultDialog(
    BuildContext context,
    QstImportResult result,
    WidgetRef ref,
  ) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF00C853)),
            SizedBox(width: 12),
            Text(tr('Импорт успешен')),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.summary,
                style: const TextStyle(color: Colors.white70),
              ),
              if (result.warnings.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  tr('Предупреждения:'),
                  style: TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 100),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: result.warnings
                          .map(
                            (w) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '• $w',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _saveQuest(result, ref, context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00C853),
              foregroundColor: Colors.black,
            ),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
  }

  Future<void> _saveQuest(
    QstImportResult result,
    WidgetRef ref,
    BuildContext context,
  ) async {
    try {
      // Сохраняем квест через функцию импорта
      await saveImportedQuest(
        quest: result.quest!,
        nodes: result.nodes!,
        scripts: result.scripts,
      );

      // Инвалидируем кэш провайдеров
      ref.invalidate(questsProvider);
      ref.invalidate(questProvider(result.quest!.id));
      ref.invalidate(questTagsProvider(result.quest!.id));

      // Открываем редактор
      if (context.mounted) {
        // Получаем первый тег для квеста
        final tags = await ref.read(questTagsProvider(result.quest!.id).future);

        if (tags.isEmpty) {
          _showErrorDialog(context, tr('У квеста нет тегов'));
          return;
        }

        final firstTagId = tags.first.id;

        final questId = result.quest!.id;
        final protection = await QuestDataGuard.protect(questId);
        if (!context.mounted) return;
        await notifyQuestDataProtection(context, protection);
        if (!context.mounted) return;

        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => QuestEditorShell(
              questId: questId,
              initialDocument: EditorDocumentDescriptor.canvas(
                questId,
                firstTagId,
              ),
            ),
          ),
        );
      }
    } catch (e) {
      _showErrorDialog(
        context,
        trf('Ошибка сохранения: {p0}', {'p0': friendlyError(e)}),
      );
    }
  }

  void _showNotImplemented(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Этот формат будет поддерживаться в будущей версии')),
        backgroundColor: Color(0xFF00C853),
      ),
    );
  }
}

class _ImportOption extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  const _ImportOption({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled
          ? Colors.white.withOpacity(0.05)
          : Colors.white.withOpacity(0.02),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: enabled ? iconColor : Colors.white24,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: enabled ? Colors.white : Colors.white38,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: enabled ? Colors.white54 : Colors.white24,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (enabled)
                const Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.white54,
                  size: 16,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
