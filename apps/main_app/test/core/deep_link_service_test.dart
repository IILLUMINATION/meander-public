import 'package:canvas_app/core/services/deep_link_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Ссылка на наш же хост, которая не является маршрутом приложения, обязана
// уезжать в браузер: раньше такой тап молча исчезал.
void main() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');

  List<MethodCall> setUpLauncher(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    return calls;
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Меню')),
      ),
    );
  }

  testWidgets('ссылка на сайт внутри поста открывается снаружи', (
    tester,
  ) async {
    final calls = setUpLauncher(tester);
    await pumpApp(tester);

    DeepLinkService().openUrl('https://meander.illuminat.dev/pricing');
    await tester.pumpAndSettle();

    final launched = calls
        .where((c) => c.method == 'launch')
        .map((c) => (c.arguments as Map)['url'])
        .toList();
    expect(launched, ['https://meander.illuminat.dev/pricing']);
  });

  testWidgets('чужая meander-схема в браузер не уезжает', (tester) async {
    final calls = setUpLauncher(tester);
    await pumpApp(tester);

    DeepLinkService().openUrl('meander://settings');
    await tester.pumpAndSettle();

    expect(calls.where((c) => c.method == 'launch'), isEmpty);
  });
}
