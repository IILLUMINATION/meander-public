import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/services/export_service.dart';
import 'package:canvas_app/core/services/publish_upload.dart';
import 'package:mnd_player/utils/file_storage.dart';
import 'package:mnd_player/utils/quest_nodes_store.dart';
import 'package:canvas_app/features/quests/providers/quest_provider.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mnd_core/utils/quest_paths.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:canvas_app/core/utils/error_text.dart';

// ============================================================================
//  ПУБЛИКАЦИЯ КВЕСТА — Material 3 редизайн
// ============================================================================
//
//  UX-улучшения:
//   • Pre-publish dialog → bottom-sheet с drag handle (естественнее на мобиле).
//   • Прогресс-вид: чистая M3 круговая шкала + плавающий статус.
//   • Результат: M3 иконка-плашка + цветной title-bg + действия на любом исходе.
//   • Цвета — только через ColorScheme.
//   • Логика публикации (HTTP, оценка playtime) сохранена без правок.
//
// ============================================================================

enum PublishResult { success, failure, cancelled }

class QuestPublishScreen extends ConsumerStatefulWidget {
  final Quest quest;
  const QuestPublishScreen({super.key, required this.quest});

  @override
  ConsumerState<QuestPublishScreen> createState() => _QuestPublishScreenState();
}

class _QuestPublishScreenState extends ConsumerState<QuestPublishScreen> {
  String _status = tr('Подготовка...');
  double _progress = 0.0;
  bool _isComplete = false;

  bool _hasError = false;
  bool _isPendingReview = false;
  bool _isDemo = false;
  bool _isNsfw = false;
  bool _acceptedRules = false;

  String _resultTitle = '';
  String _resultMessage = '';

  Timer? _stallTimer;

  /// Клиент идущей загрузки: нужен, чтобы оборвать её, если человек нажал
  /// «Отменить» — без этого multipart улетал на сервер до конца.
  http.Client? _uploadClient;

  /// Момент, когда по соединению в последний раз шли байты.
  DateTime _lastByteAt = DateTime.now();
  bool _allBytesSent = false;

  /// Прервали загрузку сторожем — тогда показываем свою строку, а не сырое
  /// исключение транспорта.
  bool _abortedByStall = false;
  int _stallSeconds = 0;

  /// Лимиты паузы в передаваемых байтах и в ожидании ответа сервера: модерация
  /// идёт внутри того же запроса и обязана успеть (на проде это 600 с).
  static const Duration _uploadStallLimit = Duration(seconds: 60);
  static const Duration _serverWaitLimit = Duration(seconds: 180);

  /// Контекст открытого pre-publish bottom-sheet. Нужен, чтобы корректно
  /// закрыть лист при нажатии «крестика» в AppBar — иначе получался
  /// двойной pop / зависающий UI поверх Navigator.
  BuildContext? _prePublishSheetCtx;

  /// Чтобы не дёргать Navigator.pop экрана дважды (из обработчика sheet
  /// и из _onWillPop одновременно).
  bool _screenPopped = false;

  // Константы из старой версии — переименованы в lowerCamelCase.
  static const double _wordsPerSecond = 3.3;
  static const int _secondsPerImage = 5;
  static const int _secondsPerNodeInteraction = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showPrePublishSheet();
    });
  }

  @override
  void dispose() {
    _abortUpload();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  //  PRE-PUBLISH BOTTOM SHEET
  // ---------------------------------------------------------------------------

  Future<void> _showPrePublishSheet() async {
    final result = await showAdaptiveSheet<bool>(
      context: context,
      isScrollControlled: true,
      barrierDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        // Запоминаем контекст листа — нужен для корректного закрытия из
        // _onWillPop (когда юзер жмёт крестик до подтверждения публикации).
        _prePublishSheetCtx = ctx;
        bool isDemoLocal = _isDemo;
        bool isNsfwLocal = _isNsfw;
        bool accepted = _acceptedRules;
        return StatefulBuilder(
          builder: (context, setSheet) {
            final scheme = Theme.of(context).colorScheme;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  20 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.cloud_upload_rounded,
                            color: scheme.onPrimaryContainer,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            tr('Публикация квеста'),
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Warning banner
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            color: scheme.onTertiaryContainer,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              tr(
                                'Указывайте, если это демо. Если модератор обнаружит, что квест демо, но не отмечен — будет бан аккаунта.',
                              ),
                              style: TextStyle(
                                color: scheme.onTertiaryContainer,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Demo switch
                    SwitchListTile(
                      title: Text(
                        tr('Это демо-версия'),
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        tr('Недоделанный квест, нужны отзывы и тесты'),
                        style: TextStyle(fontSize: 12),
                      ),
                      value: isDemoLocal,
                      onChanged: (v) => setSheet(() => isDemoLocal = v),
                      contentPadding: EdgeInsets.zero,
                    ),

                    SwitchListTile(
                      title: Text(
                        tr('Контент 18+'),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.error,
                        ),
                      ),
                      subtitle: Text(
                        tr('Нецензурная лексика, жестокость, эротика'),
                        style: TextStyle(fontSize: 12),
                      ),
                      value: isNsfwLocal,
                      onChanged: (v) => setSheet(() => isNsfwLocal = v),
                      contentPadding: EdgeInsets.zero,
                      activeColor: scheme.error,
                      activeTrackColor: scheme.errorContainer,
                    ),

                    const SizedBox(height: 4),
                    Divider(color: scheme.outlineVariant),
                    const SizedBox(height: 8),

                    // Rules header
                    Row(
                      children: [
                        Icon(
                          Icons.gavel_rounded,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr('Правила публикации'),
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    _RuleBullet(
                      text: tr(
                        'Запрещены порнография, обнажёнка, сексуализация несовершеннолетних',
                      ),
                    ),
                    _RuleBullet(
                      text: tr(
                        'Запрещены пропаганда насилия, экстремизма, ненависти',
                      ),
                    ),
                    _RuleBullet(
                      text: tr(
                        'Запрещены доксинг, вредоносные ссылки, мошенничество',
                      ),
                    ),
                    _RuleBullet(
                      text: tr('Запрещены чужие авторские материалы без прав'),
                    ),

                    const SizedBox(height: 12),

                    CheckboxListTile(
                      value: accepted,
                      onChanged: (v) => setSheet(() => accepted = v ?? false),
                      title: Text(
                        tr('Я прочитал и согласен с правилами'),
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),

                    const SizedBox(height: 16),

                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(tr('Отмена')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: accepted
                                ? () {
                                    _isDemo = isDemoLocal;
                                    _isNsfw = isNsfwLocal;
                                    _acceptedRules = accepted;
                                    Navigator.pop(ctx, true);
                                  }
                                : null,
                            icon: const Icon(Icons.arrow_forward_rounded),
                            label: Text(tr('Продолжить')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    // Sheet закрыт — обнуляем ссылку.
    _prePublishSheetCtx = null;

    if (result != true) {
      // Пользователь отменил публикацию ещё до старта (либо нажал «Отмена»,
      // либо закрыл sheet через _onWillPop). Закрываем экран ровно один раз.
      if (mounted && !_screenPopped) {
        _screenPopped = true;
        Navigator.of(context).pop(PublishResult.cancelled);
      }
      return;
    }

    _runPublishProcess();
  }

  // ---------------------------------------------------------------------------
  //  ERROR MAPPING
  // ---------------------------------------------------------------------------

  String _mapErrorToFriendlyMessage(String error) {
    final e = error.toLowerCase();
    if (e.contains("file size exceeds limit")) {
      return tr(
        'Размер квеста превышает лимит сервера. Сейчас лимит для обычных аккаунтов: 100 МБ, для верифицированных: 500 МБ.',
      );
    }
    if (e.contains("413") || e.contains("file too large")) {
      return tr(
        'Сервер отклонил загрузку: файл слишком большой (HTTP 413). Проверь лимиты на backend/nginx.',
      );
    }
    if (e.contains("connection reset by peer") ||
        e.contains("socketexception")) {
      return tr(
        'Соединение сброшено сервером во время загрузки. Обычно это лимит размера на прокси (nginx) или таймаут upload.',
      );
    }
    if (e.contains("rate limit")) {
      return tr('Вы публикуете слишком часто. Подождите пару часов.');
    }
    if (e.contains("cover image rejected")) {
      return tr('Обложка не прошла проверку (возможно, NSFW или насилие).');
    }
    if (e.contains("screenshot rejected")) {
      return tr('Один из скриншотов содержит недопустимый контент.');
    }
    if (e.contains("internal game image rejected")) {
      return tr('Внутри игры найдена запрещённая картинка.');
    }
    if (e.contains("text content rejected")) {
      return tr('Текст или описание квеста нарушают правила сообщества.');
    }
    if (e.contains("script rejected")) {
      return tr('В скриптах найден подозрительный или вредоносный код.');
    }
    if (e.contains("duplicate content")) {
      return tr('Этот квест уже был опубликован (дубликат).');
    }
    if (e.contains("unauthorized") || e.contains("authenticated")) {
      return tr('Ошибка авторизации. Перезайдите в аккаунт.');
    }
    return trf('Ошибка публикации: {p0}', {'p0': friendlyError(error)});
  }

  // ---------------------------------------------------------------------------
  //  CANCEL / EXIT
  // ---------------------------------------------------------------------------

  Future<void> _onWillPop() async {
    // 1. Если процесс уже завершён — закрываем с актуальным результатом.
    if (_isComplete) {
      if (!_screenPopped && mounted) {
        _screenPopped = true;
        Navigator.of(
          context,
        ).pop(_hasError ? PublishResult.failure : PublishResult.success);
      }
      return;
    }

    // 2. Если открыт pre-publish bottom sheet (юзер ещё ничего не отправил) —
    //    просто закрываем его. Хендлер `_showPrePublishSheet` после await
    //    сам закроет экран с PublishResult.cancelled. Без отдельного диалога
    //    подтверждения: сам факт «не нажал Продолжить» уже = отмена.
    final sheetCtx = _prePublishSheetCtx;
    if (sheetCtx != null) {
      _prePublishSheetCtx = null;
      if (Navigator.canPop(sheetCtx)) {
        Navigator.pop(sheetCtx, false);
      }
      return;
    }

    // 3. Идёт загрузка/публикация — спрашиваем подтверждение.
    final shouldPop = await showAppDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(tr('Отменить публикацию?')),
          content: Text(tr('Процесс будет прерван. Вы уверены?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Остаться')),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              child: Text(tr('Отменить')),
            ),
          ],
        );
      },
    );

    if (shouldPop == true && mounted && !_screenPopped) {
      _screenPopped = true;
      _abortUpload();
      Navigator.of(context).pop(PublishResult.cancelled);
    }
  }

  // ---------------------------------------------------------------------------
  //  ПРОГРЕСС И СТОРОЖ ЗАГРУЗКИ
  // ---------------------------------------------------------------------------

  /// Сторож паузы в передаче байтов.
  ///
  /// `request.send()` не имеет таймаута: оборванная посреди загрузки висящая
  /// гостевая сессия держала экран публикации на «99%» ровно столько, сколько
  /// жил сокет. Прогресс теперь считается от реально отправленных байт, и если
  /// Прогресс отправки: реальные байты тела, а не шаги таймера.
  void _onSendProgress(int sent, int total) {
    _lastByteAt = DateTime.now();
    final fraction = sentFraction(sent, total);
    if (fraction == null || !mounted) return;
    if (fraction >= 1.0) _allBytesSent = true;
    setState(() {
      _progress = 0.2 + 0.7 * fraction;
      _status = _allBytesSent
          ? tr('Сервер проверяет и сохраняет пакет...')
          : trf('Загрузка пакета: {p0}%', {
              'p0': (fraction * 100).toStringAsFixed(0),
            });
    });
  }

  /// Сторож паузы в передаче байтов.
  ///
  /// `client.send()` не имеет таймаута: оборванная посреди загрузки висящая
  /// сессия держала экран публикации на «99%» ровно столько, сколько жил
  /// сокет. Прогресс считается от реально отправленных байт, и если они
  /// перестали идти — загрузку обрываем и объясняем это.
  void _armStallWatchdog(http.Client client) {
    _stallTimer?.cancel();
    _lastByteAt = DateTime.now();
    _allBytesSent = false;
    _abortedByStall = false;
    _stallSeconds = 0;
    _stallTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      final limit = _allBytesSent ? _serverWaitLimit : _uploadStallLimit;
      if (DateTime.now().difference(_lastByteAt) < limit) return;
      _abortedByStall = true;
      _stallSeconds = limit.inSeconds;
      timer.cancel();
      debugPrint(
        '⏱ [Publish] соединение молчит ${limit.inSeconds} с — обрываем загрузку',
      );
      client.close();
    });
  }

  /// Обрыв идущей загрузки: «Отменить», ошибка и закрытие экрана не должны
  /// оставлять multipart-тело долетать до сервера.
  void _abortUpload() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _uploadClient?.close();
    _uploadClient = null;
  }

  /// Роль автора задаёт лимит пакета. `null` — не удалось узнать: тогда отсев не
  /// делаем (худший случай — сервер проверит после загрузки), чтобы сбой сети
  /// не запретил публикацию верифицированному автору.
  Future<bool?> _lookupAuthorVerification(String userId) async {
    try {
      final profile = await ref
          .read(apiServiceProvider)
          .get('profiles/$userId')
          .timeout(const Duration(seconds: 5));
      if (profile is! Map) return null;
      final value = profile['is_verified'];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        return normalized == 'true' || normalized == '1';
      }
      return null;
    } catch (e) {
      debugPrint('Publish limits: роль автора недоступна ($e)');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  //  PUBLISH PIPELINE
  // ---------------------------------------------------------------------------

  Future<void> _runPublishProcess() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    final token = prefs.getString('jwt_token');

    if (userId == null || token == null) {
      if (!mounted) return;
      setState(() {
        _isComplete = true;
        _hasError = true;
        _resultTitle = tr('Ошибка');
        _resultMessage = _mapErrorToFriendlyMessage("User not authenticated");
      });
      return;
    }

    try {
      if (!mounted) return;

      setState(() {
        _status = tr('Сборка пакета квеста...');
        _progress = 0.1;
      });

      final estimatedPlaytimeSeconds = await _calculateEstimatedPlaytime(
        widget.quest.id,
      );
      final estimatedPlaytime = (estimatedPlaytimeSeconds / 60).ceil();
      int nodeCount = 0;
      final nodesData = await QuestNodesStore.read(widget.quest.id);
      nodeCount = (nodesData['nodes'] as List<dynamic>? ?? []).length;

      final mndData = await ExportService.createMndFile(
        widget.quest.id,
        // Каталог и веб-плеер читают legacy nodes.json.
        nodesFormat: QuestArchiveNodesFormat.legacy,
      );
      final tempDir = await getTemporaryDirectory();
      final mndFile = File('${tempDir.path}/${widget.quest.id}.mnd');
      await mndFile.writeAsBytes(mndData);
      final mndSizeBytes = await mndFile.length();
      final mndSizeMb = (mndSizeBytes / (1024 * 1024)).toStringAsFixed(2);
      debugPrint('📦 [Publish] Quest package size: $mndSizeMb MB');

      // Отсев до загрузки: размер пакета известен сейчас, а сервер узнаёт о
      // превышении лимита только когда все байты уже доехали.
      final isVerifiedAuthor = await _lookupAuthorVerification(userId);
      if (isVerifiedAuthor != null) {
        final oversize = preflightSizeRejection(mndSizeBytes, isVerifiedAuthor);
        if (oversize != null) {
          debugPrint('⛔ [Publish] preflight: $oversize');
          if (await mndFile.exists()) await mndFile.delete();
          if (!mounted) return;
          setState(() {
            _isComplete = true;
            _hasError = true;
            _resultTitle = tr('Пакет больше лимита');
            _resultMessage = oversize;
          });
          return;
        }
      }

      if (!mounted) return;
      setState(() {
        _status = tr('Отправка файлов на сервер...');
        _progress = 0.2;
      });

      var uri = Uri.parse('${AppConfig.apiUrl}/quests');
      final request = ProgressMultipartRequest('POST', uri, _onSendProgress);

      request.headers['Authorization'] = 'Bearer $token';
      request.fields['id'] = widget.quest.id;
      request.fields['title'] = widget.quest.title;
      request.fields['description'] = widget.quest.description ?? '';
      request.fields['version'] = widget.quest.version ?? '1.0.0';
      request.fields['node_count'] = nodeCount.toString();
      request.fields['estimated_playtime'] = estimatedPlaytime.toString();
      request.fields['is_demo'] = _isDemo.toString();
      request.fields['is_nsfw'] = _isNsfw.toString();

      // Отправляем жанры как JSON-строку.
      request.fields['genres'] = jsonEncode(widget.quest.genres);
      // Язык квеста сервер использует для порядка выдачи в маркете. Поле
      // шлём всегда: пустая строка — «автор снял метку», а отсутствие поля
      // сервер прочитал бы как «старый клиент» и оставил бы прежний язык.
      request.fields['language'] = widget.quest.language ?? '';
      // Для обратной совместимости отправляем первый жанр как category.
      if (widget.quest.genres.isNotEmpty) {
        request.fields['category'] = widget.quest.genres.first;
      }

      request.files.add(
        await http.MultipartFile.fromPath('questFile', mndFile.path),
      );

      if (widget.quest.localPreviewPath != null) {
        final coverFile = File(widget.quest.localPreviewPath!);
        if (await coverFile.exists()) {
          request.files.add(
            await http.MultipartFile.fromPath('cover', coverFile.path),
          );
        }
      }

      if (widget.quest.screenshotFiles != null) {
        for (var fileName in widget.quest.screenshotFiles!) {
          final screenPath = await FileStorage.getFilePath(
            QuestPaths.resScreenshot(widget.quest.id, fileName),
          );
          final screenFile = File(screenPath);
          if (await screenFile.exists()) {
            request.files.add(
              await http.MultipartFile.fromPath('screenshots', screenFile.path),
            );
          }
        }
      }

      final client = http.Client();
      _uploadClient = client;
      _armStallWatchdog(client);

      final http.Response response;
      try {
        response = await http.Response.fromStream(await client.send(request));
      } finally {
        _abortUpload();
      }

      if (await mndFile.exists()) await mndFile.delete();
      if (!mounted) return;

      if (response.statusCode == 201 || response.statusCode == 200) {
        String serverStatus = 'published';
        try {
          final respData = jsonDecode(response.body);
          if (respData['status'] != null) {
            serverStatus = respData['status'];
          }
        } catch (_) {}

        setState(() {
          _progress = 1.0;
          _isComplete = true;
          _hasError = false;

          if (serverStatus == 'published') {
            _isPendingReview = false;
            _resultTitle = tr('Успешно опубликовано');
            _resultMessage = tr('Ваш квест теперь доступен в магазине.');
          } else {
            _isPendingReview = true;
            _resultTitle = tr('Отправлено на проверку');
            _resultMessage = tr(
              'Ваш квест отправлен модераторам. Это может занять некоторое время.',
            );
          }
        });
      } else {
        String errorDetails = response.body;
        String? byCode;
        try {
          final jsonErr = jsonDecode(response.body);
          if (jsonErr is Map) {
            final typed = describePublishFailure(
              jsonErr.cast<String, dynamic>(),
              response.statusCode,
            );
            byCode = typed;
            if (jsonErr['error'] != null) {
              errorDetails = jsonErr['error'].toString();
            }
          }
        } catch (_) {}

        // Готовый текст сервера не прогоняем через старый разбор по подстрокам:
        // он уже понятен, а вторичная обработка превращала его в
        // «Ошибка публикации: …».
        setState(() {
          _isComplete = true;
          _hasError = true;
          _resultTitle = tr('Ошибка');
          _resultMessage = byCode ?? _mapErrorToFriendlyMessage(errorDetails);
        });
        return;
      }
    } catch (e) {
      _abortUpload();
      debugPrint('Publish Error: $e');
      if (!mounted) return;
      final message = !_abortedByStall
          ? _mapErrorToFriendlyMessage(
              e.toString().replaceAll('Exception: ', ''),
            )
          : _allBytesSent
          ? trf(
              'Пакет ушёл на сервер, но ответ не пришёл за {p0} с. Публикация могла и не записаться: проверь «Мои квесты» и, если её там нет, опубликуй заново.',
              {'p0': _stallSeconds},
            )
          : trf(
              'Загрузка встала: {p0} секунд по соединению не прошло ни одного байта. Публикацию не записали, квест остался у тебя — попробуй опубликовать заново.',
              {'p0': _stallSeconds},
            );
      setState(() {
        _isComplete = true;
        _hasError = true;
        _resultTitle = tr('Ошибка');
        _resultMessage = message;
      });
    }
  }

  // ---------------------------------------------------------------------------
  //  PLAYTIME ESTIMATION
  // ---------------------------------------------------------------------------

  Future<int> _getAudioDurationInSeconds(String relativePath) async {
    try {
      if (!(Platform.isAndroid || Platform.isIOS)) {
        return 0;
      }
      final fullPath = await FileStorage.getFilePath(relativePath);
      final file = File(fullPath);
      if (!await file.exists()) return 0;
      final player = ja.AudioPlayer();
      final duration = await player.setFilePath(fullPath);
      await player.dispose();
      return duration?.inSeconds ?? 0;
    } catch (e) {
      return 0;
    }
  }

  Future<int> _calculateEstimatedPlaytime(String questId) async {
    double totalSeconds = 0.0;
    try {
      final nodesData = await QuestNodesStore.read(questId);
      final nodesList = nodesData['nodes'] as List<dynamic>? ?? [];

      for (final nodeJson in nodesList) {
        totalSeconds += _secondsPerNodeInteraction;
        final content = nodeJson['content'] as Map<String, dynamic>? ?? {};
        final items = content['items'] as List<dynamic>? ?? [];
        for (final item in items) {
          if (item is! Map<String, dynamic>) continue;
          final type = item['type'] as String?;
          switch (type) {
            case 'text':
              final text = item['text'] as String? ?? '';
              final wordCount = text.split(RegExp(r'\s+')).length;
              totalSeconds += wordCount / _wordsPerSecond;
              break;
            case 'image':
              totalSeconds += _secondsPerImage;
              break;
            case 'timer':
            case 'delay':
              final seconds = int.tryParse(item['text'] as String? ?? '0') ?? 0;
              totalSeconds += seconds;
              break;
            case 'audio':
              final resourcePath = item['resourcePath'] as String?;
              if (resourcePath != null) {
                totalSeconds += await _getAudioDurationInSeconds(
                  QuestPaths.questFile(questId, resourcePath),
                );
              }
              break;
          }
        }
      }
    } catch (e) {
      // ignore
    }
    return totalSeconds.round();
  }

  // ---------------------------------------------------------------------------
  //  BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _onWillPop();
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _onWillPop,
            tooltip: tr('Закрыть'),
          ),
        ),
        body: AdaptiveContent(
          maxWidth: 760,
          child: SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _isComplete
                      ? _buildResultView()
                      : _buildProgressView(),
                ),
              ),
            ), // SingleChildScrollView
          ),
        ),
      ),
    );
  }

  Widget _buildProgressView() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('progress'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 130,
          height: 130,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(
                value: _progress > 0 ? _progress : null,
                strokeWidth: 8,
                strokeCap: StrokeCap.round,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
              ),
              if (_progress > 0)
                Center(
                  child: Text(
                    '${(_progress * 100).toInt()}%',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          tr('Публикация'),
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: Text(
            _status,
            key: ValueKey(_status),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResultView() {
    final scheme = Theme.of(context).colorScheme;

    late final IconData icon;
    late final Color iconBg;
    late final Color iconFg;

    if (_hasError) {
      icon = Icons.error_outline_rounded;
      iconBg = scheme.errorContainer;
      iconFg = scheme.onErrorContainer;
    } else if (_isPendingReview) {
      icon = Icons.hourglass_top_rounded;
      iconBg = scheme.tertiaryContainer;
      iconFg = scheme.onTertiaryContainer;
    } else {
      icon = Icons.check_circle_outline_rounded;
      iconBg = scheme.primaryContainer;
      iconFg = scheme.onPrimaryContainer;
    }

    return Column(
      key: const ValueKey('result'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
          child: Icon(icon, color: iconFg, size: 58),
        ),
        const SizedBox(height: 24),
        Text(
          _resultTitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: scheme.onSurface,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _resultMessage,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 14.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: () => Navigator.of(
              context,
            ).pop(_hasError ? PublishResult.failure : PublishResult.success),
            icon: const Icon(Icons.check_rounded),
            label: Text(
              tr('Закрыть'),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
//  RULE BULLET (используется в pre-publish sheet)
// ============================================================================

class _RuleBullet extends StatelessWidget {
  final String text;
  const _RuleBullet({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
