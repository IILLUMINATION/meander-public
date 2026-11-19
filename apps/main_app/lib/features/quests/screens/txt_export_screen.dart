import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/txt_quest_exporter.dart';
import 'package:flutter/material.dart';

/// Промежуточный экран настроек перед экспортом квеста в `.txt`.
///
/// Возвращает [TxtExportOptions] либо `null`, если пользователь отменил.
class TxtExportScreen extends StatefulWidget {
  final String questTitle;

  const TxtExportScreen({super.key, required this.questTitle});

  @override
  State<TxtExportScreen> createState() => _TxtExportScreenState();
}

class _TxtExportScreenState extends State<TxtExportScreen> {
  TxtExportOptions _options = const TxtExportOptions();

  void _update(TxtExportOptions value) => setState(() => _options = value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Настройки экспорта в .txt'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            widget.questTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            tr('Один .txt для ИИ'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _card(tr('Для ИИ'), [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Справка о движке и правила чтения')),
              value: _options.aiGuide,
              onChanged: _options.readable
                  ? (value) => _update(_options.copyWith(aiGuide: value))
                  : null,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Понятный текст вместо JSON')),
              subtitle: Text(
                _options.readable
                    ? tr('Текст и структура без JSON')
                    : tr('Если выключить, будет сырой технический дамп'),
              ),
              value: _options.readable,
              onChanged: (value) => _update(_options.copyWith(readable: value)),
            ),
          ]),
          const SizedBox(height: 12),
          _card(tr('Сокращать UUID'), [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Сокращать UUID')),
              subtitle: Text(tr('Длинные ID заменяются на ID_1, ID_2')),
              value: _options.shortenIds,
              onChanged: (value) =>
                  _update(_options.copyWith(shortenIds: value)),
            ),
          ]),
          const SizedBox(height: 12),
          _card(tr('Что включить'), [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Конфигурация')),
              value: _options.includeConfig,
              onChanged: (value) =>
                  _update(_options.copyWith(includeConfig: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Ноды')),
              subtitle: Text(tr('Содержимое нод')),
              value: _options.includeNodes,
              onChanged: (value) =>
                  _update(_options.copyWith(includeNodes: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Скрипты')),
              value: _options.includeScripts,
              onChanged: (value) =>
                  _update(_options.copyWith(includeScripts: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Связи')),
              subtitle: Text(tr('Связи между нодами')),
              value: _options.includeConnections,
              onChanged: (value) =>
                  _update(_options.copyWith(includeConnections: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Группы')),
              value: _options.includeGroups,
              onChanged: (value) =>
                  _update(_options.copyWith(includeGroups: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Комментарии')),
              value: _options.includeComments,
              onChanged: (value) =>
                  _update(_options.copyWith(includeComments: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Координаты нод')),
              value: _options.includeCoordinates,
              onChanged: (value) =>
                  _update(_options.copyWith(includeCoordinates: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Служебные скрипты')),
              value: _options.includeSystemScripts,
              onChanged: (value) =>
                  _update(_options.copyWith(includeSystemScripts: value)),
            ),
          ]),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _options = const TxtExportOptions()),
              icon: const Icon(Icons.restart_alt),
              label: Text(tr('Сбросить настройки')),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('Отмена')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(_options),
                icon: const Icon(Icons.description_outlined),
                label: Text(tr('Экспортировать')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}
