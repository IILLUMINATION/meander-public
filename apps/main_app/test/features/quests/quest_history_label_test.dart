import 'package:canvas_app/features/quests/screens/quest_history_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('старая точка получает дату без инициализации локали intl', () {
    // Негативный контроль: если вернуть DateFormat('dd MMM yyyy', 'ru'),
    // тест упадёт с LocaleDataException, как падала карточка в release.
    expect(snapshotTimestampLabel(DateTime(2026, 10, 20, 18, 46)), '20.10.2026');
  });
}
