import 'dart:async';
import 'dart:io';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_image_source.dart';
import 'package:canvas_app/models/content_item_model.dart';
import 'package:canvas_app/features/resources/screens/resource_selection_screen.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

class ChatEditorScreen extends StatefulWidget {
  final String questId;
  final ContentItem existingItem;

  /// Автосохранение в родительскую вкладку без закрытия экрана.
  final ValueChanged<ContentItem>? onChanged;

  const ChatEditorScreen({
    super.key,
    required this.questId,
    required this.existingItem,
    this.onChanged,
  });

  @override
  State<ChatEditorScreen> createState() => _ChatEditorScreenState();
}

class _ChatEditorScreenState extends State<ChatEditorScreen> {
  String? _lastAutosave;
  late TextEditingController _senderController;
  late TextEditingController _textController;
  late bool _isIncoming;
  String? _avatarPath;
  late int _avatarColor;
  late bool _animateIn;
  final Map<String, String> _resourceNames = {};

  static const List<int> _avatarColors = [
    0xFF26C6DA,
    0xFF00C853,
    0xFFFF7043,
    0xFFAB47BC,
    0xFF42A5F5,
    0xFFEC407A,
    0xFFFFCA28,
    0xFF8D6E63,
    0xFF78909C,
    0xFF66BB6A,
  ];

  @override
  void initState() {
    super.initState();
    _senderController = TextEditingController(
      text: widget.existingItem.senderName ?? '',
    );
    _textController = TextEditingController(
      text: widget.existingItem.text ?? '',
    );
    _isIncoming = widget.existingItem.isIncoming;
    _avatarPath = widget.existingItem.avatarPath;
    _avatarColor = widget.existingItem.avatarColor ?? 0xFF26C6DA;
    _animateIn = widget.existingItem.animateIn;
    _lastAutosave = _snapshot(_buildItem());
    _senderController.addListener(_scheduleAutosave);
    _textController.addListener(_scheduleAutosave);
    _loadMetadataNames();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleAutosave();
  }

  void _scheduleAutosave() => _emitAutosave();

  String _snapshot(ContentItem item) => item.toJson().toString();

  void _emitAutosave() {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    final item = _buildItem();
    final snapshot = _snapshot(item);
    if (snapshot == _lastAutosave) return;
    _lastAutosave = snapshot;
    onChanged(item);
  }

  ContentItem _buildItem() => ContentItem(
    id: widget.existingItem.id,
    type: 'chat',
    text: _textController.text,
    senderName: _senderController.text.trim(),
    isIncoming: _isIncoming,
    avatarPath: _avatarPath,
    avatarColor: _avatarColor,
    animateIn: _animateIn,
    flex: widget.existingItem.flex,
  );

  @override
  void dispose() {
    _senderController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadMetadataNames() async {
    try {
      final metaPath = QuestPaths.metadata(widget.questId);
      if (!await FileStorage.exists(metaPath)) return;
      final metadata = await FileStorage.readJsonFile(metaPath);
      if (!mounted) return;
      setState(() {
        _resourceNames.clear();
        metadata.forEach((key, value) {
          if (value is Map && value['name'] != null) {
            _resourceNames[key] = value['name'].toString();
          } else if (value is String) {
            _resourceNames[key] = value;
          }
        });
      });
    } catch (_) {}
  }

  String _resolveDisplayName(String? path) {
    if (path == null || path.isEmpty) return tr('Не выбрано');
    final fileName = p.basename(path);
    return _resourceNames[fileName] ?? p.basenameWithoutExtension(fileName);
  }

  Future<void> _pickAvatar() async {
    final result = await Navigator.push<SelectableResource>(
      context,
      MaterialPageRoute(
        builder: (_) => ResourceSelectionScreen(
          questId: widget.questId,
          allowedTypes: const ['image'],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => _avatarPath = result.path);
    }
  }

  Future<void> _save() async {
    final sender = _senderController.text.trim();
    if (sender.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Введите имя отправителя')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final result = _buildItem();

    if (!mounted) return;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _save();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        appBar: AppBar(
          title: Text(tr('Чат (сообщение)')),
          backgroundColor: const Color(0xFF1E1E1E),
        ),
        body: AdaptiveContent(
          maxWidth: 720,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Имя отправителя'),
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _senderController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: tr('Имя отправителя'),
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF00C853)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    tr('Направление'),
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _DirectionToggle(
                          label: tr('Входящее'),
                          isSelected: _isIncoming,
                          onTap: () => setState(() => _isIncoming = true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _DirectionToggle(
                          label: tr('Исходящее'),
                          isSelected: !_isIncoming,
                          onTap: () => setState(() => _isIncoming = false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    tr('Аватарка'),
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _avatarPath != null
                        ? FutureBuilder<File?>(
                            // Резолвер библиотеки: аватарку можно указать именем
                            // файла или uuid, а не точным путём.
                            future: QuestImageSource.resolve(
                              widget.questId,
                              _avatarPath,
                            ),
                            builder: (context, snapshot) {
                              if (snapshot.hasData && snapshot.data != null) {
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: Image.file(
                                    snapshot.data!,
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                  ),
                                );
                              }
                              return _ColorAvatar(color: _avatarColor);
                            },
                          )
                        : _ColorAvatar(color: _avatarColor),
                    title: Text(
                      _resolveDisplayName(_avatarPath),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    trailing: const Icon(Icons.edit, color: Colors.white54),
                    onTap: _pickAvatar,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Цвет аватарки (если нет изображения)'),
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _avatarColors.map((color) {
                      return GestureDetector(
                        onTap: () => setState(() => _avatarColor = color),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Color(color),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _avatarColor == color
                                  ? Colors.white
                                  : Colors.white24,
                              width: _avatarColor == color ? 2 : 1,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    title: Text(
                      tr('Анимация появления'),
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      tr('Плавное появление сообщения снизу'),
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    value: _animateIn,
                    activeColor: const Color(0xFF00C853),
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) => setState(() => _animateIn = val),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    tr('Текст сообщения'),
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 6,
                      decoration: InputDecoration(
                        hintText: tr('Текст сообщения (поддерживается markdown)'),
                        hintStyle: TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00C853),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        tr('Сохранить'),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectionToggle extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _DirectionToggle({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00C853).withOpacity(0.15)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF00C853)
                : Colors.white.withOpacity(0.1),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? const Color(0xFF00C853) : Colors.white70,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorAvatar extends StatelessWidget {
  final int color;

  const _ColorAvatar({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: Color(color), shape: BoxShape.circle),
      child: const Icon(Icons.person, color: Colors.white, size: 22),
    );
  }
}
