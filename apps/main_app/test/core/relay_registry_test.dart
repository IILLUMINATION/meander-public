// Ретрансляторы в настройках: разбор адресов, включение, порядок.
//
// Порядок важен: свои ретрансляторы идут раньше встроенных, чтобы нагрузка
// уходила на сервер пользователя, а не на общий VPS проекта.
import 'package:canvas_app/core/services/relay_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final registry = RelayRegistry.instance;
  const builtIn = 'relay.builtin.example:8443';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    registry.resetForTests();
    RelayRegistry.builtInOverride = [builtIn];
  });

  tearDown(() {
    registry.resetForTests();
  });

  group('parse', () {
    test('принимает host:port и обрезает пробелы', () {
      expect(RelayRegistry.parse('1.2.3.4:8443'), '1.2.3.4:8443');
      expect(
        RelayRegistry.parse(' tunnel.example.com:443 '),
        'tunnel.example.com:443',
      );
    });

    test('отвергает схему, путь, пустой и нечисловой порт', () {
      expect(RelayRegistry.parse('https://1.2.3.4:8443'), isNull);
      expect(RelayRegistry.parse('1.2.3.4:8443/x'), isNull);
      expect(RelayRegistry.parse('1.2.3.4'), isNull);
      expect(RelayRegistry.parse(':8443'), isNull);
      expect(RelayRegistry.parse('1.2.3.4:'), isNull);
      expect(RelayRegistry.parse('1.2.3.4:0'), isNull);
      expect(RelayRegistry.parse('1.2.3.4:70000'), isNull);
      expect(RelayRegistry.parse('1.2.3.4:abc'), isNull);
      expect(RelayRegistry.parse('   '), isNull);
      expect(RelayRegistry.parse(null), isNull);
    });
  });

  test('свои ретрансляторы идут раньше встроенных, без дубликатов', () async {
    await registry.ensureLoaded();
    expect(registry.all, [builtIn]);

    expect(await registry.addCustom('mine.example:9443'), 'mine.example:9443');
    expect(await registry.addCustom('mine.example:9443'), 'mine.example:9443');
    expect(registry.all, ['mine.example:9443', builtIn]);

    // Пользователь может вписать и встроенный: дубликат не появляется.
    await registry.addCustom(builtIn);
    expect(registry.all, ['mine.example:9443', builtIn]);
    expect(registry.custom, ['mine.example:9443', builtIn]);
  });

  test('некорректный адрес не сохраняется', () async {
    expect(await registry.addCustom('https://bad:1'), isNull);
    expect(registry.all, [builtIn]);
  });

  test('выключенный ретранслятор не попадает в enabled, но остаётся в all',
      () async {
    await registry.addCustom('mine.example:9443');
    await registry.setEnabled('mine.example:9443', false);

    expect(registry.all, ['mine.example:9443', builtIn]);
    expect(registry.enabled, [builtIn]);
    expect(registry.isEnabled('mine.example:9443'), isFalse);

    await registry.setEnabled('mine.example:9443', true);
    expect(registry.enabled, ['mine.example:9443', builtIn]);
  });

  test('состояние переживает перезапуск', () async {
    await registry.addCustom('mine.example:9443');
    await registry.setEnabled(builtIn, false);

    registry.resetForTests();
    RelayRegistry.builtInOverride = [builtIn];
    await registry.ensureLoaded();

    expect(registry.all, ['mine.example:9443', builtIn]);
    expect(registry.enabled, ['mine.example:9443']);
  });

  test('удаление своего ретранслятора возвращает его в состояние «включён»',
      () async {
    await registry.addCustom('mine.example:9443');
    await registry.setEnabled('mine.example:9443', false);
    await registry.removeCustom('mine.example:9443');

    expect(registry.all, [builtIn]);
    expect(registry.isEnabled('mine.example:9443'), isTrue);
  });

  test('встроенный определяется как встроенный', () async {
    await registry.addCustom('mine.example:9443');
    expect(registry.isBuiltIn(builtIn), isTrue);
    expect(registry.isBuiltIn('mine.example:9443'), isFalse);
  });

  test('probeAll проверяет все, включая выключенные', () async {
    await registry.addCustom('mine.example:9443');
    await registry.setEnabled(builtIn, false);
    RelayRegistry.probeHook = (endpoint) async => endpoint == builtIn;

    final results = await registry.probeAll();
    expect(results, {'mine.example:9443': false, builtIn: true});
  });
}