import 'package:canvas_app/features/profile/cosmetics/cosmetic_model.dart';

/// Комментарий в общем виде.
///
/// Карточка комментария одна на всё приложение, а бэкенды разные: стена
/// сообщества отдаёт лайки, ответы и косметику автора, комментарии канала —
/// только текст, время и профиль. Экран раскладывает свой ответ в эту модель,
/// поэтому никто не заводит второй список комментариев со своя вёрсткой.
class CommentView {
  const CommentView({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
    this.avatarUrl,
    this.nameStyle,
    this.cosmetics = EquippedCosmetics.none,
    this.likesCount = 0,
    this.likedByMe = false,
    this.parentId,
  });

  final String id;

  /// Пустая строка — автор обезличен (например, удалённый профиль): карточку
  /// тогда не открываем, но текст и время показываем.
  final String authorId;
  final String authorName;
  final String? avatarUrl;

  /// id стиля ника и экипировка автора: оформление профиля видно и в
  /// комментариях, иначе человек в них выглядит чужим.
  final String? nameStyle;
  final EquippedCosmetics cosmetics;

  /// Markdown: ссылки, упоминания и переносы строк.
  final String body;
  final DateTime createdAt;

  final int likesCount;
  final bool likedByMe;

  /// Ответ на чужой комментарий. `null` — корневой.
  final String? parentId;

  bool get isReply => parentId != null;
  bool get canOpenAuthor => authorId.isNotEmpty;
}
