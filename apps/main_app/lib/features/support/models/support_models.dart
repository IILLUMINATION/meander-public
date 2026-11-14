import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/messages/models/dm_models.dart';

/// Кнопка под сообщением бота. `id` — не текст: на нём завязано дерево бота
/// (`new`, `faq`, `cat:bug`, `lang:en`), а подпись переводится на стороне
/// сервера под язык диалога.
class SupportButton {
  const SupportButton({required this.id, required this.label});

  final String id;
  final String label;

  static List<SupportButton> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final result = <SupportButton>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final id = (item['id'] ?? '').toString();
      final label = (item['label'] ?? '').toString();
      if (id.isEmpty || label.isEmpty) continue;
      result.add(SupportButton(id: id, label: label));
    }
    return result;
  }
}

/// Реплика в окне поддержки.
class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.role,
    required this.body,
    required this.createdAt,
    this.ticketId,
    this.senderId,
    this.attachments = const [],
    this.buttons = const [],
    this.pending = false,
  });

  final String id;

  /// 'user', 'bot', 'staff' или 'system'.
  final String role;
  final String body;
  final DateTime createdAt;
  final String? ticketId;
  final String? senderId;
  final List<DmAttachment> attachments;
  final List<SupportButton> buttons;

  /// Отправлено локально, ответ сервера ещё не пришёл.
  final bool pending;

  bool get isMine => role == 'user';
  bool get isBot => role == 'bot';

  factory SupportMessage.fromJson(Map<dynamic, dynamic> json) {
    return SupportMessage(
      id: (json['id'] ?? '').toString(),
      role: (json['role'] ?? 'user').toString(),
      body: (json['body'] ?? '').toString(),
      createdAt:
          DateTime.tryParse('${json['created_at'] ?? ''}')?.toLocal() ??
          DateTime.now(),
      ticketId: json['ticket_id']?.toString(),
      senderId: json['sender_id']?.toString(),
      attachments: DmAttachment.listFrom(json['attachments']),
      buttons: SupportButton.listFrom(json['buttons']),
    );
  }

  SupportMessage copyWith({String? id, bool? pending}) {
    return SupportMessage(
      id: id ?? this.id,
      role: role,
      body: body,
      createdAt: createdAt,
      ticketId: ticketId,
      senderId: senderId,
      attachments: attachments,
      buttons: buttons,
      pending: pending ?? this.pending,
    );
  }
}

/// Обращение. Человеку показываем его в списке «Мои обращения», команде — в
/// инбоксе.
class SupportTicket {
  const SupportTicket({
    required this.id,
    required this.subject,
    this.category = 'other',
    this.status = 'open',
    this.unread = 0,
    this.lastBody,
    this.lastMessageAt,
    this.createdAt,
    this.userName,
    this.userAvatarUrl,
    this.priority = 0,
  });

  final String id;
  final String subject;
  final String category;

  /// 'open' — ждёт команду, 'answered' — ответили, 'closed' — закрыто.
  final String status;
  final int unread;
  final String? lastBody;
  final DateTime? lastMessageAt;
  final DateTime? createdAt;

  /// Поля профиля автора: инбокс команды показывает, кто пишет.
  final String? userName;
  final String? userAvatarUrl;
  final int priority;

  bool get isClosed => status == 'closed';

  String get statusTitle => switch (status) {
    'open' => tr('Ждёт ответа'),
    'answered' => tr('Ответили'),
    'closed' => tr('Закрыто'),
    _ => status,
  };

  String get categoryTitle => switch (category) {
    'bug' => tr('Ошибка в приложении'),
    'payment' => tr('Оплата'),
    'account' => tr('Аккаунт'),
    'idea' => tr('Идея'),
    _ => tr('Другое'),
  };

  factory SupportTicket.fromJson(Map<dynamic, dynamic> json) {
    return SupportTicket(
      id: (json['id'] ?? '').toString(),
      subject: (json['subject'] ?? tr('Обращение')).toString(),
      category: (json['category'] ?? 'other').toString(),
      status: (json['status'] ?? 'open').toString(),
      unread: json['unread'] is int
          ? json['unread'] as int
          : int.tryParse('${json['unread'] ?? 0}') ?? 0,
      lastBody: json['last_body']?.toString(),
      lastMessageAt: _local(json['last_message_at']),
      createdAt: _local(json['created_at']),
      userName: json['full_name']?.toString(),
      userAvatarUrl: json['avatar_url']?.toString(),
      priority: json['priority'] is int
          ? json['priority'] as int
          : int.tryParse('${json['priority'] ?? 0}') ?? 0,
    );
  }
}

DateTime? _local(Object? raw) => DateTime.tryParse('${raw ?? ''}')?.toLocal();