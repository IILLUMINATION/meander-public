import 'package:canvas_app/features/resources/screens/lua_docs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Документация — лицо Lua-API: по запросу об авторе каждая `core.*`-функция,
/// которую регистрирует рантайм (`crates/mnd-core/src/lua/mod.rs`), должна
/// находить карточку с примером. Список карточек собирается лениво, поэтому
/// проверяем не «всё на экране», а отклик поиска.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<void> openDocs(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LuaDocsScreen()));
    await tester.pump();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(SearchBar), query);
    await tester.pump();
  }

  testWidgets('под каждой эффект-функцией core.* есть карточка', (
    tester,
  ) async {
    await openDocs(tester);
    for (final name in [
      'core.go_to',
      'core.play_sound',
      'core.stop_sound',
      'core.play_music',
      'core.stop_music',
      'core.pause_resume',
      'core.set_volume',
      'core.set_blur',
      'core.set_item_visible',
      'core.set_item_image',
      'core.open_link',
      'core.set_top_panel',
      'core.fade_out',
      'core.fade_in',
      'core.save_game',
      'core.open_saves',
      'core.load_save',
      'core.delete_save',
      'core.log',
    ]) {
      await search(tester, name);
      expect(find.text('Ничего не найдено'), findsNothing, reason: name);
    }
  });

  testWidgets('границы Lua описаны честно, а не молча', (tester) async {
    await openDocs(tester);
    await search(tester, 'не хватает');
    expect(find.textContaining('Чего Lua пока не хватает'), findsOneWidget);
    expect(find.textContaining('wait'), findsWidgets);
  });

  testWidgets('поиск по имени функции доводит до карточки эффектов', (
    tester,
  ) async {
    await openDocs(tester);
    await search(tester, 'set_item_visible');
    expect(find.textContaining('Контент ноды'), findsOneWidget);
  });
}
