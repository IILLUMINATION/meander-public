import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

void main() {
  testWidgets('M3E-компоненты работают внутри Flutter MaterialApp', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: M3ETheme(
          data: M3EThemeData.light(seedColor: Colors.blue),
          child: Scaffold(
            appBar: M3EAppBar.top(
              automaticallyImplyLeading: false,
              leading: M3EIconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () {},
              ),
              titleText: 'Моя библиотека',
              subtitleText: 'Библиотека',
              variant: M3EAppBarVariant.mediumFlexible,
              actions: [
                M3EIconButton(
                  icon: const Icon(Icons.help_outline_rounded),
                  onPressed: () {},
                ),
              ],
            ),
            body: Column(
              children: [
                M3ETabs(
                  selectedIndex: 0,
                  onTabSelected: (_) {},
                  tabs: [
                    M3ETab(
                      label: 'Ресурсы',
                      icon: const Icon(Icons.collections_rounded),
                    ),
                    M3ETab(
                      label: 'Музыка',
                      icon: const Icon(Icons.music_note_rounded),
                    ),
                  ],
                ),
                Expanded(
                  child: M3ETabsView(
                    selectedIndex: 0,
                    onTabSelected: (_) {},
                    children: [
                      ListView(
                        children: [
                          M3ECard(
                            variant: M3ECardVariant.filled,
                            child: Column(
                              children: [
                                M3EChip(
                                  label: 'Фильтр',
                                  type: M3EChipType.filter,
                                  selected: true,
                                  onPressed: () {},
                                ),
                                M3EButton(
                                  label: const Text('В квест'),
                                  style: M3EButtonStyle.tonal,
                                  size: M3EButtonSize.xs,
                                  onPressed: () {},
                                ),
                                M3EProgressIndicator.circularWavy(size: 32),
                              ],
                            ),
                          ),
                        ],
                      ),
                      M3EList.scrollable(
                        itemCount: 2,
                        padding: const EdgeInsets.all(16),
                        gap: 8,
                        itemBuilder: (context, index) => M3EListItem(
                          headline: 'Трек $index',
                          supportingText: 'Исполнитель',
                          largeLeading: true,
                          leading: const Icon(Icons.music_note_rounded),
                          trailing: M3EIconButton(
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () {},
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('Моя библиотека'), findsOneWidget);
    expect(find.text('В квест'), findsOneWidget);
  });
}
