import 'package:canvas_app/features/editor/widgets/quest_validation_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('scriptEditorPath', () {
    test('плоский скрипт открывается в редакторе', () {
      expect(scriptEditorPath('scripts/flow.json'), 'scripts/flow.json');
      expect(scriptEditorPath('scripts/boot.lua'), 'scripts/boot.lua');
    });

    test('вложенные папки и чужие пути не адресуются', () {
      expect(scriptEditorPath('scripts/group/flow.json'), isNull);
      expect(scriptEditorPath('res/scripts/x.json'), isNull);
      expect(scriptEditorPath(''), isNull);
      expect(scriptEditorPath(null), isNull);
    });
  });
}
