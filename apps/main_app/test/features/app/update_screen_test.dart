import 'package:canvas_app/core/config.dart';
import 'package:canvas_app/features/app/screens/update_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// На тестовом VM (Linux-десктоп) `Platform.isAndroid == false`, поэтому
/// здесь проверяется десктопная/«прочие платформы» ветка: она целиком
/// зависит от ссылки, которую прислал сервер.
Widget _wrap(UpdateScreen screen) => MaterialApp(home: screen);

void main() {
  testWidgets('без ссылки обязательное обновление не превращается в ловушку', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const UpdateScreen(
          version: '2.9.0',
          changelog: '• исправлено всё',
          downloadUrl: '',
          isCritical: true,
        ),
      ),
    );

    // До правки: «Позже» не показывалось, «Скачать» молча ничего не делала,
    // PopScope блокировал выход — пользователь оставался заперт на экране.
    expect(find.text('Позже'), findsOneWidget);

    await tester.tap(find.text('Скачать'));
    await tester.pump();

    expect(
      find.text(
        'Ссылка на загрузку не задана — зайдите на ${AppConfig.siteHost}',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('мусорная ссылка вместо адресата — то же безопасное поведение', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const UpdateScreen(
          version: '2.9.0',
          changelog: '',
          downloadUrl: 'meander.illuminat.dev/apk',
          isCritical: true,
        ),
      ),
    );

    expect(find.text('Позже'), findsOneWidget);
    await tester.tap(find.text('Скачать'));
    await tester.pump();
    expect(find.textContaining('Ссылка'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'с рабочей ссылкой обязательное обновление по-прежнему не закрыть',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const UpdateScreen(
            version: '2.9.0',
            changelog: '',
            downloadUrl: 'https://meander.illuminat.dev',
            isCritical: true,
          ),
        ),
      );

      expect(find.text('Позже'), findsNothing);
    },
  );
}
