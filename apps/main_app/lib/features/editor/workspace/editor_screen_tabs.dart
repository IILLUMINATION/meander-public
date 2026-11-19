import 'package:flutter/material.dart';

import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/features/profile/screens/profile_screen.dart';

import 'editor_document.dart';
import 'editor_nested_documents.dart';
import 'editor_workspace_scope.dart';

/// Универсальная точка открытия экранов: в воркспейсе — вкладкой, вне его —
/// прежним маршрутом.
///
/// Экраны приложения не знают id квеста и не должны тянуть его через
/// параметры: scope воркспейса уже знает, где открыт. Поэтому профиль,
/// каталог, настройки и любые другие экраны можно открывать одной функцией,
/// не заводя отдельный `EditorDocumentKind` под каждый.
class EditorScreenTabs {
  EditorScreenTabs._();

  static Future<T?> open<T>(
    BuildContext context, {
    required String identity,
    required String title,
    required WidgetBuilder builder,
    IconData? icon,
  }) {
    final scope = EditorWorkspaceScope.maybeOf(context);
    if (scope == null) {
      return Navigator.push<T>(context, MaterialPageRoute<T>(builder: builder));
    }
    return EditorNestedDocuments.open<T>(
      context,
      questId: scope.questId,
      identity: identity,
      title: title,
      kind: EditorDocumentKind.screen,
      icon: icon,
      builder: builder,
    );
  }

  /// Профиль автора/пользователя. В воркспейсе каждый профиль получает
  /// отдельную вкладку, поэтому возврат к прежней вкладке не теряет её.
  static Future<void> openProfile(BuildContext context, String userId) {
    if (userId.isEmpty) return Future<void>.value();
    return open<void>(
      context,
      identity: 'profile:$userId',
      title: tr('Профиль'),
      icon: Icons.person_rounded,
      builder: (_) => ProfileScreen(userId: userId),
    );
  }
}
