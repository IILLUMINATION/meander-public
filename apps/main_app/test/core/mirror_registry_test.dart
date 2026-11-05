// Тесты перебора зеркал: нормализация адреса, порядок зеркал,
// пользовательское зеркало, маркер все-зеркала-недоступны и текст ошибки.
import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/core/services/mirror_registry.dart';
import 'package:canvas_app/core/utils/error_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // SharedPreferences.setMockInitialValues чистит хранилище перед
    // каждым тестом: активное зеркало каждого теста начинает с дефолта.
    SharedPreferences.setMockInitialValues({});
  });

  test('normalizeForPreview: добавляет https, срезает хвостовые слэши',
      () async {
    expect(
      MirrorRegistry.normalizeForPreview('example.com'),
      'https://example.com',
    );
    expect(
      MirrorRegistry.normalizeForPreview('https://example.com/'),
      'https://example.com',
    );
    expect(MirrorRegistry.normalizeForPreview('  '), isNull);
    expect(MirrorRegistry.normalizeForPreview('http://'), isNull);
    expect(MirrorRegistry.normalizeForPreview(null), isNull);
  });

  test('активное зеркало по умолчанию — основной домен', () async {
    expect(AppConfig.apiUrl, AppConfig.vpsApiBaseUrl);
  });

  test('своё зеркало попадает в список первым', () async {
    await MirrorRegistry.instance.setCustomUrl('https://my.server');
    final urls = MirrorRegistry.instance.allUrls;
    expect(urls.first, 'https://my.server',
        reason: 'пользовательское зеркало приоритетнее после установки');
    expect(
      urls,
      containsAll([
        AppConfig.vpsApiBaseUrl,
        'https://meander.elitrycraft.workers.dev',
      ]),
      reason: 'встроенные зеркала остаются в переборе',
    );
  });

  test(
      'все зеркала недоступны, но срок жив: ensureReachable с выключенным '
      'зондом считает их живыми и сохраняет активным',
      () async {
    MirrorRegistry.skipRealNetwork = true;
    addTearDown(() => MirrorRegistry.skipRealNetwork = false);
    final ok = await MirrorRegistry.instance.ensureReachable();
    expect(ok, isTrue);
  });

  test('сброс своего зеркала возвращает активным основной домен',
      () async {
    await MirrorRegistry.instance.setCustomUrl('https://my.server');
    await MirrorRegistry.instance.setCustomUrl(null);
    expect(MirrorRegistry.instance.activeUrl, AppConfig.vpsApiBaseUrl);
  });

  test(
      'все зеркала недоступны — friendlyError формулирует через '
      '«ускоритель интернета», без запрещённых терминов',
      () async {
    final text = friendlyError(
      Exception(MirrorRegistry.allMirrorsDownMarker),
    );
    expect(text, contains('ускорител'));
    expect(text, contains('зеркало'));
    // Термин VPN в интерфейсе нельзя упоминать.
    expect(text.toLowerCase(), isNot(contains('vpn')));
  });

  test('обычные сетевые ошибки не превращаются в сообщение про зеркала',
      () async {
    final text = friendlyError(Exception('SERVER_MAINTENANCE'));
    expect(text, contains('обслуживании'));
  });
}
