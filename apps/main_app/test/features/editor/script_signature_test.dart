import 'package:canvas_app/features/editor/screens/visual_script_editor/block_models.dart';
import 'package:canvas_app/features/editor/screens/visual_script_editor/script_signature.dart';
import 'package:flutter_test/flutter_test.dart';

/// Сигнатура автосейва обязана меняться от правки **содержимого** блока.
///
/// Регресс: сигнатура считалась по имени и id блоков, поэтому смена значения
/// (`value` у присвоения, `source` у смены картинки) не делала скрипт грязным —
/// автосейв молчал, и правка терялась при выходе с экрана.
void main() {
  EventBlock makeScript({String value = '0', String source = ''}) {
    return EventBlock(
      id: 'ev-1',
      eventType: EventType.onDataChange,
      watchPaths: ['Оружие'],
      children: [
        AssignVariableBlock(id: 'a-1', variableName: 'Урон', value: value),
        SetImageBlock(id: 'i-1', itemId: 'item-1', source: source),
      ],
    );
  }

  String signatureOf(EventBlock block) =>
      scriptSignatureOf(name: 'G_Оружие', blocks: [block]);

  test('правка значения делает сигнатуру другой', () {
    final block = makeScript(value: '0');

    final before = signatureOf(block);
    block.children.whereType<AssignVariableBlock>().single.value =
        '{{Оружие["Урон"][Оружие]}}';

    expect(signatureOf(block), isNot(before));
  });

  test('правка источника картинки делает сигнатуру другой', () {
    final block = makeScript(source: 'res/images/a.webp');

    final before = signatureOf(block);
    block.children.whereType<SetImageBlock>().single.source =
        '{{Оружие["Картинка"][Оружие]}}';

    expect(signatureOf(block), isNot(before));
  });

  test('правка подписки события делает сигнатуру другой', () {
    final block = makeScript();

    final before = signatureOf(block);
    block.watchPaths.add('Урон');

    expect(signatureOf(block), isNot(before));
  });

  test('одинаковое содержимое даёт одинаковую сигнатуру', () {
    expect(signatureOf(makeScript(value: '5')), signatureOf(makeScript(value: '5')));
  });

  test('добавление блока делает сигнатуру другой', () {
    final block = makeScript();
    final before = signatureOf(block);

    block.children.add(
      AssignVariableBlock(id: 'a-2', variableName: 'HP', value: '50'),
    );

    expect(signatureOf(block), isNot(before));
  });
}