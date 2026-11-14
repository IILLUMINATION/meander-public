import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';

/// Сервисный аккаунт команды: тот же диалог, что и человеческий, только
/// вторым участником числится он. Id зафиксирован в `add_direct_messages.sql`.
const String kSystemUserId = '00000000-0000-0000-0000-000000000001';

/// Собеседник в ленте переписок и в шапке окна чата.
class DmPeer {
  const DmPeer({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.equipped = EquippedCosmetics.none,
    this.role = 'user',
    this.lastSeenAt,
  });

  final String id;
  final String name;
  final String? avatarUrl;

  /// Рамка аватара и стиль ника — как и везде, где показан человек.
  final EquippedCosmetics equipped;
  final String role;
  final DateTime? lastSeenAt;

  bool get isSystem => id == kSystemUserId;
  bool get isStaff => role == 'admin' || role == 'moderator';

  /// Строка «был(а) …» под именем; у аккаунта команды она не нужна.
  String get presenceLine {
    if (isSystem) return tr('Новости команды и системные уведомления');
    return lastSeenAt == null ? tr('В сети давно') : formatSeen(lastSeenAt!);
  }

  static String formatSeen(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 5) return tr('Сейчас в сети');
    if (diff.inHours < 24) {
      return trf('Был(а) {p0} ч назад', {'p0': diff.inHours});
    }
    return trf('Был(а) {p0} дн назад', {'p0': diff.inDays});
  }

  /// Лента диалогов и окно чата отдают человека с префиксом `peer_`, список
  /// блокировок — теми же колонками без префикса.
  factory DmPeer.fromJson(Map<dynamic, dynamic> json) {
    Object? pick(String prefixed, String plain) =>
        json['peer_$prefixed'] ?? json[plain];
    return DmPeer(
      id: (pick('id', 'id') ?? '').toString(),
      name: (pick('name', 'full_name') ?? tr('Пользователь')).toString(),
      avatarUrl: pick('avatar_url', 'avatar_url')?.toString(),
      equipped: equippedOf({
        'author_cosmetics': pick('cosmetics', 'cosmetics'),
      }),
      role: (pick('role', 'role') ?? 'user').toString(),
      lastSeenAt: _local(pick('last_seen_at', 'last_seen_at')),
    );
  }
}

/// Одна строка ленты «Чаты».
class DmThread {
  const DmThread({
    required this.threadId,
    required this.peer,
    this.lastBody,
    this.lastSenderId,
    this.lastKind = 'text',
    this.muted = false,
    this.unread = 0,
    this.lastMessageAt,
    this.lastAttachments = const [],
  });

  final String threadId;
  final DmPeer peer;

  /// Пустой диалог возможен: тред создаётся вместе с профилем команды,
  /// а сообщений в нём ещё нет.
  final String? lastBody;
  final String? lastSenderId;

  /// 'text' в человеческом диалоге; в системном — type уведомления или 'news'.
  final String lastKind;
  final bool muted;
  final int unread;
  final DateTime? lastMessageAt;

  /// Фото последней реплики: в ленте вместо текста пишем «Фото».
  final List<DmAttachment> lastAttachments;

  bool get isSystem => peer.isSystem;

  String get preview {
    final body = lastBody;
    if (body == null || body.isEmpty) {
      if (lastAttachments.isNotEmpty) {
        return lastAttachments.length == 1
            ? tr('Фото')
            : trf('{p0} фото', {'p0': lastAttachments.length});
      }
      return isSystem
          ? tr('Пока пусто — здесь появятся новости Meander')
          : tr('Нет сообщений');
    }
    final oneLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 90 ? oneLine : '${oneLine.substring(0, 90)}…';
  }

  /// «Вы: » у последних реплик — как в мессенджерах, чтобы лента читалась
  /// без сверки с аватаром.
  String previewFor(String viewerId) {
    if (lastSenderId == null || lastSenderId != viewerId) return preview;
    final body = preview;
    return body.startsWith('Вы:') ? body : trf('Вы: {body}', {'body': body});
  }

  factory DmThread.fromJson(Map<dynamic, dynamic> json) {
    return DmThread(
      threadId: (json['thread_id'] ?? '').toString(),
      peer: DmPeer.fromJson(json),
      lastBody: json['last_body']?.toString(),
      lastSenderId: json['last_sender_id']?.toString(),
      lastKind: (json['last_kind'] ?? 'text').toString(),
      muted: json['muted'] == true,
      unread: json['unread'] is int
          ? json['unread'] as int
          : int.tryParse('${json['unread']}') ?? 0,
      lastMessageAt: _local(json['last_message_at']),
      lastAttachments: DmAttachment.listFrom(json['last_attachments']),
    );
  }

  DmThread copyWith({
    String? lastBody,
    String? lastSenderId,
    String? lastKind,
    DateTime? lastMessageAt,
    bool? muted,
    int? unread,
    List<DmAttachment>? lastAttachments,
  }) {
    return DmThread(
      threadId: threadId,
      peer: peer,
      lastBody: lastBody ?? this.lastBody,
      lastSenderId: lastSenderId ?? this.lastSenderId,
      lastKind: lastKind ?? this.lastKind,
      muted: muted ?? this.muted,
      unread: unread ?? this.unread,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastAttachments: lastAttachments ?? this.lastAttachments,
    );
  }
}

/// Фото в сообщении: сервер уже пересжал его и вернул размеры, поэтому
/// превью можно резервировать до загрузки и лента не прыгает.
class DmAttachment {
  const DmAttachment({
    required this.url,
    this.width = 0,
    this.height = 0,
    this.size = 0,
  });

  final String url;
  final int width;
  final int height;
  final int size;

  /// Пропорции кадра для резерва места: 0 — размеры неизвестны.
  double? get aspectRatio => width > 0 && height > 0 ? width / height : null;

  static List<DmAttachment> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final result = <DmAttachment>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final url = (item['url'] ?? '').toString();
      if (url.isEmpty) continue;
      result.add(
        DmAttachment(
          url: url,
          width: _int(item['width']),
          height: _int(item['height']),
          size: _int(item['size']),
        ),
      );
    }
    return result;
  }

  static int _int(Object? raw) =>
      raw is int ? raw : int.tryParse('${raw ?? 0}') ?? 0;
}

/// Реплика переписки.
class DmMessage {
  const DmMessage({
    required this.id,
    required this.threadId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    this.kind = 'text',
    this.pending = false,
    this.attachments = const [],
  });

  final String id;
  final String threadId;
  final String senderId;
  final String body;
  final DateTime createdAt;

  /// 'news' и type уведомления — служебные реплики аккаунта команды.
  final String kind;

  /// Отправлено, но ответа сервера ещё нет: показываем часики, а не галочку.
  final bool pending;

  /// До пяти фото: сервер режет размер и отдаёт уже сжатые ссылки.
  final List<DmAttachment> attachments;

  bool get isService => kind == 'news' || kind == 'system';

  factory DmMessage.fromJson(Map<dynamic, dynamic> json) {
    return DmMessage(
      id: (json['id'] ?? '').toString(),
      threadId: (json['thread_id'] ?? '').toString(),
      senderId: (json['sender_id'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      createdAt:
          _local(json['created_at']) ?? DateTime.now(),
      kind: (json['kind'] ?? 'text').toString(),
      attachments: DmAttachment.listFrom(json['attachments']),
    );
  }

  DmMessage copyWith({
    String? id,
    String? threadId,
    bool? pending,
    List<DmAttachment>? attachments,
  }) {
    return DmMessage(
      id: id ?? this.id,
      threadId: threadId ?? this.threadId,
      senderId: senderId,
      body: body,
      createdAt: createdAt,
      kind: kind,
      pending: pending ?? this.pending,
      attachments: attachments ?? this.attachments,
    );
  }
}

/// Сервер отдаёт момент в UTC. Без перевода в местный пояс вечерняя реплика
/// ложилась бы не в тот день, а часы под пузырём показывали бы чужое время.
DateTime? _local(Object? raw) => DateTime.tryParse('${raw ?? ''}')?.toLocal();

/// Настройка «кто может мне писать».
class DmPrivacy {
  const DmPrivacy({
    this.mode = 'everyone',
    this.minPlaytimeHours = 0,
    this.minAccountAgeDays = 0,
  });

  final String mode;
  final int minPlaytimeHours;
  final int minAccountAgeDays;

  static const List<String> modes = [
    'everyone',
    'standing',
    'following',
    'nobody',
  ];

  static String modeTitle(String mode) => switch (mode) {
    'everyone' => tr('Все'),
    'standing' => tr('Только участники с историей'),
    'following' => tr('Только те, на кого я подписан'),
    'nobody' => tr('Никто — личка закрыта'),
    _ => tr('Все'),
  };

  static String modeSubtitle(String mode) => switch (mode) {
    'everyone' => tr('Писать может любой, кроме заблокированных'),
    'standing' =>
      tr('Нужны подписчики, опубликованный квест, отзывы, стрик или наигранные часы'),
    'following' => tr('Только тем, за кого вы следите'),
    'nobody' => tr('Сообщения не приходят никому'),
    _ => '',
  };

  factory DmPrivacy.fromJson(Map<dynamic, dynamic> json) {
    final mode = (json['mode'] ?? 'everyone').toString();
    return DmPrivacy(
      mode: modes.contains(mode) ? mode : 'everyone',
      minPlaytimeHours: _int(json['min_playtime_hours']),
      minAccountAgeDays: _int(json['min_account_age_days']),
    );
  }

  static int _int(Object? raw) =>
      raw is int ? raw : int.tryParse('${raw ?? 0}') ?? 0;
}
