import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/core/l10n/l10n_provider.dart';
import 'package:canvas_app/core/services/api_service.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:canvas_app/core/services/onboarding_service.dart';
import 'package:canvas_app/core/services/session_service.dart';
import 'package:canvas_app/features/app/screens/about_screen.dart';
import 'package:canvas_app/features/app/screens/tutorial_screen.dart';
import 'package:canvas_app/features/onboarding/controllers/tutorial_controller.dart';
import 'package:canvas_app/features/onboarding/hints/section_hint.dart';
import 'package:canvas_app/features/plugins/screens/plugin_manager_screen.dart';
import 'package:canvas_app/features/app/screens/update_screen.dart';
import 'package:canvas_app/features/messages/screens/chat_privacy_screen.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetics_repository.dart';
import 'package:canvas_app/features/profile/providers/profile_provider.dart';
import 'package:canvas_app/features/quests/screens/my_quests_screen.dart';
import 'package:canvas_app/features/settings/providers/notifications_settings_provider.dart';
import 'package:canvas_app/features/settings/screens/theme_settings_screen.dart';
import 'package:canvas_app/features/settings/widgets/interface_language_dialog.dart';
import 'package:canvas_app/features/settings/widgets/refresh_rate_card.dart';
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

  /// Удаление аккаунта уже запланировано — дата, когда строка уйдёт.
  DateTime? _deletionScheduledAt;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _currentUserId = prefs.getString('user_id');
        _tabsEnabled = prefs.getBool('editor_tabs_enabled') ?? true;
        _autoOpenTab = prefs.getBool('editor_auto_open_tab') ?? false;
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
          content: Text(trf('Не удалось изменить: {p0}', {'p0': friendlyError(e)})),
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
                tr('Аккаунт, профиль, сохранения, переписки, публикации и статистика будут удалены безвозвратно.\n\nКвесты других авторов, которые вы купили или скачали, останутся на устройстве.'),
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
                ? tr('Аккаунт будет удалён в ближайшие дни. Если передумаете — войдите и отмените удаление в этих же настройках.')
                : trf('Аккаунт будет удалён {p0}. Если передумаете — вернитесь в приложение, войдите и отмените удаление здесь же.', {'p0': _formatDeletionDate(scheduledAt)}),
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
            content: Text(trf('Не удалось удалить аккаунт: {p0}', {'p0': friendlyError(e)})),
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
            content: Text(trf('Не удалось отменить: {p0}', {'p0': friendlyError(e)})),
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
          tr('Обучение по созданию квеста будет показано снова при следующем нажатии на «Создать квест».'),
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

  Future<void> _toggleNsfw(bool current) async {
    if (_currentUserId == null) return;
    final container = ProviderScope.containerOf(context, listen: false);

    if (!current) {
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Внимание')),
          content: Text(
            tr('Контент 18+ может содержать нецензурную лексику, жестокость и материалы для взрослых.\n\nПодтвердите, что вам исполнилось 18 лет.'),
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
          SnackBar(
            content: Text(message),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              serverErrorMessage(e, fallback: tr('Не удалось активировать код')),
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
                              icon: Icons.description_outlined,
                              title: tr('Редактировать био'),
                              subtitle: bio ?? tr('Не задано'),
                              onTap: _editBio,
                            ),
                            _SettingsTile(
                              icon: showNsfw
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              title: tr('Контент 18+'),
                              subtitle: showNsfw ? tr('Включен') : tr('Скрыт из ленты'),
                              iconColor: showNsfw
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                              onTap: () => _toggleNsfw(showNsfw),
                            ),
                            _SettingsTile(
                              icon: Icons.mail_outline_rounded,
                              title: tr('Личные сообщения'),
                              subtitle: tr('Кто может писать, стаж, блокировки'),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ChatPrivacyScreen(),
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
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          SwitchListTile(
                            secondary: const Icon(Icons.tab_rounded),
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
                            secondary: const Icon(Icons.open_in_new_rounded),
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
                            _SettingsTile(
                              icon: notificationsEnabled
                                  ? Icons.notifications_active_outlined
                                  : Icons.notifications_off_outlined,
                              title: tr('Push-уведомления'),
                              subtitle: notificationsEnabled
                                  ? tr('Включены')
                                  : tr('Выключены'),
                              onTap: () => ref
                                  .read(notificationsSettingsProvider.notifier)
                                  .toggle(!notificationsEnabled),
                            ),
                            _SettingsTile(
                              icon: Icons.nightlight_round,
                              title: tr('Не беспокоить ночью'),
                              subtitle: quietHoursEnabled
                                  ? tr('Push выключены с 22:00 до 08:00')
                                  : tr('Пуши приходят в любое время'),
                              onTap: () => _toggleQuietHours(quietHoursEnabled),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],

                // Интерактивный тур по созданию квеста скрыт — фича сырая,
                // его методы оставлены выше и включаются раскомментированием.
                _SectionHeader(
                  title: tr('Помощь'),
                  icon: Icons.school_rounded,
                ),
                SliverToBoxAdapter(
                  child: _SettingsGroup(
                    tiles: [
                      _SettingsTile(
                        icon: Icons.menu_book_rounded,
                        title: tr('Академия'),
                        subtitle:
                            tr('Видеогайды, разборы квестов, ссылки сообщества'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => TutorialScreen(),
                          ),
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
                          MaterialPageRoute(
                            builder: (_) => AboutScreen(),
                          ),
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
                            MaterialPageRoute(
                              builder: (_) => AdminScreen(),
                            ),
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
                      child: FilledButton.tonalIcon(
                        onPressed: _handleLogout,
                        icon: const Icon(Icons.logout_rounded),
                        label: Text(tr('Выйти из аккаунта')),
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
                        child: OutlinedButton.icon(
                          onPressed: _handleDeleteAccount,
                          icon: const Icon(Icons.delete_forever_outlined),
                          label: Text(tr('Удалить аккаунт')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.error,
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
                                  trf('Будет удалён {p0} — до этой даты всё можно вернуть.', {'p0': _formatDeletionDate(_deletionScheduledAt!)}),
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
                                    foregroundColor:
                                        scheme.onErrorContainer,
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
  final List<_SettingsTile> tiles;
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
              child: Icon(icon, size: 20, color: color),
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
