import 'package:canvas_app/features/messages/models/dm_models.dart';
import 'package:canvas_app/features/messages/providers/dm_provider.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_widgets.dart';
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// «Кто может мне писать»: режим, два порога стажа и список блокировок.
///
/// Пороги — не украшение: пока личка открыта всем, любой регистр на пять
/// секунд превращается в рассылку. При этом блокировка живёт рядом, потому что
/// для одного человека она точнее любого режима.
class ChatPrivacyScreen extends ConsumerStatefulWidget {
  const ChatPrivacyScreen({super.key});

  @override
  ConsumerState<ChatPrivacyScreen> createState() => _ChatPrivacyScreenState();
}

class _ChatPrivacyScreenState extends ConsumerState<ChatPrivacyScreen> {
  final TextEditingController _days = TextEditingController();
  final TextEditingController _hours = TextEditingController();
  String _mode = 'everyone';
  bool _dirty = false;

  @override
  void dispose() {
    _days.dispose();
    _hours.dispose();
    super.dispose();
  }

  void _sync(DmPrivacy privacy) {
    if (_dirty) return;
    _mode = privacy.mode;
    _days.text = privacy.minAccountAgeDays == 0
        ? ''
        : '${privacy.minAccountAgeDays}';
    _hours.text = privacy.minPlaytimeHours == 0
        ? ''
        : '${privacy.minPlaytimeHours}';
  }

  DmPrivacy _draft() {
    return DmPrivacy(
      mode: _mode,
      minAccountAgeDays: int.tryParse(_days.text.trim()) ?? 0,
      minPlaytimeHours: int.tryParse(_hours.text.trim()) ?? 0,
    );
  }

  Future<void> _save() async {
    final error = await ref.read(dmPrivacyProvider.notifier).save(_draft());
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? tr('Настройки сохранены'))));
  }

  Future<void> _unblock(DmPeer peer) async {
    final error = await ref.read(dmBlocksProvider.notifier).unblock(peer.id);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _confirmUnblock(DmPeer peer) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Разблокировать?')),
        content: Text(
          tr('Человек снова сможет писать тебе в личные сообщения.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Разблокировать пользователя')),
          ),
        ],
      ),
    );
    if (confirmed == true) await _unblock(peer);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final privacy = ref.watch(dmPrivacyProvider);
    if (privacy != null) _sync(privacy);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(tr('Личные сообщения')),
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          AdaptiveContent(
            maxWidth: 720,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Text(
                  tr('Кто может начать переписку'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final mode in DmPrivacy.modes)
                  _ModeTile(
                    mode: mode,
                    selected: _mode == mode,
                    onTap: () => setState(() {
                      _mode = mode;
                      _dirty = true;
                    }),
                  ),
                const SizedBox(height: 20),
                Text(
                  tr('Дополнительные пороги'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Text(
                    tr('Работают поверх режима: человеку должно быть столько дней с регистрации и столько часов в квестах. Проверяются только в новом диалоге — отвеченная переписка не рвётся посередине. 0 — порог не нужен.'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _ThresholdField(
                  controller: _days,
                  label: tr('Возраст аккаунта, дней'),
                  icon: Icons.calendar_month_outlined,
                  onChanged: () => setState(() => _dirty = true),
                ),
                const SizedBox(height: 10),
                _ThresholdField(
                  controller: _hours,
                  label: tr('Наиграно в квестах, часов'),
                  icon: Icons.schedule_rounded,
                  onChanged: () => setState(() => _dirty = true),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: privacy == null ? null : _save,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text(tr('Сохранить')),
                ),
                const SizedBox(height: 28),
                Text(
                  tr('Заблокированные'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                _BlocksList(onUnblock: _confirmUnblock),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final String mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: selected ? scheme.primary : Colors.transparent),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Icon(
          selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(
          DmPrivacy.modeTitle(mode),
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          DmPrivacy.modeSubtitle(mode),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _ThresholdField extends StatelessWidget {
  const _ThresholdField({
    required this.controller,
    required this.label,
    required this.icon,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      onChanged: (_) => onChanged(),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        hintText: '0',
        prefixIcon: Icon(icon, color: scheme.onSurfaceVariant),
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _BlocksList extends ConsumerWidget {
  const _BlocksList({required this.onUnblock});

  final void Function(DmPeer peer) onUnblock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = ref.watch(dmBlocksProvider);

    if (blocked.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          tr('Никого не блокировал.'),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    return Column(
      children: [
        for (final peer in blocked)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                CosmeticAvatar(
                  frame: cosmeticById(peer.equipped.avatarFrame),
                  avatarUrl: peer.avatarUrl,
                  radius: 20,
                  placeholderColor: scheme.surfaceContainerHighest,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: CosmeticNameText(
                    name: peer.name,
                    def: cosmeticById(peer.equipped.nameStyle),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => onUnblock(peer),
                  child: Text(tr('Разблокировать пользователя')),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
