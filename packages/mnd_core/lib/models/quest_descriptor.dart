import 'content_item.dart';

const String kScriptEngineModeNew = 'new';

String normalizeScriptEngineMode(String? rawMode) {
  // Legacy engine mode is fully removed; always normalize to the new engine.
  return kScriptEngineModeNew;
}

String? _stringOrNull(dynamic value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

/// Список непустых строк без повторов: `null`, одна строка и массив
/// приводятся к одной форме — так старые `config.json` читаются без ветвлений.
List<String> _stringList(dynamic value) {
  final source = value is List ? value : [value];
  final result = <String>[];
  for (final item in source) {
    final text = _stringOrNull(item);
    if (text != null && !result.contains(text)) result.add(text);
  }
  return result;
}

String _stringOrFallback(dynamic value, String fallback) {
  return _stringOrNull(value) ?? fallback;
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

/// Пресет кнопок по имени из `buttonStylePresets` (#159).
///
/// Квест мог прийти из архива или быть поправлен руками, поэтому одна битая
/// запись не имеет права ронять разбор config.json целиком.
ButtonStyleConfig? _findButtonPresetByName(
  Map<String, dynamic> json,
  String name,
) {
  final presets = json['buttonStylePresets'];
  if (presets is! List) return null;
  for (final preset in presets) {
    if (preset is! Map) continue;
    try {
      final config = ButtonStyleConfig.fromJson(
        Map<String, dynamic>.from(preset),
      );
      if (config.presetName?.trim() == name) return config;
    } catch (_) {}
  }
  return null;
}

class Quest {
  final String id;
  final String title;
  final String? imageUrl;
  final String? author;
  final String? description;
  final String? startNodeId;
  final String? password;
  final DateTime? created;
  /// Последнее изменение содержимого или настроек локального квеста.
  final DateTime? lastEditedAt;
  final DateTime? lastOpened;
  final String? version;
  final String? backgroundAssetId;
  final String? localPreviewPath;
  final List<String>? screenshotFiles;
  final bool dimBackground;
  final bool hideNodeTitles;

  /// Не показывать верхнюю панель игры (назад/сохранить/загрузить/громкость).
  /// Скрипт может вернуть её блоком `set_top_panel`.
  final bool hideTopPanel;

  /// Разрешить игроку вернуться на предыдущую ноду.
  final bool allowStepBack;
  final List<String> genres;
  final String defaultTextFit;
  final bool isReadOnly;
  final bool isMarketDownloaded;
  final String? marketQuestId;
  /// ID автора в базе, если квест пришёл из маркета.
  final String? authorId;
  /// Сохранённая серверная метка верификации (не используется для обхода
  /// онлайн-проверки безопасности, нужна для offline-диагностики).
  final bool authorIsVerified;
  /// Дата последнего обновления версии квеста на сервере.
  final DateTime? marketUpdatedAt;
  final String? marketVersion;
  final String? customFontFileName;
  final bool wrapButtonText;
  /// Имя пресета из `buttonStylePresets`, который играет роль оформления
  /// кнопок по умолчанию для всего квеста (#159).
  final String? defaultButtonPresetName;
  /// Тот же пресет, найденный в списке пресетов квеста. `null` — значит
  /// встроенный стеклянный вид: либо стиль не назначен, либо пресет удалили.
  final ButtonStyleConfig? defaultButtonStyle;
  /// Продолжать ли играть музыку (и звуки) при сворачивании приложения.
  /// По умолчанию — нет: сворачивание ставит аудио на паузу.
  final bool musicInBackground;
  final String nodeTransitionMode;
  final String scriptEngineMode;
  final bool isCorrupted;
  final String? loadError;
  final List<String> pluginDependencies;
  final bool allowOpenContent;
  /// Язык, на котором написан квест (код из реестра интерфейсных языков:
  /// `ru`, `en`, `ja`, `pt-BR`). `null` — автор не указал. Нужен, чтобы в
  /// маркете первыми показывать квесты на языке игрока.
  final String? language;

  /// Все поддерживаемые языки в порядке автора; первый — основной
  /// ([language]). Пустой список у старых квестов, где автор выбрал один
  /// язык или не выбрал вовсе.
  final List<String> languages;

  Quest({
    required this.id,
    required this.title,
    this.imageUrl,
    this.author,
    this.description,
    this.startNodeId,
    this.password,
    this.created,
    this.lastEditedAt,
    this.lastOpened,
    this.version,
    this.backgroundAssetId,
    this.localPreviewPath,
    this.screenshotFiles,
    this.dimBackground = true,
    this.hideNodeTitles = false,
    this.hideTopPanel = false,
    this.allowStepBack = false,
    this.genres = const [],
    this.defaultTextFit = 'scale',
    this.isReadOnly = false,
    this.isMarketDownloaded = false,
    this.marketQuestId,
    this.authorId,
    this.authorIsVerified = false,
    this.marketUpdatedAt,
    this.marketVersion,
    this.customFontFileName,
    this.wrapButtonText = true,
    this.defaultButtonPresetName,
    this.defaultButtonStyle,
    this.musicInBackground = false,
    this.nodeTransitionMode = 'none',
    this.scriptEngineMode = kScriptEngineModeNew,
    this.isCorrupted = false,
    this.loadError,
    this.pluginDependencies = const [],
    this.allowOpenContent = false,
    this.language,
    this.languages = const [],
  });

  factory Quest.fromJson(Map<String, dynamic> json) {
    final bool isDimmed = json['dimBackground'] as bool? ?? true;
    final bool isTitlesHidden = json['hideNodeTitles'] as bool? ?? false;
    final bool isTopPanelHidden = json['hideTopPanel'] as bool? ?? false;
    final bool allowStepBack = json['allowStepBack'] as bool? ?? false;
    final String textFit = json['defaultTextFit'] as String? ?? 'scale';
    final bool readOnly = json['isReadOnly'] as bool? ?? false;
    final bool isMarketDownloaded =
        json['isMarketDownloaded'] as bool? ??
        json['isFromMarket'] as bool? ??
        false;
    final String? marketQuestId = json['marketQuestId'] as String?;
    final bool buttonWrapText = json['wrapButtonText'] as bool? ?? true;
    final bool musicInBackground =
        json['musicInBackground'] as bool? ?? false;
    final String transitionMode =
        json['nodeTransitionMode'] as String? ?? 'none';
    final String scriptEngineMode = normalizeScriptEngineMode(
      json['scriptEngineMode']?.toString() ?? json['scriptEngine']?.toString(),
    );
    final pluginDeps =
        (json['pluginDependencies'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final bool allowOpenContent = json['allowOpenContent'] as bool? ?? false;
    final String? language = _stringOrNull(json['language']);
    // Старый `config.json` знает только один язык — список собираем из него,
    // чтобы редактор и публикация не различали две формы.
    final List<String> languages = _stringList(json['languages']);
    if (languages.isEmpty && language != null) languages.add(language);
    final String? defaultPresetName = _stringOrNull(
      json['defaultButtonPresetName'],
    );
    final ButtonStyleConfig? defaultPreset = defaultPresetName == null
        ? null
        : _findButtonPresetByName(json, defaultPresetName);

    List<String> loadedGenres = [];
    if (json['genres'] != null && json['genres'] is List) {
      loadedGenres = (json['genres'] as List).map((e) => e.toString()).toList();
    } else if (json['category'] != null) {
      loadedGenres.add(json['category'].toString());
    }

    return Quest(
      id: _stringOrFallback(json['id'], ''),
      title: _stringOrFallback(json['title'], 'Без названия'),
      imageUrl: _stringOrNull(json['imageUrl']),
      author: _stringOrNull(json['author']),
      description: _stringOrNull(json['description']),
      startNodeId: _stringOrNull(json['startNodeId']),
      password: _stringOrNull(json['password']),
      created: _parseDate(json['created']),
      lastEditedAt: _parseDate(
        json['lastEditedAt'] ??
            json['last_edited_at'] ??
            json['updatedAt'] ??
            json['updated_at'] ??
            json['updated'],
      ),
      lastOpened: _parseDate(json['lastOpened']),
      version: _stringOrNull(json['version']),
      backgroundAssetId: _stringOrNull(json['backgroundAssetId']),
      screenshotFiles: (json['screenshot_files'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      dimBackground: isDimmed,
      hideNodeTitles: isTitlesHidden,
      hideTopPanel: isTopPanelHidden,
      allowStepBack: allowStepBack,
      genres: loadedGenres,
      defaultTextFit: textFit,
      isReadOnly: readOnly,
      isMarketDownloaded: isMarketDownloaded,
      marketQuestId: marketQuestId,
      authorId: _stringOrNull(json['authorId'] ?? json['author_id']),
      authorIsVerified: json['authorIsVerified'] as bool? ??
          json['author_is_verified'] as bool? ??
          false,
      marketUpdatedAt: _parseDate(
        json['marketUpdatedAt'] ?? json['market_updated_at'],
      ),
      marketVersion: _stringOrNull(
        json['marketVersion'] ?? json['market_version'],
      ),
      customFontFileName: _stringOrNull(json['customFontFileName']),
      wrapButtonText: buttonWrapText,
      defaultButtonPresetName: defaultPresetName,
      defaultButtonStyle: defaultPreset,
      musicInBackground: musicInBackground,
      nodeTransitionMode: transitionMode,
      scriptEngineMode: scriptEngineMode,
      isCorrupted: json['isCorrupted'] as bool? ?? false,
      loadError: _stringOrNull(json['loadError']),
      pluginDependencies: pluginDeps,
      allowOpenContent: allowOpenContent,
      language: language,
      languages: languages,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'imageUrl': imageUrl,
    'author': author,
    'description': description,
    'startNodeId': startNodeId,
    'password': password,
    'created': created?.toIso8601String(),
    if (lastEditedAt != null)
      'lastEditedAt': lastEditedAt!.toIso8601String(),
    'lastOpened': lastOpened?.toIso8601String(),
    'version': version,
    'dimBackground': dimBackground,
    'hideNodeTitles': hideNodeTitles,
    'hideTopPanel': hideTopPanel,
    'allowStepBack': allowStepBack,
    'genres': genres,
    'defaultTextFit': defaultTextFit,
    'isReadOnly': isReadOnly,
    'isMarketDownloaded': isMarketDownloaded,
    'allowOpenContent': allowOpenContent,
    if (marketQuestId != null) 'marketQuestId': marketQuestId,
    if (authorId != null) 'authorId': authorId,
    'authorIsVerified': authorIsVerified,
    if (marketUpdatedAt != null)
      'marketUpdatedAt': marketUpdatedAt!.toIso8601String(),
    if (marketVersion != null) 'marketVersion': marketVersion,
    'wrapButtonText': wrapButtonText,
    if (defaultButtonPresetName != null)
      'defaultButtonPresetName': defaultButtonPresetName,
    'musicInBackground': musicInBackground,
    'nodeTransitionMode': nodeTransitionMode,
    'scriptEngineMode': scriptEngineMode,
    'pluginDependencies': pluginDependencies,
    'category': genres.isNotEmpty ? genres.first : null,
    if (language != null) 'language': language,
    if (languages.isNotEmpty) 'languages': languages,
    if (backgroundAssetId != null) 'backgroundAssetId': backgroundAssetId,
    if (screenshotFiles != null) 'screenshot_files': screenshotFiles,
    if (customFontFileName != null) 'customFontFileName': customFontFileName,
  };

  Quest copyWith({
    String? id,
    String? title,
    String? imageUrl,
    String? author,
    String? description,
    String? startNodeId,
    String? password,
    DateTime? created,
    DateTime? lastEditedAt,
    DateTime? lastOpened,
    String? version,
    String? backgroundAssetId,
    String? localPreviewPath,
    List<String>? screenshotFiles,
    bool? dimBackground,
    bool? hideNodeTitles,
    bool? hideTopPanel,
    bool? allowStepBack,
    List<String>? genres,
    String? defaultTextFit,
    bool? isReadOnly,
    bool? isMarketDownloaded,
    String? marketQuestId,
    String? authorId,
    bool? authorIsVerified,
    DateTime? marketUpdatedAt,
    String? marketVersion,
    String? customFontFileName,
    bool? wrapButtonText,
    String? defaultButtonPresetName,
    ButtonStyleConfig? defaultButtonStyle,
    bool? musicInBackground,
    String? nodeTransitionMode,
    String? scriptEngineMode,
    bool? isCorrupted,
    String? loadError,
    List<String>? pluginDependencies,
    bool? allowOpenContent,
    String? language,
    List<String>? languages,
  }) {
    return Quest(
      id: id ?? this.id,
      title: title ?? this.title,
      imageUrl: imageUrl ?? this.imageUrl,
      author: author ?? this.author,
      description: description ?? this.description,
      startNodeId: startNodeId ?? this.startNodeId,
      password: password ?? this.password,
      created: created ?? this.created,
      lastEditedAt: lastEditedAt ?? this.lastEditedAt,
      lastOpened: lastOpened ?? this.lastOpened,
      version: version ?? this.version,
      backgroundAssetId: backgroundAssetId ?? this.backgroundAssetId,
      localPreviewPath: localPreviewPath ?? this.localPreviewPath,
      screenshotFiles: screenshotFiles ?? this.screenshotFiles,
      dimBackground: dimBackground ?? this.dimBackground,
      hideNodeTitles: hideNodeTitles ?? this.hideNodeTitles,
      hideTopPanel: hideTopPanel ?? this.hideTopPanel,
      allowStepBack: allowStepBack ?? this.allowStepBack,
      genres: genres ?? this.genres,
      defaultTextFit: defaultTextFit ?? this.defaultTextFit,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      isMarketDownloaded: isMarketDownloaded ?? this.isMarketDownloaded,
      marketQuestId: marketQuestId ?? this.marketQuestId,
      authorId: authorId ?? this.authorId,
      authorIsVerified: authorIsVerified ?? this.authorIsVerified,
      marketUpdatedAt: marketUpdatedAt ?? this.marketUpdatedAt,
      marketVersion: marketVersion ?? this.marketVersion,
      customFontFileName: customFontFileName ?? this.customFontFileName,
      wrapButtonText: wrapButtonText ?? this.wrapButtonText,
      defaultButtonPresetName:
          defaultButtonPresetName ?? this.defaultButtonPresetName,
      defaultButtonStyle: defaultButtonStyle ?? this.defaultButtonStyle,
      musicInBackground: musicInBackground ?? this.musicInBackground,
      nodeTransitionMode: nodeTransitionMode ?? this.nodeTransitionMode,
      scriptEngineMode: scriptEngineMode ?? this.scriptEngineMode,
      isCorrupted: isCorrupted ?? this.isCorrupted,
      loadError: loadError ?? this.loadError,
      pluginDependencies: pluginDependencies ?? this.pluginDependencies,
      allowOpenContent: allowOpenContent ?? this.allowOpenContent,
      language: language ?? this.language,
      languages: languages ?? this.languages,
    );
  }
}
