import 'dart:convert';

import 'package:canvas_app/core/services/refactoring_service.dart';
import 'package:canvas_app/core/services/table_export_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:canvas_app/models/quest_table_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:canvas_app/features/resources/screens/data/table_editor_screen.dart';
import 'package:canvas_app/features/resources/screens/data/table_guide.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';

enum SortOption { nameAsc, nameDesc, usage, folder }

Map<String, int> _countVariableUsageInBackground(Map<String, dynamic> input) {
  final variableNames = (input['variables'] as List<dynamic>? ?? const [])
      .map((v) => v.toString())
      .toSet();
  final documents = (input['documents'] as List<dynamic>? ?? const []).map(
    (d) => d.toString(),
  );
  final usage = <String, int>{};

  void addUsage(String? name) {
    if (name == null || !variableNames.contains(name)) return;
    usage[name] = (usage[name] ?? 0) + 1;
  }

  void walkJson(dynamic value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final val = entry.value;
        if ((key == 'variable' ||
                key == 'переменная' ||
                key == 'targetVariable') &&
            val is String) {
          addUsage(val);
        }
        walkJson(val);
      }
      return;
    }
    if (value is List) {
      for (final item in value) {
        walkJson(item);
      }
      return;
    }
    if (value is String) {
      for (final match in RegExp(r'\{([^{}]+)\}').allMatches(value)) {
        addUsage(match.group(1));
      }
    }
  }

  final keyRegex = RegExp(
    r'"(?:variable|переменная|targetVariable)"\s*:\s*"([^"]+)"',
  );
  final inlineRegex = RegExp(r'\{([^{}]+)\}');

  for (final content in documents) {
    try {
      walkJson(jsonDecode(content));
      continue;
    } catch (_) {}

    for (final match in keyRegex.allMatches(content)) {
      addUsage(match.group(1));
    }
    for (final match in inlineRegex.allMatches(content)) {
      addUsage(match.group(1));
    }
  }

  return usage;
}

class QuestVariable {
  final String name;
  final dynamic defaultValue;
  final bool isSystem;
  final String folderPath;

  const QuestVariable({
    required this.name,
    this.defaultValue,
    this.isSystem = false,
    this.folderPath = '/',
  });
}

class VariableSelectionScreen extends StatefulWidget {
  final String questId;
  final String? selectedVariable;
  final int initialTabIndex;

  /// Если `true`, тап по таблице возвращает её имя через `Navigator.pop`
  /// (режим пикера для скрипт-блоков и вставки данных). По умолчанию —
  /// тап открывает визуальный редактор таблицы.
  final bool pickerMode;

  /// Если `true` — тап по таблице открывает редактор в режиме пикера ячейки
  /// (`TableEditorScreen.cellPickerMode`), результат — ссылка
  /// `{имя["колонка"][N]}` через `Navigator.pop`.
  final bool cellPicker;

  const VariableSelectionScreen({
    super.key,
    required this.questId,
    this.selectedVariable,
    this.initialTabIndex = 0,
    this.pickerMode = false,
    this.cellPicker = false,
  });

  /// Единая точка входа для вставки в текст (маркдаун, формулы):
  /// переменные возвращают `{имя}`, таблицы открывают редактор в режиме
  /// выбора ячейки и возвращают ссылку `{имя["колонка"][N]}`.
  /// Семантику пикера меняем здесь — вызывающим не нужно знать про `cellPicker`.
  factory VariableSelectionScreen.forTextInsert({
    required String questId,
    String? selectedVariable,
    int initialTabIndex = 0,
  }) {
    return VariableSelectionScreen(
      questId: questId,
      selectedVariable: selectedVariable,
      initialTabIndex: initialTabIndex,
      cellPicker: true,
    );
  }

  @override
  State<VariableSelectionScreen> createState() =>
      _VariableSelectionScreenState();
}

class _VariableSelectionScreenState extends State<VariableSelectionScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  late TabController _tabController;

  List<QuestVariable> _customVariables = [];
  List<QuestVariable> _systemVariables = [];
  List<QuestTable> _tables = [];
  Map<String, String> _tableFolders = {};
  List<String> _explicitFolders = [];
  Map<String, int> _variableUsage = {};
  String _searchQuery = '';
  String _currentFolder = '/';
  SortOption _sortOption = SortOption.nameAsc;
  bool _showUsedOnly = false;
  bool _showUnusedOnly = false;
  bool _scanningUsage = false;
  bool _hasUsageData = false;
  String? _usageScanError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadData();

    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  static String _normalizeFolderPath(String path) {
    if (path.isEmpty || path == '/') return '/';
    path = path.replaceAll('\\', '/');
    if (!path.startsWith('/')) path = '/$path';
    if (!path.endsWith('/')) path = '$path/';
    return path;
  }

  List<String> _subFolders() {
    if (_currentFolder == '/') {
      return _explicitFolders
          .where((f) => f.split('/').where((s) => s.isNotEmpty).length == 1)
          .toList();
    }
    final prefix = _currentFolder;
    return _explicitFolders.where((f) {
      if (!f.startsWith(prefix)) return false;
      final remainder = f.substring(prefix.length);
      return remainder.split('/').where((s) => s.isNotEmpty).length == 1;
    }).toList();
  }

  void _goUpOneLevel() {
    if (_currentFolder == '/') return;
    final parts = _currentFolder.split('/').where((s) => s.isNotEmpty).toList();
    parts.removeLast();
    setState(() {
      _currentFolder = parts.isEmpty ? '/' : '/${parts.join('/')}/';
    });
  }

  void _resetUsageData() {
    _variableUsage = {};
    _hasUsageData = false;
    _usageScanError = null;
    if (_sortOption == SortOption.usage) {
      _sortOption = SortOption.nameAsc;
    }
    _showUsedOnly = false;
    _showUnusedOnly = false;
  }

  Future<void> _scanVariableUsage() async {
    if (_scanningUsage) return;
    final variableNames = _customVariables.map((v) => v.name).toList();
    if (variableNames.isEmpty) {
      setState(() {
        _resetUsageData();
        _hasUsageData = true;
      });
      return;
    }

    setState(() {
      _scanningUsage = true;
      _usageScanError = null;
    });

    try {
      final documents = <String>[];
      final scriptsDir = QuestPaths.scriptsDir(widget.questId);
      final scriptsList = await FileStorage.listFiles(
        scriptsDir,
        extension: '.json',
      );
      for (final scriptFile in scriptsList) {
        try {
          documents.add(
            await FileStorage.readTextFile('$scriptsDir/$scriptFile'),
          );
        } catch (_) {}
      }

      final nodesDir = QuestPaths.nodesDir(widget.questId);
      final nodesList = await FileStorage.listFiles(
        nodesDir,
        extension: '.json',
      );
      for (final nodeFile in nodesList) {
        try {
          documents.add(await FileStorage.readTextFile('$nodesDir/$nodeFile'));
        } catch (_) {}
      }

      final configPath = QuestPaths.config(widget.questId);
      if (await FileStorage.exists(configPath)) {
        documents.add(await FileStorage.readTextFile(configPath));
      }

      final usage = await compute(_countVariableUsageInBackground, {
        'variables': variableNames,
        'documents': documents,
      });

      if (!mounted) return;
      setState(() {
        _variableUsage = usage;
        _hasUsageData = true;
        _scanningUsage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usageScanError = e.toString();
        _scanningUsage = false;
      });
    }
  }

  Future<void> _loadData() async {
    // Не const: подписи системных переменных строятся под текущий язык.
    final systemVars = [
      QuestVariable(
        name: 'ID',
        defaultValue: tr('ID текущей ноды'),
        isSystem: true,
      ),
      QuestVariable(
        name: 'LastID',
        defaultValue: tr('ID предыдущей ноды'),
        isSystem: true,
      ),
      QuestVariable(name: '_SYS_HOUR', defaultValue: tr('Час'), isSystem: true),
      QuestVariable(
        name: '_SYS_MINUTE',
        defaultValue: tr('Минута'),
        isSystem: true,
      ),
      QuestVariable(name: '_SYS_DAY', defaultValue: tr('День'), isSystem: true),
      QuestVariable(
        name: '_SYS_MONTH',
        defaultValue: tr('Месяц'),
        isSystem: true,
      ),
      QuestVariable(name: '_SYS_YEAR', defaultValue: tr('Год'), isSystem: true),
      QuestVariable(
        name: '_SYS_WEEKDAY',
        defaultValue: tr('День недели'),
        isSystem: true,
      ),
      QuestVariable(
        name: '_SYS_PLATFORM',
        defaultValue: tr('Платформа'),
        isSystem: true,
      ),
      QuestVariable(
        name: '_SYS_QUEST_VERSION',
        defaultValue: tr('Версия квеста'),
        isSystem: true,
      ),
      QuestVariable(
        name: 'SAVE_DATE',
        defaultValue: tr('Дата загрузки сейва (YYYY-MM-DD)'),
        isSystem: true,
      ),
      QuestVariable(
        name: 'SAVE_TIME',
        defaultValue: tr('Время загрузки сейва (HH:MM:SS)'),
        isSystem: true,
      ),
      QuestVariable(
        name: 'SAVE_DATETIME',
        defaultValue: tr('Дата и время загрузки сейва (ISO)'),
        isSystem: true,
      ),
    ];

    List<QuestVariable> customVars = [];
    List<QuestTable> tables = [];
    Map<String, String> tableFolders = {};
    List<String> folders = [];

    try {
      final configPath = QuestPaths.config(widget.questId);
      if (await FileStorage.exists(configPath)) {
        final config = await FileStorage.readJsonFile(configPath);

        final variablesJson = config['variables'] as List<dynamic>? ?? [];
        customVars = variablesJson.map((v) {
          if (v is String) return QuestVariable(name: v);
          if (v is Map<String, dynamic>) {
            return QuestVariable(
              name: v['name'] ?? 'error',
              defaultValue: v['defaultValue'],
              folderPath: _normalizeFolderPath(
                v['folderPath'] as String? ?? '/',
              ),
            );
          }
          return QuestVariable(name: 'error');
        }).toList();

        final tablesJson = config['tables'] as List<dynamic>? ?? [];
        tableFolders = <String, String>{};
        tables = tablesJson.map((t) {
          final table = QuestTable.fromJson(t);
          if (t is Map<String, dynamic>) {
            tableFolders[table.name] = _normalizeFolderPath(
              t['folderPath'] as String? ?? '/',
            );
          }
          return table;
        }).toList();

        final foldersJson = config['__varFolders__'] as List<dynamic>? ?? [];
        folders = foldersJson
            .map((f) => _normalizeFolderPath(f.toString()))
            .toSet()
            .toList();
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _customVariables = customVars;
      _systemVariables = systemVars;
      _tables = tables;
      _tableFolders = tableFolders;
      _explicitFolders = folders;
    });
  }

  Future<Map<String, dynamic>> _readConfig() async {
    final configPath = QuestPaths.config(widget.questId);
    return await FileStorage.readJsonFile(configPath);
  }

  Future<void> _writeConfig(Map<String, dynamic> config) async {
    final configPath = QuestPaths.config(widget.questId);
    final editedAt = DateTime.now().toIso8601String();
    config['lastEditedAt'] = editedAt;
    // Оставляем старый ключ для совместимости со старыми клиентами.
    config['updated'] = editedAt;
    await FileStorage.writeJsonFile(configPath, config);
  }

  Future<void> _addVariable() async {
    final nameController = TextEditingController();
    final valueController = TextEditingController();

    final result = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Новая переменная')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: InputDecoration(labelText: tr('Имя (a-z, 0-9, _)')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: valueController,
              decoration: InputDecoration(labelText: tr('Значение (опц.)')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Создать')),
          ),
        ],
      ),
    );

    if (result != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;

    dynamic val = valueController.text.trim();
    if (val.isEmpty) {
      val = null;
    } else if (num.tryParse(val) != null) {
      val = num.parse(val);
    }

    final config = await _readConfig();
    final vars = (config['variables'] as List<dynamic>? ?? []).toList();

    final varEntry = {
      'name': name,
      'defaultValue': val,
      'folderPath': _currentFolder,
    };
    vars.add(varEntry);
    config['variables'] = vars;

    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _deleteVariable(String name) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Удалить?')),
        content: Text(
          trf(
            'Переменная "{name}" будет удалена. Использования останутся как текст.',
            {'name': name},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final config = await _readConfig();
    final vars = (config['variables'] as List<dynamic>? ?? []).toList();
    vars.removeWhere((v) => (v is Map ? v['name'] : v) == name);
    config['variables'] = vars;
    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _editVariableValue(QuestVariable variable) async {
    final controller = TextEditingController(
      text: variable.defaultValue?.toString() ?? '',
    );

    final result = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trf('Изменить значение: {p0}', {'p0': variable.name})),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr('Например: 10, true, false, null, текст'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );

    if (result != true) return;

    final rawValue = controller.text.trim();
    dynamic parsed;
    if (rawValue.isEmpty || rawValue.toLowerCase() == 'null') {
      parsed = null;
    } else if (rawValue.toLowerCase() == 'true') {
      parsed = true;
    } else if (rawValue.toLowerCase() == 'false') {
      parsed = false;
    } else if (num.tryParse(rawValue) != null) {
      parsed = num.parse(rawValue);
    } else {
      parsed = rawValue;
    }

    final config = await _readConfig();
    final vars = (config['variables'] as List<dynamic>? ?? []).toList();

    for (var i = 0; i < vars.length; i++) {
      final value = vars[i];
      if (value is String && value == variable.name) {
        vars[i] = {
          'name': variable.name,
          'defaultValue': parsed,
          'folderPath': variable.folderPath,
        };
        break;
      }
      if (value is Map && value['name'] == variable.name) {
        vars[i] = {
          ...Map<String, dynamic>.from(value.cast<String, dynamic>()),
          'defaultValue': parsed,
        };
        break;
      }
    }

    config['variables'] = vars;
    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _moveVariableToFolder(
    String varName,
    String targetFolder,
  ) async {
    final config = await _readConfig();
    final vars = (config['variables'] as List<dynamic>? ?? []).toList();

    for (var i = 0; i < vars.length; i++) {
      final value = vars[i];
      if (value is Map && value['name'] == varName) {
        vars[i] = {
          ...Map<String, dynamic>.from(value.cast<String, dynamic>()),
          'folderPath': targetFolder,
        };
        break;
      }
      if (value is String && value == varName) {
        vars[i] = {
          'name': varName,
          'defaultValue': null,
          'folderPath': targetFolder,
        };
        break;
      }
    }

    config['variables'] = vars;
    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _moveTableToFolder(String tableName, String targetFolder) async {
    final config = await _readConfig();
    final tables = (config['tables'] as List<dynamic>? ?? []).toList();

    for (var i = 0; i < tables.length; i++) {
      final t = tables[i];
      if (t is Map && t['name'] == tableName) {
        tables[i] = {
          ...Map<String, dynamic>.from(t.cast<String, dynamic>()),
          'folderPath': targetFolder,
        };
        break;
      }
    }

    config['tables'] = tables;
    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _moveFolderToFolder(
    String oldFolder,
    String targetFolder,
  ) async {
    if (oldFolder == targetFolder) return;
    if (targetFolder.startsWith(oldFolder)) return;

    final config = await _readConfig();

    var folders = List<String>.from(config['__varFolders__'] ?? []);
    folders = folders
        .map((f) {
          if (f == oldFolder) return targetFolder;
          if (f.startsWith(oldFolder)) {
            return f.replaceFirst(oldFolder, targetFolder);
          }
          return f;
        })
        .toSet()
        .toList();
    config['__varFolders__'] = folders;

    final vars = (config['variables'] as List<dynamic>? ?? []).toList();
    for (var i = 0; i < vars.length; i++) {
      final v = vars[i];
      if (v is Map) {
        final fp = _normalizeFolderPath(v['folderPath'] as String? ?? '/');
        if (fp == oldFolder || fp.startsWith(oldFolder)) {
          vars[i] = {
            ...Map<String, dynamic>.from(v.cast<String, dynamic>()),
            'folderPath': fp.replaceFirst(oldFolder, targetFolder),
          };
        }
      }
    }
    config['variables'] = vars;

    final tables = (config['tables'] as List<dynamic>? ?? []).toList();
    for (var i = 0; i < tables.length; i++) {
      final t = tables[i];
      if (t is Map) {
        final fp = _normalizeFolderPath(t['folderPath'] as String? ?? '/');
        if (fp == oldFolder || fp.startsWith(oldFolder)) {
          tables[i] = {
            ...Map<String, dynamic>.from(t.cast<String, dynamic>()),
            'folderPath': fp.replaceFirst(oldFolder, targetFolder),
          };
        }
      }
    }
    config['tables'] = tables;

    await _writeConfig(config);

    if (_currentFolder == oldFolder || _currentFolder.startsWith(oldFolder)) {
      if (!mounted) return;
      setState(() {
        _currentFolder = _currentFolder.replaceFirst(oldFolder, targetFolder);
        _resetUsageData();
      });
    } else if (mounted) {
      setState(_resetUsageData);
    }

    await _loadData();
  }

  Future<void> _addTable() async {
    final nameController = TextEditingController();
    final result = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Новая таблица')),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('Название (например: inventory)'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Создать')),
          ),
        ],
      ),
    );

    if (result != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;

    final newTable = QuestTable(name: name, columns: [], rows: []);

    final config = await _readConfig();
    final tables = (config['tables'] as List<dynamic>? ?? []).toList();

    final duplicate = tables.any(
      (t) => t is Map && t['name']?.toString() == name,
    );
    if (duplicate) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Таблица «{p0}» уже существует', {'p0': name})),
          ),
        );
      }
      return;
    }

    tables.add({...newTable.toJson(), 'folderPath': _currentFolder});
    config['tables'] = tables;

    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _renameTableOrVariable(String oldName, bool isTable) async {
    final controller = TextEditingController(text: oldName);
    final newName = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          trf('Переименовать {p0}', {
            'p0': isTable ? tr('таблицу') : tr('переменную'),
          }),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(filled: true),
            ),
            const SizedBox(height: 10),
            Text(
              tr(
                'Изменение автоматически обновит имя во всех скриптах и нодах.',
              ),
              style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Переименовать')),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == oldName) return;
    if (!mounted) return;

    // Переезд на занятое имя слил бы две переменные: рефакторинг
    // переписал бы ссылки на старую, а в config остались бы две записи.
    final taken = <String>{
      ..._customVariables.map((v) => v.name),
      ..._systemVariables.map((v) => v.name),
      ..._tables.map((t) => t.name),
    }..remove(oldName);
    if (taken.contains(newName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trf('Имя «{newName}» уже занято', {'newName': newName}),
          ),
        ),
      );
      return;
    }

    final count = await RefactoringService.renameVariableOrTable(
      questId: widget.questId,
      oldName: oldName,
      newName: newName,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(trf('Обновлено файлов: {count}', {'count': count})),
      ),
    );
    setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _editTable(QuestTable table) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => TableEditorScreen(
          questId: widget.questId,
          table: table,
          onSave: (updated) {
            // отложенный вызов: редактор pop-ит себя в следующем кадре
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _saveEditedTable(updated),
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickTableCell(QuestTable table) async {
    final ref = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => TableEditorScreen(
          questId: widget.questId,
          table: table,
          onSave: (updated) {},
          cellPickerMode: true,
        ),
      ),
    );
    if (ref != null && mounted) {
      Navigator.pop(context, ref);
    }
  }

  Future<void> _saveEditedTable(QuestTable updated) async {
    final config = await _readConfig();
    final tables = (config['tables'] as List<dynamic>? ?? []).toList();

    var found = false;
    for (var i = 0; i < tables.length; i++) {
      final t = tables[i];
      if (t is Map && t['name'] == updated.name) {
        final folder = t['folderPath'];
        tables[i] = {...updated.toJson(), 'folderPath': ?folder};
        found = true;
        break;
      }
    }
    if (!found) {
      tables.add({...updated.toJson(), 'folderPath': _currentFolder});
    }
    config['tables'] = tables;
    await _writeConfig(config);
    if (mounted) {
      setState(_resetUsageData);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Таблица сохранена'))));
    }
    await _loadData();
  }

  Future<void> _exportTable(QuestTable table, String format) async {
    try {
      final ok = switch (format) {
        'csv' => await TableExportService.exportTableCsv(table),
        'xlsx' => await TableExportService.exportTableXlsx(table),
        'json' => await TableExportService.exportTableJson(table),
        _ => false,
      };
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Таблица экспортирована'))));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(trf('Ошибка экспорта: {p0}', {'p0': friendlyError(e)})),
        ),
      );
    }
  }

  Future<void> _importTable() async {
    final files = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['csv', 'json'],
    );
    if (files.isEmpty || files.single.path == null || !mounted) {
      return;
    }

    try {
      final imported = await TableExportService.importTableFromFile(
        files.single.path!,
      );

      final existing = _tables.where((t) => t.name == imported.name).toList();
      if (existing.isNotEmpty) {
        if (!mounted) return;
        final confirm = await showAppDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Таблица уже существует')),
            content: Text(
              trf(
                'Таблица «{p0}» уже есть в квесте. Заменить её данными из файла?',
                {'p0': imported.name},
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('Отмена')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('Заменить')),
              ),
            ],
          ),
        );
        if (confirm != true || !mounted) return;
        await _saveEditedTable(imported);
        return;
      }

      final nameController = TextEditingController(text: imported.name);
      if (!mounted) return;
      final finalName = await showAppDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Импорт таблицы')),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('Название таблицы')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
              child: Text(tr('Импортировать')),
            ),
          ],
        ),
      );
      if (finalName == null || finalName.isEmpty || !mounted) return;

      final renamed = QuestTable(
        name: finalName,
        columns: imported.columns,
        rows: imported.rows,
        rowNames: imported.rowNames,
        data: imported.data,
      );
      await _saveEditedTable(renamed);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(trf('Ошибка импорта: {p0}', {'p0': friendlyError(e)})),
        ),
      );
    }
  }

  Future<void> _deleteTable(String name) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Удалить таблицу?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Нет')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Да')),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final config = await _readConfig();
    final tables = (config['tables'] as List<dynamic>? ?? []).toList();
    tables.removeWhere((t) => t['name'] == name);
    config['tables'] = tables;
    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _createFolder() async {
    final nameController = TextEditingController();
    final result = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Новая папка')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_currentFolder != '/')
              Text(
                trf('В папке: {_currentFolder}', {
                  '_currentFolder': _currentFolder,
                }),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('Название папки'),
                hintText: tr('Например: Stats'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Создать')),
          ),
        ],
      ),
    );

    if (result != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty || name.contains('/') || name.contains('\\')) return;

    final folderPath = _normalizeFolderPath('$_currentFolder$name');
    if (_explicitFolders.contains(folderPath)) return;

    final config = await _readConfig();
    final folders = List<String>.from(config['__varFolders__'] ?? []);
    folders.add(folderPath);
    config['__varFolders__'] = folders;

    await _writeConfig(config);
    if (mounted) setState(_resetUsageData);
    await _loadData();
  }

  Future<void> _renameFolder(String oldFolder) async {
    final oldName = oldFolder.split('/').where((s) => s.isNotEmpty).last;
    final nameController = TextEditingController(text: oldName);
    final newName = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Переименовать папку')),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(labelText: tr('Новое название')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
            child: Text(tr('Переименовать')),
          ),
        ],
      ),
    );

    if (newName == null ||
        newName.isEmpty ||
        newName == oldName ||
        newName.contains('/')) {
      return;
    }

    final parentPath = oldFolder.substring(
      0,
      oldFolder.lastIndexOf('/', oldFolder.length - 2) + 1,
    );
    final newFolder = _normalizeFolderPath('$parentPath$newName');
    if (_explicitFolders.contains(newFolder)) return;

    final config = await _readConfig();

    var folders = List<String>.from(config['__varFolders__'] ?? []);
    folders = folders
        .map((f) {
          if (f == oldFolder) return newFolder;
          if (f.startsWith(oldFolder)) {
            return f.replaceFirst(oldFolder, newFolder);
          }
          return f;
        })
        .toSet()
        .toList();
    config['__varFolders__'] = folders;

    final vars = (config['variables'] as List<dynamic>? ?? []).toList();
    for (var i = 0; i < vars.length; i++) {
      final v = vars[i];
      if (v is Map) {
        final fp = _normalizeFolderPath(v['folderPath'] as String? ?? '/');
        if (fp == oldFolder || fp.startsWith(oldFolder)) {
          vars[i] = {
            ...Map<String, dynamic>.from(v.cast<String, dynamic>()),
            'folderPath': fp.replaceFirst(oldFolder, newFolder),
          };
        }
      }
    }
    config['variables'] = vars;

    final tables = (config['tables'] as List<dynamic>? ?? []).toList();
    for (var i = 0; i < tables.length; i++) {
      final t = tables[i];
      if (t is Map) {
        final fp = _normalizeFolderPath(t['folderPath'] as String? ?? '/');
        if (fp == oldFolder || fp.startsWith(oldFolder)) {
          tables[i] = {
            ...Map<String, dynamic>.from(t.cast<String, dynamic>()),
            'folderPath': fp.replaceFirst(oldFolder, newFolder),
          };
        }
      }
    }
    config['tables'] = tables;

    await _writeConfig(config);

    if (_currentFolder == oldFolder || _currentFolder.startsWith(oldFolder)) {
      if (!mounted) return;
      setState(() {
        _currentFolder = _currentFolder.replaceFirst(oldFolder, newFolder);
        _resetUsageData();
      });
    } else if (mounted) {
      setState(_resetUsageData);
    }

    await _loadData();
  }

  Future<void> _deleteFolder(String folder) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Удалить папку?')),
        content: Text(tr('Переменные и таблицы будут перемещены в корень.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final config = await _readConfig();

    var folders = List<String>.from(config['__varFolders__'] ?? []);
    final subFolders = folders
        .where((f) => f == folder || f.startsWith(folder))
        .toList();
    folders.removeWhere((f) => subFolders.contains(f));
    config['__varFolders__'] = folders;

    final vars = (config['variables'] as List<dynamic>? ?? []).toList();
    for (var i = 0; i < vars.length; i++) {
      final v = vars[i];
      if (v is Map) {
        final fp = _normalizeFolderPath(v['folderPath'] as String? ?? '/');
        if (fp == folder || fp.startsWith(folder)) {
          vars[i] = {
            ...Map<String, dynamic>.from(v.cast<String, dynamic>()),
            'folderPath': '/',
          };
        }
      }
    }
    config['variables'] = vars;

    final tables = (config['tables'] as List<dynamic>? ?? []).toList();
    for (var i = 0; i < tables.length; i++) {
      final t = tables[i];
      if (t is Map) {
        final fp = _normalizeFolderPath(t['folderPath'] as String? ?? '/');
        if (fp == folder || fp.startsWith(folder)) {
          tables[i] = {
            ...Map<String, dynamic>.from(t.cast<String, dynamic>()),
            'folderPath': '/',
          };
        }
      }
    }
    config['tables'] = tables;

    await _writeConfig(config);

    if (_currentFolder == folder || _currentFolder.startsWith(folder)) {
      if (!mounted) return;
      setState(() {
        _currentFolder = '/';
        _resetUsageData();
      });
    } else if (mounted) {
      setState(_resetUsageData);
    }

    await _loadData();
  }

  void _showFabMenu() {
    final scheme = Theme.of(context).colorScheme;
    showAdaptiveSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_tabController.index == 0 || _tabController.index == 2)
                _buildSheetTile(
                  icon: _tabController.index == 0
                      ? Icons.tag_rounded
                      : Icons.table_chart_rounded,
                  iconColor: _tabController.index == 0
                      ? scheme.primary
                      : scheme.tertiary,
                  title: _tabController.index == 0
                      ? tr('Добавить переменную')
                      : tr('Добавить таблицу'),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_tabController.index == 0) {
                      _addVariable();
                    } else {
                      _addTable();
                    }
                  },
                ),
              if (_tabController.index == 2)
                _buildSheetTile(
                  icon: Icons.download_for_offline_rounded,
                  iconColor: scheme.secondary,
                  title: tr('Импорт таблицы (CSV / JSON)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _importTable();
                  },
                ),
              _buildSheetTile(
                icon: Icons.create_new_folder_rounded,
                iconColor: scheme.secondary,
                title: tr('Создать папку'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createFolder();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSheetTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Text(
                title,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFolderBreadcrumb(String label, String path, bool isCurrent) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: isCurrent ? null : () => setState(() => _currentFolder = path),
      child: Text(
        label,
        style: TextStyle(
          color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          decoration: isCurrent ? null : TextDecoration.underline,
        ),
      ),
    );
  }

  Widget _buildBreadcrumbBar() {
    if (_currentFolder == '/') {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;

    final parts = _currentFolder.split('/').where((s) => s.isNotEmpty).toList();
    final breadcrumbs = <Widget>[
      _buildFolderBreadcrumb(tr('Все'), '/', _currentFolder == '/'),
    ];

    String accumulatedPath = '/';
    for (final part in parts) {
      accumulatedPath = _normalizeFolderPath('$accumulatedPath$part');
      final isLast = accumulatedPath == _currentFolder;
      breadcrumbs.add(
        Text(' / ', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
      breadcrumbs.add(_buildFolderBreadcrumb(part, accumulatedPath, isLast));
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_upward,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: _currentFolder == '/' ? null : _goUpOneLevel,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: breadcrumbs),
            ),
          ),
        ],
      ),
    );
  }

  List<QuestVariable> _sortAndFilterVariables(List<QuestVariable> vars) {
    var list = [...vars];

    if (_showUsedOnly) {
      list = list.where((v) => (_variableUsage[v.name] ?? 0) > 0).toList();
    }
    if (_showUnusedOnly) {
      list = list.where((v) => (_variableUsage[v.name] ?? 0) == 0).toList();
    }

    switch (_sortOption) {
      case SortOption.nameAsc:
        list.sort((a, b) => a.name.compareTo(b.name));
        break;
      case SortOption.nameDesc:
        list.sort((a, b) => b.name.compareTo(a.name));
        break;
      case SortOption.usage:
        list.sort((a, b) {
          final aUsed = (_variableUsage[a.name] ?? 0) > 0;
          final bUsed = (_variableUsage[b.name] ?? 0) > 0;
          if (aUsed && !bUsed) return -1;
          if (!aUsed && bUsed) return 1;
          return (_variableUsage[b.name] ?? 0).compareTo(
            _variableUsage[a.name] ?? 0,
          );
        });
        break;
      case SortOption.folder:
        list.sort((a, b) => a.folderPath.compareTo(b.folderPath));
        break;
    }

    return list;
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    IconData? icon,
    VoidCallback? onTap,
  }) {
    return FilterChip(
      label: Text(label),
      avatar: icon == null ? null : Icon(icon, size: 18),
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap(),
    );
  }

  Widget _buildUsagePanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usedCount = _variableUsage.values.where((v) => v > 0).length;
    final usageText = _scanningUsage
        ? tr('Анализ идет в фоне')
        : (_hasUsageData
              ? trf('{p0} из {p1} используются', {
                  'p0': usedCount,
                  'p1': _customVariables.length,
                })
              : tr('Проверка запускается вручную'));

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _hasUsageData
                    ? scheme.primaryContainer
                    : scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: _scanningUsage
                  ? Padding(
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: scheme.onSecondaryContainer,
                      ),
                    )
                  : Icon(
                      _hasUsageData
                          ? Icons.fact_check_rounded
                          : Icons.manage_search_rounded,
                      color: _hasUsageData
                          ? scheme.onPrimaryContainer
                          : scheme.onSecondaryContainer,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    usageText,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    trf('{p0} переменных · {p1} таблиц · {p2} папок', {
                      'p0': _customVariables.length,
                      'p1': _tables.length,
                      'p2': _explicitFolders.length,
                    }),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _scanningUsage ? null : _scanVariableUsage,
              icon: const Icon(Icons.visibility_outlined),
              tooltip: _hasUsageData
                  ? tr('Обновить использование')
                  : tr('Проверить использование'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _searchController.text.isNotEmpty;
    return SizedBox(
      height: 52,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        child: Row(
          children: [
            const SizedBox(width: 16),
            Icon(
              Icons.search_rounded,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: scheme.onSurface, fontSize: 15),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: tr(
                    'Поиск по переменным, системным данным, таблицам...',
                  ),
                  hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 15,
                  ),
                ),
                textInputAction: TextInputAction.search,
              ),
            ),
            if (hasText)
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: tr('Очистить'),
                onPressed: _searchController.clear,
              )
            else
              PopupMenuButton<SortOption>(
                icon: const Icon(Icons.tune_rounded),
                tooltip: tr('Сортировка'),
                onSelected: (val) => setState(() => _sortOption = val),
                itemBuilder: (ctx) => [
                  CheckedPopupMenuItem(
                    value: SortOption.nameAsc,
                    checked: _sortOption == SortOption.nameAsc,
                    child: Text(tr('По имени (А-Я)')),
                  ),
                  CheckedPopupMenuItem(
                    value: SortOption.nameDesc,
                    checked: _sortOption == SortOption.nameDesc,
                    child: Text(tr('По имени (Я-А)')),
                  ),
                  CheckedPopupMenuItem(
                    value: SortOption.usage,
                    enabled: _hasUsageData,
                    checked: _sortOption == SortOption.usage,
                    child: Text(tr('По использованию')),
                  ),
                  CheckedPopupMenuItem(
                    value: SortOption.folder,
                    checked: _sortOption == SortOption.folder,
                    child: Text(tr('По папке')),
                  ),
                ],
              ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(tr('Данные')),
        actions: [
          IconButton(
            icon: _scanningUsage
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  )
                : const Icon(Icons.visibility_outlined),
            tooltip: _hasUsageData
                ? tr('Обновить использование')
                : tr('Проверить использование'),
            onPressed: _scanningUsage ? null : _scanVariableUsage,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
          tabs: [
            Tab(text: tr('Переменные')),
            Tab(text: tr('Системные')),
            Tab(text: tr('Таблицы')),
          ],
        ),
      ),
      body: AdaptiveContent(
        // Пикер переменных — список на всю ширину окна: имя переменной
        // уезжало от своего значения на полмонитора.
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: _buildUsagePanel(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _buildSearchField(context),
              ),
              if (_usageScanError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      trf(
                        'Не удалось проверить использование: {_usageScanError}',
                        {'_usageScanError': _usageScanError},
                      ),
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (_tabController.index == 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildFilterChip(
                          label: tr('Все'),
                          icon: Icons.apps_rounded,
                          selected: !_showUsedOnly && !_showUnusedOnly,
                          onTap: () {
                            setState(() {
                              _showUsedOnly = false;
                              _showUnusedOnly = false;
                            });
                          },
                        ),
                        const SizedBox(width: 6),
                        _buildFilterChip(
                          label: tr('Используемые'),
                          icon: Icons.check_circle_outline_rounded,
                          selected: _showUsedOnly,
                          onTap: !_hasUsageData
                              ? null
                              : () {
                                  setState(() {
                                    _showUsedOnly = true;
                                    _showUnusedOnly = false;
                                  });
                                },
                        ),
                        const SizedBox(width: 6),
                        _buildFilterChip(
                          label: tr('Неиспользуемые'),
                          icon: Icons.hide_source_rounded,
                          selected: _showUnusedOnly,
                          onTap: !_hasUsageData
                              ? null
                              : () {
                                  setState(() {
                                    _showUnusedOnly = true;
                                    _showUsedOnly = false;
                                  });
                                },
                        ),
                      ],
                    ),
                  ),
                ),
              if (_tabController.index != 1) _buildBreadcrumbBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildCustomVariablesList(),
                    _buildSystemVariablesList(),
                    _buildTablesList(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'variable_editor_fab_${widget.questId}',
        onPressed: () {
          _showFabMenu();
        },
        child: const Icon(Icons.add_rounded, size: 28),
      ),
    );
  }

  Widget _buildCustomVariablesList() {
    final scheme = Theme.of(context).colorScheme;
    final subFolders = _subFolders();
    final filtered = _customVariables
        .where((v) => v.folderPath == _currentFolder)
        .where((v) => v.name.toLowerCase().contains(_searchQuery))
        .toList();

    final sorted = _sortAndFilterVariables(filtered);

    if (subFolders.isEmpty && sorted.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            tr('Нет переменных'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final items = <Widget>[];

    if (subFolders.isNotEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            tr('Папки'),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
      );
      for (final folder in subFolders) {
        items.add(_buildFolderTile(folder));
      }
    }

    if (subFolders.isNotEmpty && sorted.isNotEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            tr('Переменные'),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
      );
    }

    for (final v in sorted) {
      items.add(_buildVariableTile(v));
    }

    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }

  Widget _buildFolderTile(String folder) {
    final scheme = Theme.of(context).colorScheme;
    final folderName = folder.split('/').where((s) => s.isNotEmpty).last;
    final varCount = _customVariables
        .where((v) => v.folderPath == folder)
        .length;
    final tableCount = _tables.where((t) {
      final fp = _normalizeFolderPath(_tableFolders[t.name] ?? '/');
      return fp == folder;
    }).length;
    final itemCount = varCount + tableCount;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      // Цвет и рамка — на Material (а не на декорации контейнера):
      // ListTile рисует фон/ink на ближайшем Material-предке, цветная
      // декорация между ними прячет эффекты и даёт runtime-ворнинг.
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.folder_rounded,
              color: scheme.onSecondaryContainer,
              size: 22,
            ),
          ),
          title: Text(
            folderName,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          subtitle: Text(
            itemCount == 1
                ? tr('1 элемент')
                : trf('{itemCount} элементов', {'itemCount': itemCount}),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          trailing: PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
            onSelected: (val) {
              if (val == 'rename') _renameFolder(folder);
              if (val == 'delete') _deleteFolder(folder);
              if (val == 'move_pick') {
                _pickFolderAndMoveFolder(folder);
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'rename', child: Text(tr('Переименовать'))),
              PopupMenuItem(
                value: 'move_pick',
                child: Row(
                  children: [
                    Icon(Icons.folder_open, size: 18),
                    SizedBox(width: 8),
                    Text(tr('Переместить в папку...')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(tr('Удалить'), style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
          onTap: () => setState(() => _currentFolder = folder),
        ),
      ),
    );
  }

  Widget _buildVariableTile(QuestVariable v) {
    final scheme = Theme.of(context).colorScheme;
    final usageCount = _variableUsage[v.name] ?? 0;
    final isUsed = usageCount > 0;
    final hasUsageData = _hasUsageData;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasUsageData
              ? (isUsed
                    ? scheme.primary.withOpacity(0.35)
                    : scheme.outlineVariant)
              : scheme.outlineVariant,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.pop(context, v.name),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.tag_rounded,
                    color: scheme.onPrimaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              v.name,
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                letterSpacing: -0.2,
                                decoration: !isUsed && hasUsageData
                                    ? TextDecoration.lineThrough
                                    : null,
                                decorationColor: scheme.outline,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (hasUsageData) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isUsed
                                    ? scheme.primaryContainer
                                    : scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                isUsed ? '$usageCount' : '—',
                                style: TextStyle(
                                  color: isUsed
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurfaceVariant,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        v.defaultValue?.toString() ?? 'null',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
                  onSelected: (val) {
                    if (val == 'edit_value') _editVariableValue(v);
                    if (val == 'rename') _renameTableOrVariable(v.name, false);
                    if (val == 'delete') _deleteVariable(v.name);
                    if (val == 'move_pick') {
                      _pickFolderAndMove(itemName: v.name, isTable: false);
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'edit_value',
                      child: Text(tr('Изменить значение')),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(tr('Переименовать')),
                    ),
                    PopupMenuItem(
                      value: 'move_pick',
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_open,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          SizedBox(width: 8),
                          Text(tr('Переместить в папку...')),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        tr('Удалить'),
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFolderAndMove({
    required String itemName,
    required bool isTable,
  }) async {
    final targetFolder = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => _VarFolderPickerScreen(
          questId: widget.questId,
          currentFolder: _currentFolder,
          allFolders: _explicitFolders,
        ),
      ),
    );
    if (targetFolder == null || !mounted) return;

    if (isTable) {
      await _moveTableToFolder(itemName, targetFolder);
    } else {
      await _moveVariableToFolder(itemName, targetFolder);
    }
  }

  Future<void> _pickFolderAndMoveFolder(String folder) async {
    final targetFolder = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => _VarFolderPickerScreen(
          questId: widget.questId,
          currentFolder: _currentFolder,
          allFolders: _explicitFolders,
          excludePath: folder,
        ),
      ),
    );
    if (targetFolder == null || !mounted) return;

    await _moveFolderToFolder(folder, targetFolder);
  }

  Widget _buildSystemVariablesList() {
    final scheme = Theme.of(context).colorScheme;
    final filtered = _systemVariables
        .where((v) => v.name.toLowerCase().contains(_searchQuery))
        .toList();

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final v = filtered[index];
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => Navigator.pop(context, v.name),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.auto_awesome_rounded,
                        color: scheme.onTertiaryContainer,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            v.name,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            v.defaultValue?.toString() ?? 'null',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTablesList() {
    final scheme = Theme.of(context).colorScheme;
    final subFolders = _subFolders();
    final filtered = _tables
        .where((t) {
          final fp = _normalizeFolderPath(_tableFolders[t.name] ?? '/');
          return fp == _currentFolder;
        })
        .where((t) => t.name.toLowerCase().contains(_searchQuery))
        .toList();

    if (subFolders.isEmpty && filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            tr('Нет таблиц'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final items = <Widget>[];

    if (widget.pickerMode && !widget.cellPicker) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TableHintBanner(
            text: tr(
              'Блок «Данные» читает ключи хранилища скриптов, а не ряды сетки. Ключи видны в редакторе таблицы.',
            ),
            detailsLabel: tr('Шпаргалка'),
            onDetails: () => showTableGuide(context),
          ),
        ),
      );
    }

    if (subFolders.isNotEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            tr('Папки'),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
      );
      for (final folder in subFolders) {
        items.add(_buildFolderTile(folder));
      }
    }

    if (subFolders.isNotEmpty && filtered.isNotEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            tr('Таблицы'),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
      );
    }

    for (final t in filtered) {
      items.add(_buildTableTile(t));
    }

    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }

  Widget _buildTableTile(QuestTable t) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            if (widget.cellPicker) {
              _pickTableCell(t);
            } else if (widget.pickerMode) {
              Navigator.pop(context, t.name);
            } else {
              _editTable(t);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.table_chart_rounded,
                    color: scheme.onTertiaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.name,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // Без счётчика ключей автор выбирает таблицу с красивой
                        // сеткой и блок молчит: в хранилище скриптов пусто.
                        trf('{p0} столбцов · {p1} строк · {p2}', {
                          'p0': t.columns.length,
                          'p1': t.rows.length,
                          'p2': t.data.isEmpty
                              ? tr('хранилище скриптов пусто')
                              : trf('ключей скриптов: {p0}', {
                                  'p0': t.data.length,
                                }),
                        }),
                        style: TextStyle(
                          color: t.data.isEmpty
                              ? scheme.error.withValues(alpha: 0.8)
                              : scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
                  onSelected: (val) {
                    if (val == 'rename') _renameTableOrVariable(t.name, true);
                    if (val == 'edit') _editTable(t);
                    if (val == 'delete') _deleteTable(t.name);
                    if (val == 'move_pick') {
                      _pickFolderAndMove(itemName: t.name, isTable: true);
                    }
                    if (val == 'export_csv') _exportTable(t, 'csv');
                    if (val == 'export_xlsx') _exportTable(t, 'xlsx');
                    if (val == 'export_json') _exportTable(t, 'json');
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(tr('Редактировать')),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(tr('Переименовать')),
                    ),
                    PopupMenuItem(
                      value: 'move_pick',
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_open,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          SizedBox(width: 8),
                          Text(tr('Переместить в папку...')),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'export_csv',
                      child: Text(tr('Экспорт: CSV')),
                    ),
                    PopupMenuItem(
                      value: 'export_xlsx',
                      child: Text(tr('Экспорт: XLSX (Excel)')),
                    ),
                    PopupMenuItem(
                      value: 'export_json',
                      child: Text(tr('Экспорт: JSON')),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        tr('Удалить'),
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VarFolderPickerScreen extends StatefulWidget {
  final String questId;
  final String currentFolder;
  final List<String> allFolders;
  final String? excludePath;

  const _VarFolderPickerScreen({
    required this.questId,
    required this.currentFolder,
    required this.allFolders,
    this.excludePath,
  });

  @override
  State<_VarFolderPickerScreen> createState() => _VarFolderPickerScreenState();
}

class _VarFolderPickerScreenState extends State<_VarFolderPickerScreen> {
  late String _currentFolder;
  late List<String> _allFolders;

  @override
  void initState() {
    super.initState();
    _currentFolder = widget.currentFolder;
    _allFolders = [...widget.allFolders];
    if (!_allFolders.contains('/')) {
      _allFolders.insert(0, '/');
    }
  }

  List<String> get _currentSubFolders {
    final sub = <String>{};
    for (final f in _allFolders) {
      if (widget.excludePath != null &&
          (f == widget.excludePath ||
              f.startsWith('${widget.excludePath!}/'))) {
        continue;
      }
      if (f.startsWith(_currentFolder) && f != _currentFolder) {
        String relative = f.substring(_currentFolder.length);
        if (relative.startsWith('/')) relative = relative.substring(1);
        final parts = relative.split('/');
        if (parts.isNotEmpty && parts[0].isNotEmpty) {
          sub.add(parts[0]);
        }
      }
    }
    return sub.toList()..sort();
  }

  void _goUp() {
    if (_currentFolder == '/') return;
    final parts = _currentFolder.split('/');
    if (parts.length <= 2) {
      setState(() => _currentFolder = '/');
    } else {
      parts.removeLast();
      setState(() => _currentFolder = parts.join('/'));
    }
  }

  void _openFolder(String name) {
    setState(() {
      _currentFolder = _currentFolder == '/'
          ? '/$name'
          : '$_currentFolder/$name';
    });
  }

  String _normalizeFolderPath(String path) {
    if (path.isEmpty || path == '/') return '/';
    path = path.replaceAll('\\', '/');
    if (!path.startsWith('/')) path = '/$path';
    if (!path.endsWith('/')) path = '$path/';
    return path;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = <String>[];
    if (_currentFolder != '/') entries.add('..');
    entries.addAll(_currentSubFolders);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(tr('Выбрать папку')),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: scheme.surfaceContainerHigh,
            child: Row(
              children: [
                Icon(Icons.folder_open, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _currentFolder,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      tr('Нет подпапок'),
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final name = entries[index];
                      final isBack = name == '..';
                      return ListTile(
                        leading: Icon(
                          isBack ? Icons.keyboard_return_rounded : Icons.folder,
                          color: isBack
                              ? scheme.onSurfaceVariant
                              : scheme.primary,
                        ),
                        title: Text(
                          name,
                          style: TextStyle(color: scheme.onSurface),
                        ),
                        onTap: isBack ? _goUp : () => _openFolder(name),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(
                  context,
                  _normalizeFolderPath(_currentFolder),
                ),
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  tr('Переместить сюда'),
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
