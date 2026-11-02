import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';

import 'package:mnd_core/mnd_core.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/music_provider.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/utils/error_text.dart';

const kMusicGenres = [
  'Ambient',
  'Epic',
  'Synthwave',
  'Folk',
  'Horror',
  'Orchestral',
  'Electronic',
  'Lo-Fi',
];

class MusicLibraryScreen extends ConsumerStatefulWidget {
  final String? questId; // if picker mode, quest to add track to
  final bool pickerMode;
  const MusicLibraryScreen({super.key, this.questId, this.pickerMode = false});

  @override
  ConsumerState<MusicLibraryScreen> createState() => _MusicLibraryScreenState();
}

class _MusicLibraryScreenState extends ConsumerState<MusicLibraryScreen> {
  final _searchCtrl = TextEditingController();
  final _player = AudioPlayer();
  StreamSubscription? _completeSub;
  String? _playingId;
  bool _isUploading = false;
  double _uploadProgress = 0;

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _preview(MusicTrack t) async {
    try {
      if (_playingId == t.id) {
        await _player.stop();
        if (!mounted) return;
        setState(() => _playingId = null);
        return;
      }
      await _player.stop();
      await _player.play(UrlSource(t.downloadUrl));
      if (!mounted) return;
      setState(() => _playingId = t.id);
      // Подписка одна: на каждом тапе слушатель не должен копиться.
      _completeSub?.cancel();
      _completeSub = _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playingId = null);
      });
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка превью: {p0}', {'p0': friendlyError(e)})),
          ),
        );
    }
  }

  Future<void> _addToQuest(MusicTrack t) async {
    final questId = widget.questId;
    if (questId == null) return;
    try {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Скачивание в квест...'))));
      final tmpDir = Directory.systemTemp.createTempSync('music_add_');
      final tmpFile = File(
        p.join(tmpDir.path, p.basename(t.downloadUrl.split('?').first)),
      );
      // download via http with auth
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token') ?? '';
      final uri = Uri.parse(t.downloadUrl);
      final req = http.Request('GET', uri);
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      final resp = await http.Client().send(req);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final bytes = await resp.stream.toBytes();
      await tmpFile.writeAsBytes(bytes);
      // copy to quest res/audio with uuid
      final ext = p.extension(t.downloadUrl.split('?').first).isEmpty
          ? '.mp3'
          : p.extension(t.downloadUrl.split('?').first);
      final newName = '${DateTime.now().millisecondsSinceEpoch}_${t.id}$ext';
      final destRelQuested = QuestPaths.resAudio(questId, newName);
      final destPath = await FileStorage.getFilePath(destRelQuested);
      final destRel = p.join('res/audio', newName);
      await Directory(p.dirname(destPath)).create(recursive: true);
      await tmpFile.copy(destPath);
      // update metadata with friendly name
      final qs = await QuestStore.defaultInstance();
      final metaPath = QuestPaths.metadata(questId);
      Map<String, dynamic> meta = {};
      try {
        meta = await qs.readJson(metaPath) ?? {};
      } catch (_) {}
      meta[newName] = {
        'name': '${t.performer} - ${t.title}',
        'folder': '/',
        'resourceId': t.id,
      };
      await qs.writeJson(metaPath, meta);
      // invalidate quest provider
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trf('Добавлено: {p0}', {'p0': t.title}))),
        );
        if (widget.pickerMode) Navigator.pop(context, destRel);
      }
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Ошибка добавления: {p0}', {'p0': friendlyError(e)}),
            ),
          ),
        );
    }
  }

  Future<void> _upload() async {
    // Без токена POST /music вернёт 401 — новичок узнавал об этом только
    // после выбора файла и заполненной формы.
    if (!await ensurePublishAccount(context)) return;
    if (!mounted) return;

    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac'],
    );
    if (res.isEmpty) return;
    final file = File(res.first.path!);
    final titleCtrl = TextEditingController(
      text: p.basenameWithoutExtension(file.path),
    );
    final performerCtrl = TextEditingController();
    final genreCtrl = TextEditingController(text: kMusicGenres.first);
    final licenseCtrl = TextEditingController(text: 'CC-BY');
    final descCtrl = TextEditingController();
    File? coverFile;
    String? coverName;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(tr('Загрузить трек')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(labelText: tr('Название *')),
                ),
                TextField(
                  controller: performerCtrl,
                  decoration: InputDecoration(labelText: tr('Исполнитель *')),
                ),
                TextField(
                  controller: genreCtrl,
                  decoration: InputDecoration(
                    labelText: tr('Жанр'),
                    hintText: kMusicGenres.join(', '),
                  ),
                ),
                TextField(
                  controller: licenseCtrl,
                  decoration: InputDecoration(labelText: tr('Лицензия *')),
                ),
                TextField(
                  controller: descCtrl,
                  decoration: InputDecoration(labelText: tr('Описание')),
                  maxLines: 3,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        coverName ?? tr('Обложка не выбрана'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final r = await FilePicker.pickFiles(
                          type: FileType.image,
                        );
                        if (r.isNotEmpty) {
                          coverFile = File(r.first.path!);
                          coverName = p.basename(coverFile!.path);
                          setS(() {});
                        }
                      },
                      child: Text(tr('Выбрать')),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Загрузить')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (titleCtrl.text.trim().isEmpty ||
        performerCtrl.text.trim().isEmpty ||
        licenseCtrl.text.trim().isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Заполните обязательные поля'))),
        );
      return;
    }
    setState(() {
      _isUploading = true;
      _uploadProgress = 0.1;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token') ?? '';
      final uri = Uri.parse('${AppConfig.apiUrl}/music');
      final req = http.MultipartRequest('POST', uri);
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.fields['title'] = titleCtrl.text.trim();
      req.fields['performer'] = performerCtrl.text.trim();
      req.fields['genre'] = genreCtrl.text.trim();
      req.fields['license'] = licenseCtrl.text.trim();
      req.fields['description'] = descCtrl.text.trim();
      req.files.add(await http.MultipartFile.fromPath('musicFile', file.path));
      if (coverFile != null)
        req.files.add(
          await http.MultipartFile.fromPath('cover', coverFile!.path),
        );
      setState(() => _uploadProgress = 0.3);
      final streamed = await req.send();
      setState(() => _uploadProgress = 0.7);
      final respStr = await streamed.stream.bytesToString();
      setState(() => _uploadProgress = 1.0);
      await Future.delayed(const Duration(milliseconds: 300));
      if (streamed.statusCode == 201) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('Отправлено на модерацию'))),
          );
        ref.invalidate(musicTracksProvider);
        ref.invalidate(filteredMusicTracksProvider);
      } else if (streamed.statusCode == 429) {
        throw Exception(
          tr('Слишком много загрузок. Подождите час (лимит 5/час).'),
        );
      } else if (streamed.statusCode == 409) {
        throw Exception(tr('Такой файл уже загружен.'));
      } else {
        throw Exception('HTTP ${streamed.statusCode}: $respStr');
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Ошибка загрузки: {p0}', {'p0': friendlyError(e)}),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracksAsync = ref.watch(filteredMusicTracksProvider);
    final genre = ref.watch(musicGenreProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickerMode ? tr('Библиотека музыки') : tr('Музыка')),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: tr('Поиск по названию, исполнителю...'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              ref.read(musicSearchProvider.notifier).state = '';
                            },
                          )
                        : null,
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) =>
                      ref.read(musicSearchProvider.notifier).state = v,
                  onSubmitted: (v) =>
                      ref.read(musicSearchProvider.notifier).state = v,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: kMusicGenres.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      if (i == 0) {
                        final sel = genre == null;
                        return FilterChip(
                          label: Text(tr('Все')),
                          selected: sel,
                          onSelected: (_) =>
                              ref.read(musicGenreProvider.notifier).state =
                                  null,
                        );
                      }
                      final g = kMusicGenres[i - 1];
                      final sel = genre == g;
                      return FilterChip(
                        label: Text(g),
                        selected: sel,
                        onSelected: (_) =>
                            ref.read(musicGenreProvider.notifier).state = sel
                            ? null
                            : g,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _isUploading ? null : _upload,
        icon: _isUploading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.upload),
        label: Text(tr('Загрузить')),
      ),
      body: AdaptiveContent(
        maxWidth: 1100,
        child: Column(
          children: [
            if (_isUploading)
              LinearProgressIndicator(
                value: _uploadProgress > 0 && _uploadProgress < 1
                    ? _uploadProgress
                    : null,
              ),
            Expanded(
              child: tracksAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: () =>
                            ref.invalidate(filteredMusicTracksProvider),
                        child: Text(tr('Повторить')),
                      ),
                    ],
                  ),
                ),
                data: (list) {
                  if (list.isEmpty)
                    return Center(child: Text(tr('Треков пока нет')));
                  return RefreshIndicator(
                    onRefresh: () async {
                      ref.invalidate(musicTracksProvider);
                      ref.invalidate(filteredMusicTracksProvider);
                    },
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (ctx, i) {
                        final t = list[i];
                        final isPlaying = _playingId == t.id;
                        return Material(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            leading: t.coverUrl != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      t.coverUrl!,
                                      width: 48,
                                      height: 48,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.music_note,
                                        size: 32,
                                      ),
                                    ),
                                  )
                                : Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(Icons.music_note),
                                  ),
                            title: Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${t.performer} • ${t.genre ?? t.genres.firstOrNull ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  trf('Лицензия: {p0}', {'p0': t.license}),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withOpacity(0.7),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    isPlaying
                                        ? Icons.stop_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                  onPressed: () => _preview(t),
                                ),
                                if (widget.questId != null)
                                  FilledButton.tonal(
                                    onPressed: () => _addToQuest(t),
                                    child: Text(tr('В квест')),
                                  )
                                else
                                  IconButton(
                                    icon: const Icon(Icons.info_outline),
                                    onPressed: () => showDialog(
                                      context: ctx,
                                      builder: (_) => AlertDialog(
                                        title: Text(t.title),
                                        content: SingleChildScrollView(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                trf('Исполнитель: {p0}', {
                                                  'p0': t.performer,
                                                }),
                                              ),
                                              Text(
                                                trf('Жанр: {p0}', {
                                                  'p0': t.genre ?? '',
                                                }),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(tr('Лицензия:')),
                                              Text(
                                                t.license,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              if (t.description != null) ...[
                                                const SizedBox(height: 8),
                                                Text(t.description!),
                                              ],
                                            ],
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: Text(tr('Закрыть')),
                                          ),
                                          FilledButton(
                                            onPressed: () {
                                              Navigator.pop(ctx);
                                              _preview(t);
                                            },
                                            child: Text(tr('Превью')),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            onTap: () => _preview(t),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
