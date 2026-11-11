import 'package:canvas_app/shared/entity_links/entity_ref_card.dart';
import 'package:canvas_app/shared/widgets/app_markdown_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Что видит человек в переписке и в текстах, где карточка-блок неуместна:
/// вместо адреса — короткая живая ссылка.
void main() {
  const questId = '3a84a172-c52d-4414-a0af-b2f9393f32ae';

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
  }

  testWidgets('ссылка на квест сворачивается в кликабельное слово', (tester) async {
    await pump(
      tester,
      MeanderEntityLinkText(
        data: 'зацени https://meander.illuminat.dev/share/quest/$questId',
      ),
    );

    expect(find.textContaining('квест · 3a84a172'), findsOneWidget);
    expect(find.textContaining(questId), findsNothing);
    expect(find.textContaining('meander.illuminat.dev'), findsNothing);
  });

  testWidgets('у ссылки есть InkWell — по ней можно нажать', (tester) async {
    await pump(
      tester,
      const MeanderEntityLinkText(data: 'meander://profile/$questId'),
    );
    expect(find.byType(InkWell), findsOneWidget);
    expect(find.textContaining('профиль · '), findsOneWidget);
  });

  testWidgets('текст без ссылок остаётся обычным Text', (tester) async {
    await pump(tester, const MeanderEntityLinkText(data: 'привет, как ты?'));
    expect(find.byType(Text), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('обычный Text без ссылок не обрамляется в карточку', (tester) async {
    await pump(tester, const MeanderEntityText(data: 'просто строка'));
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('markdown без ссылок идёт тем же рендерером', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => SingleChildScrollView(
                child: MeanderEntityMarkdown(
                  data: 'абзац **жирным**',
                  config: AppMarkdown.getConfig(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('абзац'), findsWidgets);
    expect(find.byType(MeanderEntityCard), findsNothing);
  });
}
