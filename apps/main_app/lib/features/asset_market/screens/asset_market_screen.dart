import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/features/hub/widgets/preset_market.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_store.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canvas_app/shared/dialogs/account_gate.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import '../providers/asset_provider.dart';

class AssetMarketScreen extends ConsumerStatefulWidget {
  final String? questId;
  final String? initialKind; // filter for picker mode
  final bool pickerMode;
  const AssetMarketScreen({
    super.key,
    this.questId,
    this.initialKind,
    this.pickerMode = false,
  });

  @override
  ConsumerState<AssetMarketScreen> createState() => _AssetMarketScreenState();
}

class _AssetMarketScreenState extends ConsumerState<AssetMarketScreen> {
  final _searchCtrl = TextEditingController();
  final _player = AudioPlayer();
  StreamSubscription? _completeSub;
  String? _playingId;
  bool _isUploading = false;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialKind != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(assetKindProvider.notifier).state = widget.initialKind;
      });
    }
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _preview(MarketAsset a) async {
    if (a.kind == 'sfx' || a.kind == 'music') {
      try {
        if (_playingId == a.id) {
          await _player.stop();
          if (!mounted) return;
          setState(() => _playingId = null);
          return;
        }
        await _player.stop();
        await _player.play(UrlSource(a.downloadUrl));
        if (!mounted) return;
        setState(() => _playingId = a.id);
        // Подписка одна: на каждом тапе слушатель не должен копиться.
        _completeSub?.cancel();
        _completeSub = _player.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _playingId = null);
        });
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            ),
          );
      }
    } else {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(a.title),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (a.coverUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      a.coverUrl!,
                      errorBuilder: (_, __, ___) => const Icon(Icons.image),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(trf('Тип: {p0}', {'p0': assetKindLabel(a.kind)})),
                Text(trf('Лицензия: {p0}', {'p0': licenseLabel(a.license)})),
                if (a.authorName != null && a.authorName!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () {
                      Navigator.pop(context);
                      if (a.authorId != null)
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProfileScreen(userId: a.authorId!),
                          ),
                        );
                    },
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_rounded,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: CosmeticNameText(
                            name: a.authorName!,
                            def: cosmeticById(a.authorNameStyle),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 12,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                        if (a.authorIsVerified)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.verified_rounded,
                              size: 14,
                              color: Color(0xFF1976D2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (a.description != null) ...[
                  const SizedBox(height: 8),
                  Text(a.description!),
                ],
                if (a.kind == 'button_preset') ...[
                  const SizedBox(height: 8),
                  RemotePresetPreview(asset: a, height: 130),
                ],
                if (a.kind == 'font') ...[
                  const SizedBox(height: 12),
                  _FontPreviewBox(asset: a),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Закрыть')),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _addToQuest(MarketAsset a) async {
    final questId = widget.questId;
    if (questId == null) return;
    // Пресеты кнопок: ZIP → распаковка + мерж в config.json.
    if (a.kind == 'button_preset') {
      final ok = await addPresetToQuestFlow(
        context: context,
        asset: a,
        questId: questId,
      );
      // Пресеты не возвращаются как путь файла — просто закрываем пикер если он был.
      if (ok != null && widget.pickerMode && mounted)
        Navigator.pop(context, ok);
      return;
    }
    try {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Скачивание...'))));
      final tmpDir = Directory.systemTemp.createTempSync('asset_add_');
      final tmpFile = File(
        p.join(tmpDir.path, p.basename(a.downloadUrl.split('?').first)),
      );
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token') ?? '';
      final uri = Uri.parse(a.downloadUrl);
      final req = http.Request('GET', uri);
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      final resp = await http.Client().send(req);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final bytes = await resp.stream.toBytes();
      await tmpFile.writeAsBytes(bytes);

      final qs = await QuestStore.defaultInstance();
      String destRel = '';
      if (a.kind == 'background' || a.kind == 'image') {
        final ext = p.extension(a.downloadUrl.split('?').first).isEmpty
            ? '.png'
            : p.extension(a.downloadUrl.split('?').first);
        final newName = '${DateTime.now().millisecondsSinceEpoch}_${a.id}$ext';
        destRel = p.join('res/images', newName);
        final destPath = await FileStorage.getFilePath(
          QuestPaths.questFile(questId, destRel),
        );
        await Directory(p.dirname(destPath)).create(recursive: true);
        await tmpFile.copy(destPath);
        // metadata
        final metaPath = QuestPaths.metadata(questId);
        Map<String, dynamic> meta = {};
        try {
          meta = await qs.readJson(metaPath) ?? {};
        } catch (_) {}
        meta[newName] = {'name': a.title, 'folder': '/', 'resourceId': a.id};
        await qs.writeJson(metaPath, meta);
      } else if (a.kind == 'sfx') {
        final ext = p.extension(a.downloadUrl.split('?').first).isEmpty
            ? '.mp3'
            : p.extension(a.downloadUrl.split('?').first);
        final newName = '${DateTime.now().millisecondsSinceEpoch}_${a.id}$ext';
        destRel = p.join('res/audio', newName);
        final destPath = await FileStorage.getFilePath(
          QuestPaths.questFile(questId, destRel),
        );
        await Directory(p.dirname(destPath)).create(recursive: true);
        await tmpFile.copy(destPath);
        final metaPath = QuestPaths.metadata(questId);
        Map<String, dynamic> meta = {};
        try {
          meta = await qs.readJson(metaPath) ?? {};
        } catch (_) {}
        meta[newName] = {'name': a.title, 'folder': '/', 'resourceId': a.id};
        await qs.writeJson(metaPath, meta);
      } else if (a.kind == 'font') {
        final ext = p.extension(a.downloadUrl.split('?').first).isEmpty
            ? '.ttf'
            : p.extension(a.downloadUrl.split('?').first);
        final newName = '${a.title.replaceAll(' ', '_')}$ext';
        destRel = p.join('res/fonts', newName);
        final destPath = await FileStorage.getFilePath(
          QuestPaths.questFile(questId, destRel),
        );
        await Directory(p.dirname(destPath)).create(recursive: true);
        await tmpFile.copy(destPath);
      } else {
        final newName = p.basename(a.downloadUrl.split('?').first);
        destRel = p.join('res', newName);
        final destPath = await FileStorage.getFilePath(
          QuestPaths.questFile(questId, destRel),
        );
        await Directory(p.dirname(destPath)).create(recursive: true);
        await tmpFile.copy(destPath);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trf('Добавлено: {p0}', {'p0': a.title}))),
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
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
          ),
        );
    }
  }

  Future<void> _upload() async {
    // Сюда ведут «Ресурсы» квеста — экран доступен и без аккаунта, а
    // публикация без него уткнулась бы в 401 уже после выбора файла.
    if (!await ensurePublishAccount(context)) return;
    if (!mounted) return;

    final kind = ref.read(assetKindProvider) ?? 'image';
    List<String> allowed;
    switch (kind) {
      case 'button_preset':
        allowed = ['json'];
        break;
      case 'font':
        allowed = ['ttf', 'otf', 'woff', 'woff2'];
        break;
      case 'sfx':
        allowed = ['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac'];
        break;
      case 'background':
        allowed = ['jpg', 'jpeg', 'png', 'webp'];
        break;
      default:
        allowed = [
          'jpg',
          'jpeg',
          'png',
          'webp',
          'mp3',
          'wav',
          'json',
          'ttf',
          'otf',
        ];
    }
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowed,
    );
    if (res.isEmpty) return;
    final file = File(res.first.path!);
    final titleCtrl = TextEditingController(
      text: p.basenameWithoutExtension(file.path),
    );
    final genreCtrl = TextEditingController();
    final licenseCtrl = TextEditingController(text: 'CC-BY');
    final descCtrl = TextEditingController();
    File? coverFile;
    String? coverName;
    if (!mounted) return;
    final ok = await showAdaptiveSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final scheme = Theme.of(ctx).colorScheme;
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              20 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr('Новый ресурс'),
                      style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      trf('Загрузить {p0}', {
                        'p0': kAssetKindLabels[kind] ?? kind,
                      }),
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleCtrl,
                      decoration: InputDecoration(
                        labelText: tr('Название *'),
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: genreCtrl,
                      decoration: InputDecoration(
                        labelText: tr('Жанр/тег'),
                        hintText: trf('например {p0}', {'p0': kind}),
                        border: const OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: licenseCtrl,
                      decoration: InputDecoration(
                        labelText: tr('Лицензия *'),
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descCtrl,
                      decoration: InputDecoration(
                        labelText: tr('Описание'),
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                      maxLines: 3,
                    ),
                    if (kind != 'background' && kind != 'image') ...[
                      const SizedBox(height: 12),
                      Material(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Icon(
                            Icons.image_outlined,
                            color: scheme.primary,
                          ),
                          title: Text(
                            coverName ?? tr('Превью не выбрано'),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(tr('Необязательно • JPG, PNG, WEBP')),
                          trailing: TextButton(
                            onPressed: () async {
                              final r = await FilePicker.pickFiles(
                                type: FileType.image,
                              );
                              if (r.isNotEmpty && r.first.path != null) {
                                coverFile = File(r.first.path!);
                                coverName = p.basename(coverFile!.path);
                                setS(() {});
                              }
                            },
                            child: Text(tr('Выбрать')),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(tr('Отмена')),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => Navigator.pop(ctx, true),
                            icon: const Icon(
                              Icons.cloud_upload_rounded,
                              size: 18,
                            ),
                            label: Text(tr('Загрузить')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (ok != true) return;
    if (titleCtrl.text.trim().isEmpty || licenseCtrl.text.trim().isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Заполните обязательные поля'))),
        );
      return;
    }
    setState(() => _isUploading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token') ?? '';
      final uri = Uri.parse('${AppConfig.apiUrl}/assets');
      final req = http.MultipartRequest('POST', uri);
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.fields['kind'] = kind;
      req.fields['title'] = titleCtrl.text.trim();
      req.fields['genre'] = genreCtrl.text.trim();
      req.fields['license'] = licenseCtrl.text.trim();
      req.fields['description'] = descCtrl.text.trim();
      req.files.add(await http.MultipartFile.fromPath('assetFile', file.path));
      if (coverFile != null)
        req.files.add(
          await http.MultipartFile.fromPath('cover', coverFile!.path),
        );
      if (mounted) setState(() => _uploadProgress = 0.3);
      final streamed = await req.send();
      if (mounted) setState(() => _uploadProgress = 0.7);
      final respStr = await streamed.stream.bytesToString();
      if (mounted) setState(() => _uploadProgress = 1.0);
      await Future.delayed(const Duration(milliseconds: 300));
      if (streamed.statusCode == 201) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('Отправлено на модерацию'))),
          );
        ref.invalidate(assetListProvider);
        ref.invalidate(filteredAssetProvider);
      } else if (streamed.statusCode == 429)
        throw Exception(tr('Лимит 5/час'));
      else if (streamed.statusCode == 409)
        throw Exception(tr('Дубликат файла'));
      else
        throw Exception('HTTP ${streamed.statusCode}: $respStr');
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
  Widget build(BuildContext context) {
    final assetsAsync = ref.watch(filteredAssetProvider);
    final kind = ref.watch(assetKindProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickerMode ? tr('Маркет ассетов') : tr('Маркет')),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: tr('Поиск...'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              ref.read(assetSearchProvider.notifier).state = '';
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
                      ref.read(assetSearchProvider.notifier).state = v,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: kAssetKinds.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      if (i == 0) {
                        final sel = kind == null;
                        return FilterChip(
                          label: Text(tr('Все')),
                          selected: sel,
                          onSelected: (_) =>
                              ref.read(assetKindProvider.notifier).state = null,
                        );
                      }
                      final k = kAssetKinds[i - 1];
                      final sel = kind == k;
                      return FilterChip(
                        label: Text(kAssetKindLabels[k] ?? k),
                        selected: sel,
                        onSelected: (_) =>
                            ref.read(assetKindProvider.notifier).state = sel
                            ? null
                            : k,
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
      body: Column(
        children: [
          if (_isUploading)
            LinearProgressIndicator(
              value: _uploadProgress > 0 && _uploadProgress < 1
                  ? _uploadProgress
                  : null,
            ),
          Expanded(
            child: assetsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
                    FilledButton(
                      onPressed: () => ref.invalidate(filteredAssetProvider),
                      child: Text(tr('Повторить')),
                    ),
                  ],
                ),
              ),
              data: (list) {
                if (list.isEmpty)
                  return Center(child: Text(tr('Ассетов пока нет')));
                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(assetListProvider);
                  },
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                    // Ширина карточки, а не их число: на ПК каталог
                    // ассетов оставался двухколоночной лентой, растянутой
                    // на треть монитора.
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 280,
                          childAspectRatio: 0.85,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                    itemCount: list.length,
                    itemBuilder: (ctx, i) {
                      final a = list[i];
                      final isPlaying = _playingId == a.id;
                      return Material(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _preview(a),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: a.kind == 'button_preset'
                                    ? RemotePresetPreview(asset: a)
                                    : a.kind == 'font'
                                    ? _FontGridPreview(asset: a)
                                    : Builder(
                                        builder: (_) {
                                          final preview =
                                              a.coverUrl ??
                                              ((a.kind == 'background' ||
                                                      a.kind == 'image')
                                                  ? a.downloadUrl
                                                  : null);
                                          if (preview != null)
                                            return Image.network(
                                              preview,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  _KindIcon(kind: a.kind),
                                            );
                                          return _KindIcon(kind: a.kind);
                                        },
                                      ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      a.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Text(
                                      '${assetKindLabel(a.kind)} • ${assetGenreDisplay(a.genre, a.kind)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                        fontSize: 11,
                                      ),
                                    ),
                                    if (a.authorName != null &&
                                        a.authorName!.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: InkWell(
                                          onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ProfileScreen(
                                                userId: a.authorId!,
                                              ),
                                            ),
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .secondaryContainer
                                                  .withOpacity(0.7),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.person_rounded,
                                                  size: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSecondaryContainer,
                                                ),
                                                const SizedBox(width: 4),
                                                Flexible(
                                                  child: CosmeticNameText(
                                                    name: a.authorName!,
                                                    def: cosmeticById(
                                                      a.authorNameStyle,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSecondaryContainer,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                if (a.authorIsVerified)
                                                  const Padding(
                                                    padding: EdgeInsets.only(
                                                      left: 4,
                                                    ),
                                                    child: Icon(
                                                      Icons.verified_rounded,
                                                      size: 12,
                                                      color: Color(0xFF1976D2),
                                                    ),
                                                  ),
                                                const SizedBox(width: 2),
                                                Icon(
                                                  Icons.chevron_right_rounded,
                                                  size: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSecondaryContainer
                                                      .withOpacity(0.6),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            trf('Лиц: {p0}', {
                                              'p0': licenseLabel(a.license),
                                            }),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant
                                                  .withOpacity(0.7),
                                            ),
                                          ),
                                        ),
                                        if (a.kind == 'sfx' ||
                                            a.kind == 'music')
                                          IconButton(
                                            icon: Icon(
                                              isPlaying
                                                  ? Icons.stop_rounded
                                                  : Icons.play_arrow_rounded,
                                              size: 20,
                                            ),
                                            onPressed: () => _preview(a),
                                            visualDensity:
                                                VisualDensity.compact,
                                            padding: EdgeInsets.zero,
                                          )
                                        else
                                          const SizedBox.shrink(),
                                      ],
                                    ),
                                    if (widget.questId != null)
                                      SizedBox(
                                        width: double.infinity,
                                        child: FilledButton.tonal(
                                          onPressed: () => _addToQuest(a),
                                          child: Text(
                                            tr('В квест'),
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
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
    );
  }
}

class _KindIcon extends StatelessWidget {
  final String kind;
  const _KindIcon({required this.kind});
  @override
  Widget build(BuildContext context) {
    IconData icon;
    switch (kind) {
      case 'button_preset':
        icon = Icons.smart_button_rounded;
        break;
      case 'background':
        icon = Icons.wallpaper_rounded;
        break;
      case 'sfx':
        icon = Icons.music_note_rounded;
        break;
      case 'font':
        icon = Icons.text_fields_rounded;
        break;
      default:
        icon = Icons.image_rounded;
    }
    return Container(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Center(
        child: Icon(
          icon,
          size: 32,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _FontPreviewBox extends StatefulWidget {
  final MarketAsset asset;
  const _FontPreviewBox({required this.asset});
  @override
  State<_FontPreviewBox> createState() => _FontPreviewBoxState();
}

class _FontPreviewBoxState extends State<_FontPreviewBox> {
  String? _family;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final family = 'market_font_${widget.asset.id}';
    try {
      final tmpDir = await getTemporaryDirectory();
      final file = File(
        p.join(
          tmpDir.path,
          'font_preview_${widget.asset.id}${p.extension(widget.asset.downloadUrl.split('?').first)}',
        ),
      );
      if (!await file.exists()) {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('jwt_token') ?? '';
        final req = http.Request('GET', Uri.parse(widget.asset.downloadUrl));
        if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
        final resp = await http.Client().send(req);
        if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
        await file.writeAsBytes(await resp.stream.toBytes());
      }
      final bytes = await file.readAsBytes();
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      if (mounted)
        setState(() {
          _family = family;
          _loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString();
          _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    if (_error != null)
      return Text(
        tr('Ошибка загрузки шрифта'),
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
      );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Съешь ещё этих мягких французских булок'),
            style: TextStyle(fontFamily: _family, fontSize: 18),
          ),
          const SizedBox(height: 6),
          Text(
            '0123456789 ABC abc',
            style: TextStyle(
              fontFamily: _family,
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FontGridPreview extends StatefulWidget {
  final MarketAsset asset;
  const _FontGridPreview({required this.asset});
  @override
  State<_FontGridPreview> createState() => _FontGridPreviewState();
}

class _FontGridPreviewState extends State<_FontGridPreview> {
  String? _family;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final family = 'market_font_grid_${widget.asset.id}';
    try {
      final tmpDir = await getTemporaryDirectory();
      final ext = p.extension(widget.asset.downloadUrl.split('?').first);
      final file = File(
        p.join(tmpDir.path, 'font_grid_${widget.asset.id}$ext'),
      );
      if (!await file.exists()) {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('jwt_token') ?? '';
        final req = http.Request('GET', Uri.parse(widget.asset.downloadUrl));
        if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
        final resp = await http.Client().send(req);
        if (resp.statusCode != 200) return;
        await file.writeAsBytes(await resp.stream.toBytes());
      }
      final bytes = await file.readAsBytes();
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      if (mounted)
        setState(() {
          _family = family;
          _done = true;
        });
    } catch (_) {
      if (mounted) setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_family != null) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        padding: const EdgeInsets.all(10),
        child: Center(
          child: Text(
            tr('Аа Бб Вв'),
            style: TextStyle(
              fontFamily: _family,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return Container(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Center(
        child: _done
            ? Icon(
                Icons.text_fields_rounded,
                size: 28,
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              )
            : const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
  }
}
