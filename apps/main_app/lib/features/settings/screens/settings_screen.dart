import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/net/blind_tunnel.dart';
import 'package:canvas_app/core/services/relay_registry.dart';
import 'package:canvas_app/core/l10n/l10n_provider.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/services/onboarding_service.dart';
import 'package:canvas_app/features/editor/workspace/script_editor_mode.dart';
import 'package:canvas_app/core/services/session_service.dart';
import 'package:canvas_app/features/app/screens/about_screen.dart';
import 'package:canvas_app/features/app/screens/policy_screen.dart';
import 'package:canvas_app/features/app/screens/tutorial_screen.dart';
import 'package:canvas_app/features/guides/screens/guides_screen.dart';
import 'package:canvas_app/features/guides/widgets/guide_prompt.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:canvas_app/features/plugins/screens/plugin_manager_screen.dart';
import 'package:canvas_app/features/app/screens/update_screen.dart';
import 'package:canvas_app/features/messages/screens/chat_privacy_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/quests/screens/my_quests_screen.dart';
import 'package:canvas_app/features/resources/services/resource_prefs.dart';
import 'package:canvas_app/features/settings/providers/notifications_settings_provider.dart';
import 'package:canvas_app/features/settings/screens/theme_settings_screen.dart';
import 'package:canvas_app/features/settings/widgets/interface_language_dialog.dart';
import 'package:canvas_app/features/settings/widgets/refresh_rate_card.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:canvas_app/core/services/server_registry.dart';
import 'package:canvas_app/features/shell/screens/admin_screen.dart';
import 'package:canvas_app/features/shell/screens/menu_screen.dart';

// ============================================================================
//  НАСТРОЙКИ — Material You / Material 3 редизайн
// ============================================================================

import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _currentUserId;
  bool _tabsEnabled = true;
  bool _autoOpenTab = false;

  /// Какой редактор скриптов открывать: классический или канвас.
  ScriptEditorMode _scriptEditorMode = ScriptEditorModeStore.instance.mode;

  /// Библиотека ресурсов открывается с корня, а не там, где её закрыли.
  bool _resourcesOpenAtRoot = ResourcesPrefs.instance.openAtRoot;
  final _serverUrlController = TextEditingController();
  String? _serverUrlError;

  /// Серверы для секции «Подключение»: URL → пинг в мс
  /// (`null` — не отвечен, ещё не проверен).
  List<String> _serverList = [];
  Map<String, int?> _serverPings = {};
  bool _serverProbing = false;

  /// Пользователь ещё не просил проверку: пустой пинг не означает отказ, и
  /// секция не должна ходить в сеть сама по себе при открытии.
  bool _serverProbed = false;

  final _relayController = TextEditingController();
  String? _relayError;

  /// Ретрансляторы и их статус: `true` — TCP-коннект проходит.
  List<String> _relayList = [];
  Map<String, bool?> _relayStatuses = {};

  /// Удаление аккаунта уже запланировано — дата, когда строка уйдёт.
  DateTime? _deletionScheduledAt;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _loadConnection();
  }

  /// Адресная книга: серверы и ретрансляторы. Без сетевых проб — они идут
  /// только по кнопке, иначе открытие настроек ждёт таймаутов.
  Future<void> _loadConnection() async {
    await ServerRegistry.instance.ensureLoaded();
    await RelayRegistry.instance.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _serverList = ServerRegistry.instance.allUrls;
      _relayList = RelayRegistry.instance.all;
    });
  }

  /// Пинги серверов и TCP-статусы ретрансляторов.
  Future<void> _probeConnection() async {
    setState(() => _serverProbing = true);
    final results = await Future.wait([
      ServerRegistry.instance.probeAll(),
      RelayRegistry.instance.probeAll(),
    ]);
    if (!mounted) return;
    setState(() {
      _serverPings = results[0] as Map<String, int?>;
      _relayStatuses = results[1] as Map<String, bool>;
      _serverProbing = false;
      _serverProbed = true;
    });
  }

  /// Добавить свой сервер. Некорректный адрес не сохраняется; живость
  /// проверяем сразу и показываем пинг.
  Future<void> _saveServerUrl() async {
    final raw = _serverUrlController.text.trim();
    if (raw.isEmpty) {
      setState(() => _serverUrlError = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Поле пустое — зеркало не добавлено'))),
      );
      return;
    }

    final normalized = ServerRegistry.normalizeForPreview(raw);
    if (normalized == null) {
      setState(() => _serverUrlError = tr('Некорректный адрес сервера'));
      return;
    }

    await ServerRegistry.instance.addCustomUrl(normalized);
    final ping = await ServerRegistry.instance.probeUrl(normalized);
    if (!mounted) return;
    setState(() {
      _serverUrlError = ping == null ? tr('Сервер не отвечает') : null;
      _serverUrlController.text = '';
      _serverList = ServerRegistry.instance.allUrls;
      _serverPings[normalized] = ping;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('Зеркало добавлено'))));
  }

  Future<void> _removeServer(String url) async {
    await ServerRegistry.instance.removeCustomUrl(url);
    if (!mounted) return;
    setState(() {
      _serverList = ServerRegistry.instance.allUrls;
      _serverPings.remove(url);
    });
  }

  /// Выбрать сервер. Переключение на свой сервер отменяет ретранслятор:
  /// он прокладывает путь только к оригиналу.
  Future<void> _selectServer(String url) async {
    await ServerRegistry.instance.setActiveUrl(url);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('Подключение установлено'))));
  }

  /// Добавить свой ретранслятор (`host:port`).
  Future<void> _saveRelay() async {
    final raw = _relayController.text.trim();
    if (raw.isEmpty) {
      setState(() => _relayError = null);
      return;
    }
    final normalized = await RelayRegistry.instance.addCustom(raw);
    if (!mounted) return;
    if (normalized == null) {
      setState(() => _relayError = tr('Некорректный адрес ретранслятора'));
      return;
    }
    final ok = await RelayRegistry.instance.probe(normalized);
    if (!mounted) return;
    setState(() {
      _relayError = null;
      _relayController.text = '';
      _relayList = RelayRegistry.instance.all;
      _relayStatuses[normalized] = ok;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('Ретранслятор добавлен'))));
  }

  Future<void> _removeRelay(String endpoint) async {
    await RelayRegistry.instance.removeCustom(endpoint);
    if (!mounted) return;
    setState(() {
      _relayList = RelayRegistry.instance.all;
      _relayStatuses.remove(endpoint);
    });
  }

  Future<void> _toggleRelay(String endpoint, bool value) async {
    await RelayRegistry.instance.setEnabled(endpoint, value);
    if (!mounted) return;
    setState(() {});
  }

  /// Текущий путь к API человеческим языком.
  String _pathDescription() {
    if (BlindTunnel.enabled) {
      return trf('Сейчас: через ретранслятор {p0}', {
        'p0': BlindTunnel.endpoint ?? '',
      });
    }
    return tr('Сейчас: прямое соединение');
  }

  /// Проверить путь целиком: прямой, затем ретрансляторы. Прокси-зеркал в
  /// этом выборе нет.
  Future<void> _checkConnection() async {
    setState(() => _serverProbing = true);
    final ok = await ServerRegistry.instance.ensureReachable();
    if (!mounted) return;
    setState(() => _serverProbing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (BlindTunnel.enabled
                    ? trf('Соединение через ретранслятор {p0}', {
                        'p0': BlindTunnel.endpoint ?? '',
                      })
                    : tr('Прямое соединение работает'))
              : tr('Все зеркала недоступны'),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _relayController.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    await ScriptEditorModeStore.instance.ensureLoaded();
    await ResourcesPrefs.instance.ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _currentUserId = prefs.getString('user_id');
        _tabsEnabled = prefs.getBool('editor_tabs_enabled') ?? true;
        _autoOpenTab = prefs.getBool('editor_auto_open_tab') ?? false;
        _scriptEditorMode = ScriptEditorModeStore.instance.mode;
        _resourcesOpenAtRoot = ResourcesPrefs.instance.openAtRoot;
      });
    }
    _syncTimezone();
    _loadDeletionState();
  }

  /// Просрочка ли, запланировано ли удаление — знает только сервер. Экран это
  /// читает, чтобы показать «отменить» вместо «удалить».
  Future<void> _loadDeletionState() async {
    if (_currentUserId == null) return;
    try {
      final data = await ref.read(apiServiceProvider).get('auth/account');
      if (!mounted) return;
      final scheduledAt = (data is Map && data['deletion_scheduled_at'] != null)
          ? DateTime.tryParse(data['deletion_scheduled_at'].toString())
          : null;
      setState(() => _deletionScheduledAt = scheduledAt);
    } catch (_) {
      // На старом бэкенде ручка 404 — молча остаётся обычная кнопка.
    }
  }

  Future<void> _syncTimezone() async {
    if (_currentUserId == null) return;
    // Контейнер берётся до первого await: POST живёт дольше экрана, а `ref` на
    // снятом State бросает — и бросок ловит нижний catch, так что профиль
    // остаётся с прошлой таймзоной и молча.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSync = prefs.getString('tz_last_sync');
      final today = DateTime.now().toIso8601String().substring(0, 10);
      if (lastSync == today) return;

      final offset = DateTime.now().timeZoneOffset.inMinutes;
      await container
          .read(apiServiceProvider)
          .post('profiles/me', body: {'timezone_offset': offset});
      await prefs.setString('tz_last_sync', today);
      container.invalidate(userProfileProvider(_currentUserId!));
    } catch (_) {
      // Фоновая синхронизация при открытии настроек: у человека нет запроса,
      // на который можно отвечать, а снэкбар про часовой пояс — шум.
    }
  }

  Future<void> _toggleQuietHours(bool current) async {
    if (_currentUserId == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container
          .read(apiServiceProvider)
          .post('profiles/me', body: {'quiet_hours_enabled': !current});
      // Переключатель живёт на userProfileProvider: без перезагрузки он
      // возвращался в прежнее положение, даже когда сервер уже всё принял.
      container.invalidate(userProfileProvider(_currentUserId!));
    } catch (e) {
      // Раньше здесь был заглушённый catch без единого слова человеку: без
      // сети или с просроченной сессией тап по «Не беспокоить ночью» не давал
      // ни изменения, ни ответа — жест повторяли в надежде, что «не с первого
      // раза».
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trf('Не удалось изменить: {p0}', {'p0': friendlyError(e)}),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Выйти из аккаунта?')),
        content: Text(tr('Вы уверены, что хотите выйти?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            child: Text(tr('Выйти')),
          ),
        ],
      ),
    );

    if (confirm == true && _currentUserId != null && mounted) {
      await endSession(context: context);

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => MenuScreen()),
          (route) => false,
        );
      }
    }
  }

  /// Удаление аккаунта. Требование App Store 5.1.1(v): если приложение
  /// позволяет создать аккаунт, удалить его надо тоже прямо в приложении.
  /// Бэкенд снимает строку profiles — всё остальное уходит каскадом по FK.
  Future<void> _handleDeleteAccount() async {
    if (_currentUserId == null) return;

    var acknowledged = false;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(tr('Удалить аккаунт?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'Аккаунт, профиль, сохранения, переписки, публикации и статистика будут удалены безвозвратно.\n\nКвесты других авторов, которые вы купили или скачали, останутся на устройстве.',
                ),
              ),
              CheckboxListTile(
                value: acknowledged,
                onChanged: (v) =>
                    setDialogState(() => acknowledged = v ?? false),
                title: Text(tr('Понимаю, что это необратимо')),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton.tonal(
              onPressed: acknowledged ? () => Navigator.pop(ctx, true) : null,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
                foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
              ),
              child: Text(tr('Удалить навсегда')),
            ),
          ],
        ),
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final data = await ref
          .read(apiServiceProvider)
          .delete('auth/account', body: {'acknowledged': true});
      final scheduledAt = data is Map
          ? DateTime.tryParse('${data['deletion_scheduled_at']}')
          : null;
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Удаление запланировано')),
          content: Text(
            scheduledAt == null
                ? tr(
                    'Аккаунт будет удалён в ближайшие дни. Если передумаете — войдите и отмените удаление в этих же настройках.',
                  )
                : trf(
                    'Аккаунт будет удалён {p0}. Если передумаете — вернитесь в приложение, войдите и отмените удаление здесь же.',
                    {'p0': _formatDeletionDate(scheduledAt)},
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Понятно')),
            ),
          ],
        ),
      );
      if (!mounted) return;
      await endSession(context: context, notifyServer: false);
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => MenuScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Не удалось удалить аккаунт: {p0}', {'p0': friendlyError(e)}),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  static String _formatDeletionDate(DateTime at) {
    final t = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year}, ${two(t.hour)}:${two(t.minute)}';
  }

  /// Отмена плана на удаление: пока grace-срок не истёк, строка profiles цела.
  Future<void> _handleCancelDeletion() async {
    try {
      await ref.read(apiServiceProvider).post('auth/account/restore');
      if (!mounted) return;
      setState(() => _deletionScheduledAt = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Удаление отменено, аккаунт снова обычный.')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trf('Не удалось отменить: {p0}', {'p0': friendlyError(e)}),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _copyProfileId() async {
    if (_currentUserId == null) return;
    await Clipboard.setData(ClipboardData(text: _currentUserId!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('ID скопирован')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // Методы тура временно не используются — секция «Помощь» скрыта.
  // Оставлены здесь для лёгкого включения обратно после доработки фичи.
  // ignore: unused_element
  Future<void> _openQuestCreationTutorial() async {
    // Запускаем интерактивный тур и переходим в библиотеку —
    // именно там подсветится кнопка «Создать квест».
    ref.read(tutorialControllerProvider.notifier).start();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => MyQuestsScreen(isRoot: true)),
      (route) => route.isFirst,
    );
  }

  // ignore: unused_element
  Future<void> _resetQuestCreationTutorial() async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Сбросить обучение?')),
        content: Text(
          tr(
            'Обучение по созданию квеста будет показано снова при следующем нажатии на «Создать квест».',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Сбросить')),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await OnboardingService.resetQuestCreationTutorial();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Обучение сброшено')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Плашку раздела человек закрывает навсегда: без этого пункта тот, кто
  /// промахнулся по крестику, объяснение уже не увидит.
  Future<void> _restoreSectionHints() async {
    await SectionHintService.reset();
    GuidePrompt.resetSession();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Подсказки вернутся при следующем входе в разделы')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showDebugUpdateDialog(BuildContext context) {
    final changelog = [
      '• Новый дизайн окна обновления',
      '• Исправлен pinch-to-zoom на канвасе',
      '• Исправлено выделение текста в редакторе',
      '• Плеер квестов вынесен в отдельный модуль mnd_player',
      '• Добавлен template_quest_app для сборки standalone квестов',
      '• Сохранения через mnd_core SaveStore',
    ].join('\n');

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UpdateScreen(
          version: '99.0.0',
          changelog: changelog,
          downloadUrl: '',
          isCritical: false,
        ),
      ),
    );
  }

  Future<void> _editName() async {
    if (_currentUserId == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final profileAsync = ref.read(userProfileProvider(_currentUserId!));
    final currentName = profileAsync.maybeWhen(
      data: (p) => p.fullName,
      orElse: () => '',
    );
    final controller = TextEditingController(text: currentName);
    final newName = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Изменить имя')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('Новое имя')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == currentName) return;
    try {
      await container
          .read(apiServiceProvider)
          .post('profiles/me', body: {'full_name': newName});
      // Диалог и POST — минимум два кадра; экран за это время закрывают.
      // Через container, иначе бросок ловит нижний catch и уже сохранённое имя
      // выглядит несделанным: «Ошибка: …» при принявшем запрос сервере.
      container.invalidate(userProfileProvider(_currentUserId!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Имя обновлено')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// @адрес: короткая ссылка вместо uuid. Формат проверяем здесь же, чтобы
  /// не гонять запрос из-за «ab»; занятость знает только сервер.
  Future<void> _editUsername() async {
    if (_currentUserId == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final profileAsync = ref.read(userProfileProvider(_currentUserId!));
    final current = profileAsync.maybeWhen(
      data: (p) => p.username,
      orElse: () => null,
    );
    final controller = TextEditingController(text: current ?? '');
    final entered = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Юзернейм')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(
            prefixText: '@',
            hintText: 'meander',
            helperText: tr('Латинские буквы, цифры и _, от 3 до 32 символов'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (entered == null) return;
    final username = entered.replaceFirst(RegExp(r'^@+'), '').toLowerCase();
    if (username == (current ?? '')) return;
    if (username.isNotEmpty &&
        !RegExp(r'^[a-z][a-z0-9_]{2,31}$').hasMatch(username)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Латинские буквы, цифры и _, от 3 до 32 символов'),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    try {
      await container
          .read(apiServiceProvider)
          .post('profiles/me', body: {'username': username});
      container.invalidate(userProfileProvider(_currentUserId!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              username.isEmpty ? tr('Юзернейм убран') : tr('Юзернейм обновлён'),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _toggleNsfw(bool current) async {
    if (_currentUserId == null) return;
    final container = ProviderScope.containerOf(context, listen: false);

    if (!current) {
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Внимание')),
          content: Text(
            tr(
              'Контент 18+ может содержать нецензурную лексику, жестокость и материалы для взрослых.\n\nПодтвердите, что вам исполнилось 18 лет.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: Text(tr('Мне есть 18 лет')),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    try {
      await container
          .read(apiServiceProvider)
          .post('profiles/me', body: {'show_nsfw': !current});
      container.invalidate(userProfileProvider(_currentUserId!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              !current ? tr('Контент 18+ включен') : tr('Контент 18+ скрыт'),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _editBio() async {
    if (_currentUserId == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final profileAsync = ref.read(userProfileProvider(_currentUserId!));
    final currentBio = profileAsync.maybeWhen(
      data: (p) => p.bio ?? '',
      orElse: () => '',
    );
    final controller = TextEditingController(text: currentBio);
    final newBio = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('О себе')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: 280,
          decoration: InputDecoration(
            hintText: tr('Расскажите о себе…'),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (newBio == null || newBio == currentBio) return;
    try {
      await container
          .read(apiServiceProvider)
          .post('profiles/me', body: {'bio': newBio});
      container.invalidate(userProfileProvider(_currentUserId!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Описание обновлено')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trf('Ошибка: {p0}', {'p0': friendlyError(e)})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showRedeemCodeDialog() async {
    final controller = TextEditingController();
    final result = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Ввести код')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr('Введите промокод'),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('Активировать')),
          ),
        ],
      ),
    );

    final code = (result ?? '').trim().toUpperCase();
    if (code.isEmpty || _currentUserId == null) return;

    try {
      final message = await redeemPromoCode(
        ref: ref,
        userId: _currentUserId!,
        code: code,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              serverErrorMessage(
                e,
                fallback: tr('Не удалось активировать код'),
              ),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Выбор языка интерфейса.
  ///
  /// Язык применяется на месте: `L10n` меняет строки, провайдер перерисовывает
  /// этот экран, а остальные экраны подписаны на смену языка и перестраиваются
  /// сами. Навигация и несохранённая работа в редакторе не теряются.
  /// Диалог делает и выбор, и импорт своих переводов — см.
  /// `InterfaceLanguageDialog`.
  Future<void> _pickInterfaceLanguage() async {
    await showAppDialog<void>(
      context: context,
      builder: (_) => InterfaceLanguageDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final language = ref.watch(appLanguageProvider);
    final isLoggedIn = _currentUserId != null;
    final isAdmin = isLoggedIn
        ? ref
              .watch(userProfileProvider(_currentUserId!))
              .maybeWhen(data: (p) => p.role == 'admin', orElse: () => false)
        : false;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                SliverAppBar.large(
                  title: Text(tr('Настройки')),
                  // Прозрачная шапка пропускала заголовки секций сквозь
                  // «Настройки»: строка «Помощь» рисовалась прямо по нему.
                  backgroundColor: scheme.surface,
                  surfaceTintColor: Colors.transparent,
                  scrolledUnderElevation: 0,
                ),

                if (isLoggedIn) ...[
                  _SectionHeader(
                    title: tr('Профиль'),
                    icon: Icons.person_rounded,
                  ),
                  SliverToBoxAdapter(
                    child: Consumer(
                      builder: (context, ref, _) {
                        final profileAsync = ref.watch(
                          userProfileProvider(_currentUserId!),
                        );
                        final name = profileAsync.maybeWhen(
                          data: (p) => p.fullName,
                          orElse: () => null,
                        );
                        final username = profileAsync.maybeWhen(
                          data: (p) => p.username,
                          orElse: () => null,
                        );
                        final bio = profileAsync.maybeWhen(
                          data: (p) =>
                              (p.bio == null || p.bio!.isEmpty) ? null : p.bio,
                          orElse: () => null,
                        );
                        final bool showNsfw = profileAsync.maybeWhen(
                          data: (p) => p.showNsfw,
                          orElse: () => false,
                        );

                        return _SettingsGroup(
                          tiles: [
                            _SettingsTile(
                              icon: Icons.badge_outlined,
                              title: tr('Редактировать имя'),
                              subtitle: name,
                              onTap: _editName,
                            ),
                            _SettingsTile(
                              icon: Icons.alternate_email_rounded,
                              title: tr('Юзернейм'),
                              subtitle: username == null
                                  ? tr('Не задан')
                                  : '@$username',
                              onTap: _editUsername,
                            ),
                            _SettingsTile(
                              icon: Icons.description_outlined,
                              title: tr('Редактировать био'),
                              subtitle: bio ?? tr('Не задано'),
                              onTap: _editBio,
                            ),
                            SwitchListTile(
                              secondary: _SettingsSwitchIcon(
                                icon: showNsfw
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                iconColor: showNsfw
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                              title: Text(tr('Контент 18+')),
                              subtitle: Text(
                                showNsfw ? tr('Включен') : tr('Скрыт из ленты'),
                              ),
                              value: showNsfw,
                              onChanged: (_) => _toggleNsfw(showNsfw),
                            ),
                            _SettingsTile(
                              icon: Icons.mail_outline_rounded,
                              title: tr('Личные сообщения'),
                              subtitle: tr(
                                'Кто может писать, стаж, блокировки',
                              ),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatPrivacyScreen(),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],

                // Тема, плагины и поведение редактора — настройки устройства,
                // аккаунта они не требуют.
                _SectionHeader(
                  title: tr('Внешний вид'),
                  icon: Icons.palette_rounded,
                ),
                SliverToBoxAdapter(
                  child: _SettingsGroup(
                    tiles: [
                      _SettingsTile(
                        icon: Icons.color_lens_outlined,
                        title: tr('Тема оформления'),
                        subtitle: tr('Цвет, фон, пресеты'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ThemeSettingsScreen(),
                          ),
                        ),
                      ),
                      _SettingsTile(
                        icon: Icons.translate_outlined,
                        title: tr('Язык интерфейса'),
                        // Самоназвание языка: «English» видно и по-русски, и
                        // по-английски — иначе выбор языка на незнакомом
                        // интерфейсе превращается в угадайку.
                        subtitle: language.nativeName,
                        onTap: _pickInterfaceLanguage,
                      ),
                      _SettingsTile(
                        icon: Icons.extension_outlined,
                        title: tr('Плагины'),
                        subtitle: tr('Управление расширениями'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PluginManagerScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                SliverToBoxAdapter(child: RefreshRateCard()),

                _SectionHeader(
                  title: tr('Редактор'),
                  icon: Icons.edit_note_rounded,
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          SwitchListTile(
                            secondary: const _SettingsSwitchIcon(
                              icon: Icons.tab_rounded,
                            ),
                            title: Text(tr('Вкладки')),
                            subtitle: Text(
                              tr('Панель вкладок для открытых документов'),
                            ),
                            value: _tabsEnabled,
                            onChanged: (v) async {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setBool('editor_tabs_enabled', v);
                              if (mounted) setState(() => _tabsEnabled = v);
                            },
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            indent: 60,
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                          SwitchListTile(
                            secondary: const _SettingsSwitchIcon(
                              icon: Icons.open_in_new_rounded,
                            ),
                            title: Text(tr('Авто-открывать вкладку')),
                            subtitle: Text(
                              tr('Новый документ сразу в новой вкладке'),
                            ),
                            value: _autoOpenTab,
                            onChanged: (v) async {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setBool('editor_auto_open_tab', v);
                              if (mounted) setState(() => _autoOpenTab = v);
                            },
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            indent: 60,
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                          _ScriptEditorModeTile(
                            value: _scriptEditorMode,
                            onChanged: (mode) async {
                              await ScriptEditorModeStore.instance.set(mode);
                              if (mounted) {
                                setState(() => _scriptEditorMode = mode);
                              }
                            },
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            indent: 60,
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                          SwitchListTile(
                            secondary: const _SettingsSwitchIcon(
                              icon: Icons.folder_open_rounded,
                            ),
                            title: Text(tr('Библиотека ресурсов с корня')),
                            subtitle: Text(
                              tr(
                                'Открывать на корневой папке, а не там, где библиотеку закрыли',
                              ),
                            ),
                            value: _resourcesOpenAtRoot,
                            onChanged: (v) async {
                              await ResourcesPrefs.instance.setOpenAtRoot(v);
                              if (mounted) {
                                setState(() => _resourcesOpenAtRoot = v);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Material(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => launchUrl(
                          Uri.parse(
                            'https://github.com/IILLUMINATION/meander-public',
                          ),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                Icons.code_rounded,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      tr('Meander — open-source'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      tr(
                                        'Исходный код открыт: github.com/IILLUMINATION/meander-public — бэкенд, конструктор квестов, плеер',
                                      ),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                Icons.open_in_new_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                _SectionHeader(
                  title: tr('Подключение'),
                  icon: Icons.language_rounded,
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr('Серверы и ретрансляторы'),
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  trf(
                                    'Оригинальный сервер один — {p0}. Если провайдер его блокирует, доступ дают ретрансляторы: они передают трафик, не расшифровывая его, поэтому не видят ни токен, ни переписку.',
                                    {'p0': AppConfig.siteHost},
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  tr(
                                    'Свой сервер — это отдельный бэкенд: у него своя база и свой вход. Сессия основного сервера на него не передаётся, а сервер видит всё, что вы на нём размещаете.',
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _pathDescription(),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: BlindTunnel.enabled
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: TextField(
                              controller: _serverUrlController,
                              decoration: InputDecoration(
                                hintText: 'https://example.com',
                                errorText: _serverUrlError,
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              keyboardType: TextInputType.url,
                              onSubmitted: (_) => _saveServerUrl(),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                FilledButton.tonal(
                                  onPressed: _serverProbing
                                      ? null
                                      : _saveServerUrl,
                                  child: Text(tr('Добавить')),
                                ),
                                TextButton(
                                  onPressed: _serverProbing
                                      ? null
                                      : _probeConnection,
                                  child: Text(tr('Тест пинга')),
                                ),
                                TextButton(
                                  onPressed: _serverProbing
                                      ? null
                                      : _checkConnection,
                                  child: Text(tr('Проверить соединение')),
                                ),
                              ],
                            ),
                          ),
                          if (_serverProbing)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: LinearProgressIndicator(minHeight: 2),
                            ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: _serverList.length,
                            itemBuilder: (context, index) {
                              final url = _serverList[index];
                              final ping = _serverPings[url];
                              final isActive =
                                  url == ServerRegistry.instance.activeUrl;
                              final isCustom = url != AppConfig.vpsApiBaseUrl;
                              return ListTile(
                                dense: true,
                                onTap: () => _selectServer(url),
                                leading: Icon(
                                  isActive
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: isActive
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                title: Text(url),
                                subtitle: Text(
                                  isActive
                                      ? tr('Активный сервер')
                                      : (isCustom
                                            ? tr('Ваш сервер')
                                            : tr('Основной сервер')),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_serverProbing)
                                      const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    else if (ping != null)
                                      Text(
                                        '$ping ms',
                                        style: TextStyle(
                                          color: ping < 300
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                              : null,
                                        ),
                                      )
                                    else if (_serverProbed)
                                      Text(
                                        tr('Нет ответа'),
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                        ),
                                      ),
                                    if (isCustom)
                                      IconButton(
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                        ),
                                        tooltip: tr('Убрать'),
                                        onPressed: () => _removeServer(url),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr('Ретрансляторы'),
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  tr(
                                    'Впишите host:port ретранслятора. Он передаёт зашифрованный трафик и не видит ни токен, ни переписку; поднять свой — инструкция в relay/README.md.',
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: TextField(
                              controller: _relayController,
                              decoration: InputDecoration(
                                hintText: '1.2.3.4:8443',
                                errorText: _relayError,
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              keyboardType: TextInputType.url,
                              onSubmitted: (_) => _saveRelay(),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                FilledButton.tonal(
                                  onPressed: _saveRelay,
                                  child: Text(tr('Добавить ретранслятор')),
                                ),
                              ],
                            ),
                          ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: _relayList.length,
                            itemBuilder: (context, index) {
                              final endpoint = _relayList[index];
                              final status = _relayStatuses[endpoint];
                              final enabled = RelayRegistry.instance.isEnabled(
                                endpoint,
                              );
                              final builtIn = RelayRegistry.instance.isBuiltIn(
                                endpoint,
                              );
                              return SwitchListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                value: enabled,
                                onChanged: (value) =>
                                    _toggleRelay(endpoint, value),
                                title: Text(endpoint),
                                secondary: Icon(
                                  status == null
                                      ? Icons.lock_outline_rounded
                                      : status
                                      ? Icons.lock_rounded
                                      : Icons.lock_open_rounded,
                                  color: status == true
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                ),
                                // SwitchListTile без `trailing`: кнопка
                                // удаления живёт в подзаголовке, иначе она
                                // спорит с переключателем за тап.
                                subtitle: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        [
                                          builtIn
                                              ? tr('Встроенный')
                                              : tr('Свой'),
                                          if (status == false) tr('Нет ответа'),
                                        ].join(' · '),
                                      ),
                                    ),
                                    if (!builtIn)
                                      IconButton(
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                        ),
                                        tooltip: tr('Убрать'),
                                        onPressed: () => _removeRelay(endpoint),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                if (isLoggedIn) ...[
                  _SectionHeader(
                    title: tr('Уведомления'),
                    icon: Icons.notifications_active_rounded,
                  ),
                  SliverToBoxAdapter(
                    child: Consumer(
                      builder: (context, ref, _) {
                        final notificationsEnabled = ref.watch(
                          notificationsSettingsProvider,
                        );
                        final profileAsync = ref.watch(
                          userProfileProvider(_currentUserId!),
                        );
                        final quietHoursEnabled = profileAsync.maybeWhen(
                          data: (p) => p.quietHoursEnabled,
                          orElse: () => true,
                        );

                        return _SettingsGroup(
                          tiles: [
                            SwitchListTile(
                              secondary: _SettingsSwitchIcon(
                                icon: notificationsEnabled
                                    ? Icons.notifications_active_outlined
                                    : Icons.notifications_off_outlined,
                              ),
                              title: Text(tr('Push-уведомления')),
                              subtitle: Text(
                                notificationsEnabled
                                    ? tr('Включены')
                                    : tr('Выключены'),
                              ),
                              value: notificationsEnabled,
                              onChanged: (_) => ref
                                  .read(notificationsSettingsProvider.notifier)
                                  .toggle(!notificationsEnabled),
                            ),
                            SwitchListTile(
                              secondary: const _SettingsSwitchIcon(
                                icon: Icons.nightlight_round,
                              ),
                              title: Text(tr('Не беспокоить ночью')),
                              subtitle: Text(
                                quietHoursEnabled
                                    ? tr('Push выключены с 22:00 до 08:00')
                                    : tr('Пуши приходят в любое время'),
                              ),
                              value: quietHoursEnabled,
                              onChanged: (_) =>
                                  _toggleQuietHours(quietHoursEnabled),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],

                // Интерактивный тур по созданию квеста скрыт — фича сырая,
                // его методы оставлены выше и включаются раскомментированием.
                _SectionHeader(title: tr('Помощь'), icon: Icons.school_rounded),
                SliverToBoxAdapter(
                  child: _SettingsGroup(
                    tiles: [
                      _SettingsTile(
                        icon: Icons.menu_book_rounded,
                        title: tr('Академия'),
                        subtitle: tr(
                          'Видеогайды, разборы квестов, ссылки сообщества',
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => TutorialScreen()),
                        ),
                      ),
                      _SettingsTile(
                        icon: Icons.auto_stories_rounded,
                        title: tr('Гайды по разделам'),
                        subtitle: tr(
                          'Офлайн-статьи, видео и схемы с подсказками',
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => GuidesScreen()),
                        ),
                      ),
                      _SettingsTile(
                        icon: Icons.lightbulb_outline_rounded,
                        title: tr('Подсказки в разделах'),
                        subtitle: tr('Показать объяснения плашек заново'),
                        onTap: _restoreSectionHints,
                      ),
                    ],
                  ),
                ),
                _SectionHeader(
                  title: tr('Информация'),
                  icon: Icons.info_outline_rounded,
                ),
                SliverToBoxAdapter(
                  child: _SettingsGroup(
                    tiles: [
                      if (isLoggedIn)
                        _SettingsTile(
                          icon: Icons.redeem_rounded,
                          title: tr('Ввести код'),
                          subtitle: tr('Активация промокода'),
                          onTap: _showRedeemCodeDialog,
                        ),
                      _SettingsTile(
                        icon: Icons.auto_stories_outlined,
                        title: tr('О нас'),
                        subtitle: tr('История версий, команда'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => AboutScreen()),
                        ),
                      ),
                      if (isLoggedIn)
                        _SettingsTile(
                          icon: Icons.copy_rounded,
                          title: tr('Скопировать ID'),
                          subtitle: _currentUserId,
                          onTap: _copyProfileId,
                        ),
                    ],
                  ),
                ),

                if (kDebugMode) ...[
                  _SectionHeader(
                    title: tr('Разработка'),
                    icon: Icons.bug_report_rounded,
                  ),
                  SliverToBoxAdapter(
                    child: _SettingsGroup(
                      tiles: [
                        _SettingsTile(
                          icon: Icons.system_update_rounded,
                          title: tr('Диалог обновления'),
                          subtitle: tr('Показать тестовое окно с ченджлогом'),
                          iconColor: scheme.tertiary,
                          onTap: () => _showDebugUpdateDialog(context),
                        ),
                        _SettingsTile(
                          icon: Icons.rocket_launch_rounded,
                          title: tr('Первый запуск'),
                          subtitle: tr(
                            'Экран, который видит новый пользователь',
                          ),
                          iconColor: scheme.tertiary,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => PolicyScreen()),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                ],

                if (isAdmin) ...[
                  _SectionHeader(
                    title: tr('Администрирование'),
                    icon: Icons.shield_rounded,
                  ),
                  SliverToBoxAdapter(
                    child: _SettingsGroup(
                      tiles: [
                        _SettingsTile(
                          icon: Icons.security_rounded,
                          title: tr('Админ-панель'),
                          subtitle: tr('Модерация, отчёты, блокировки'),
                          iconColor: scheme.error,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => AdminScreen()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                if (isLoggedIn) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: OutlinedButton.icon(
                        onPressed: _handleLogout,
                        icon: const Icon(Icons.logout_rounded),
                        label: Text(tr('Выйти из аккаунта')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.error,
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // App Store 5.1.1(v): раз в приложении можно создать
                  // аккаунт, удалить его тоже обязано быть в приложении.
                  if (_deletionScheduledAt == null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: FilledButton.tonalIcon(
                          onPressed: _handleDeleteAccount,
                          icon: const Icon(Icons.delete_forever_outlined),
                          label: Text(tr('Удалить аккаунт')),
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.errorContainer,
                            foregroundColor: scheme.onErrorContainer,
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Card(
                          color: scheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.hourglass_bottom_rounded,
                                      color: scheme.onErrorContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        tr('Аккаунт помечен на удаление'),
                                        style: TextStyle(
                                          color: scheme.onErrorContainer,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  trf(
                                    'Будет удалён {p0} — до этой даты всё можно вернуть.',
                                    {
                                      'p0': _formatDeletionDate(
                                        _deletionScheduledAt!,
                                      ),
                                    },
                                  ),
                                  style: TextStyle(
                                    color: scheme.onErrorContainer,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: _handleCancelDeletion,
                                  icon: const Icon(Icons.undo_rounded),
                                  label: Text(tr('Отменить удаление')),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: scheme.onErrorContainer,
                                    side: BorderSide(
                                      color: scheme.onErrorContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],

                const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  ЗАГОЛОВОК СЕКЦИИ
// ============================================================================

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: scheme.onPrimaryContainer, size: 18),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  ГРУППА ПЛИТОК (общий контейнер с скруглением)
// ============================================================================

class _SettingsGroup extends StatelessWidget {
  final List<Widget> tiles;
  const _SettingsGroup({required this.tiles});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = tiles.where((_) => true).toList();
    if (list.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < list.length; i++) ...[
              list[i],
              if (i < list.length - 1)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 60,
                  color: scheme.outlineVariant.withOpacity(0.4),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  ПЛИТКА НАСТРОЙКИ
// ============================================================================

class _ScriptEditorModeTile extends StatelessWidget {
  const _ScriptEditorModeTile({required this.value, required this.onChanged});

  final ScriptEditorMode value;
  final ValueChanged<ScriptEditorMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SettingsSwitchIcon(icon: Icons.account_tree_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Редактор скриптов'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      tr('Выберите способ редактирования визуальных скриптов'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<ScriptEditorMode>(
            segments: [
              ButtonSegment(
                value: ScriptEditorMode.classic,
                icon: const Icon(Icons.view_agenda_outlined),
                label: Text(tr('Классический')),
              ),
              ButtonSegment(
                value: ScriptEditorMode.canvas,
                icon: const Icon(Icons.account_tree_outlined),
                label: Text(tr('Канвас как в Scratch')),
              ),
            ],
            selected: {value},
            onSelectionChanged: (selected) {
              if (selected.isNotEmpty) onChanged(selected.first);
            },
          ),
        ],
      ),
    );
  }
}

class _SettingsSwitchIcon extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;

  const _SettingsSwitchIcon({required this.icon, this.iconColor});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = iconColor ?? scheme.onSurface;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: (iconColor ?? scheme.primary).withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 20, color: color),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = iconColor ?? scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: (iconColor ?? scheme.primary).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: scheme.onSurface),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
