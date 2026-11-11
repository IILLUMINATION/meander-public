import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mnd_core/mnd_core.dart';
import 'package:mnd_player/screens/table_viewer_screen.dart';

void main() {
  testWidgets('просмотр данных показывает имя строки рядом с номером', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final table = QuestTable(
      name: 'ЧСМ',
      columns: const ['dsf'],
      rows: [
        <String, dynamic>{'dsf': 'a'},
        <String, dynamic>{'dsf': 'b'},
      ],
      rowNames: const ['{test}', ''],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: TableViewerScreen(tableName: 'ЧСМ', table: table),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 · {test}'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });
}
