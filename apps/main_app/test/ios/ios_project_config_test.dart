import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Конфиг iOS-проекта — то, из-за чего сборку отклоняет модерация App Store и
/// из-за чего она не собирается вообще на свежем клоне.
///
/// Тест читаёт файлы как текст: `plutil`/Xcode на Linux недоступны, а проверять
/// нужно именно то, что уйдёт в архив.
void main() {
  final iosDir = Directory('ios');
  if (!iosDir.existsSync()) {
    // Тест запускается из корня apps/main_app.
    throw StateError('Запустите тест из apps/main_app: flutter test test/ios');
  }

  String read(String rel) => File('ios/$rel').readAsStringSync();

  group('Info.plist: приватность и имя', () {
    final plist = read('Runner/Info.plist');

    test('нет следа старого имени Canvas App / canvas_app', () {
      expect(plist, isNot(contains('Canvas App')));
      expect(plist, isNot(contains('<string>canvas_app</string>')));
    });

    test('объявлено назначение доступа к фотогалерее (ITMS-90683)', () {
      final match = RegExp(
        '<key>NSPhotoLibraryUsageDescription</key>\\s*<string>(.+?)</string>',
      ).firstMatch(plist);
      expect(match, isNotNull, reason: 'image_picker берёт фото из галереи');
      expect(match!.group(1)!.trim().length, greaterThan(20));
    });

    test('заявлено, что шифрование вне исключений не используется', () {
      expect(
        RegExp(
          '<key>ITSAppUsesNonExemptEncryption</key>\\s*<false/>',
        ).hasMatch(plist),
        isTrue,
        reason: 'без ключа TestFlight требует ручной ответ по экспорту',
      );
    });

    test('камера, микрофон и ATT не запрошены — их в приложении нет', () {
      for (final key in [
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSUserTrackingUsageDescription',
        'NSLocalNetworkUsageDescription',
      ]) {
        expect(plist, isNot(contains(key)));
      }
    });
  });

  group('PrivacyInfo.xcprivacy', () {
    final file = File('ios/Runner/PrivacyInfo.xcprivacy');

    test('лежит в Runner и попадает в Resources', () {
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('NSPrivacyAccessedAPITypes'));
      expect(content, contains('NSPrivacyAccessedAPICategoryUserDefaults'));
      expect(content, contains('CA92.1'));
      expect(content, contains('NSPrivacyAccessedAPICategoryFileTimestamp'));
      expect(content, contains('NSPrivacyAccessedAPICategoryDiskSpace'));
      expect(content, contains('<key>NSPrivacyTracking</key>\n\t<false/>'));
    });

    test('причины соответствуют тому, что код реально делает', () {
      final content = file.readAsStringSync();
      // file_picker открывает выбранные пользователем файлы → 3B52.1.
      expect(content, contains('3B52.1'));
      // Пишем файлы квеста в контейнер → E174.1. 85F4.1 означало бы «показываем
      // пользователю свободное место», а такого экрана в приложении нет.
      expect(content, contains('E174.1'));
      expect(content, isNot(contains('85F4.1')));
      // Таймеры автосохранения и замеры интервалов → SystemBootTime/35F9.1.
      expect(content, contains('NSPrivacyAccessedAPICategorySystemBootTime'));
      expect(content, contains('35F9.1'));
    });

    test('приложен к цели сборки Runner', () {
      final pbx = read('Runner.xcodeproj/project.pbxproj');
      expect(pbx, contains('PrivacyInfo.xcprivacy in Resources'));
      expect(pbx, contains('path = PrivacyInfo.xcprivacy'));
    });
  });

  group('Sign in with Apple', () {
    test('entitlements объявляют applesignin', () {
      final file = File('ios/Runner/Runner.entitlements');
      expect(file.existsSync(), isTrue);
      expect(
        file.readAsStringSync(),
        contains('com.apple.developer.applesignin'),
      );
    });

    test('все три конфигурации Runner используют entitlements', () {
      final pbx = read('Runner.xcodeproj/project.pbxproj');
      expect(
        'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'
            .allMatches(pbx)
            .length,
        3,
        reason: 'Debug/Profile/Release — иначе архив соберётся без SIWA',
      );
    });
  });

  group('минимальная версия iOS', () {
    test('13.0 нигде не осталось', () {
      expect(read('Podfile'), contains("platform :ios, '15.0'"));
      final pbx = read('Runner.xcodeproj/project.pbxproj');
      expect(pbx, isNot(contains('IPHONEOS_DEPLOYMENT_TARGET = 13.0')));
      expect('IPHONEOS_DEPLOYMENT_TARGET = 15.0;'.allMatches(pbx).length, 3);
      expect(
        read('Flutter/AppFrameworkInfo.plist'),
        contains('<string>15.0</string>'),
      );
    });
  });

  group('OAuth-дефолты iOS', () {
    test('Debug/Release подключают дефолты до локального оверрайда', () {
      for (final name in [
        'Flutter/Debug.xcconfig',
        'Flutter/Release.xcconfig',
      ]) {
        final cfg = read(name);
        final defaults = cfg.indexOf('OAuthDefaults.xcconfig');
        final local = cfg.indexOf('OAuth.xcconfig"');
        expect(defaults, greaterThan(0), reason: '$name: сборка без .env');
        expect(
          local,
          greaterThan(defaults),
          reason: '$name: локальный OAuth.xcconfig должен быть главнее',
        );
      }
    });

    test('дефолты заполнены — иначе Google Sign-In не стартует', () {
      final defaults = read('Flutter/OAuthDefaults.xcconfig');
      for (final key in [
        'GOOGLE_IOS_CLIENT_ID',
        'GOOGLE_IOS_REVERSED_CLIENT_ID',
        'GOOGLE_MOBILE_SERVER_CLIENT_ID',
        'YANDEX_CLIENT_ID',
      ]) {
        expect(
          RegExp('^$key=.+', multiLine: true).hasMatch(defaults),
          isTrue,
          reason: '$key пуст — кнопка входа отключится',
        );
      }
    });
  });

  group('Rust-ядро в iOS-сборке', () {
    test('framework не закоммичен, а собирается фейзом', () {
      expect(
        read('.gitignore'),
        contains('Runner/Frameworks/libmnd_ffi.framework/'),
      );
      final pbx = read('Runner.xcodeproj/project.pbxproj');
      expect(pbx, contains('ios_ffi_phase.sh'));
      // Фейз обязан идти до Sources: линковка со статикой happens там.
      expect(
        pbx.indexOf(
          'Build Rust core (mnd-ffi) */,\n\t\t\t\t97C146EA1CF9000F007C117D',
        ),
        greaterThan(0),
      );
      expect(File('../../scripts/ios_ffi_phase.sh').existsSync(), isTrue);
    });
  });

  group('Старт на iPhone', () {
    test('фон launch-экрана совпадает с дефолтной тёмной темой', () {
      // Приложение открывается в ThemeMode.dark, surface = #181306. Белый
      // LaunchScreen давал вспышку белым экраном перед тёмным сплэшем.
      final sb = read('Runner/Base.lproj/LaunchScreen.storyboard');
      expect(sb, isNot(contains('red="1" green="1" blue="1"')));
      expect(sb, contains('red="0.09411764705882353"'));
    });

    test('фоновый режим audio не заявлен', () {
      // Guideline 2.5.4: заявленный фоновый audio без слышимого звука в фоне
      // приводит к отказу. Музыка квеста играет только в активном окне.
      final plist = read('Runner/Info.plist');
      expect(plist, isNot(contains('<key>UIBackgroundModes</key>')));
      expect(plist, isNot(contains('<string>audio</string>')));
    });
  });

  group('Жизненный цикл сцен (iOS 27)', () {
    // iOS 27 роняет приложение, которое не объявило UISceneDelegate:
    // EXC_BREAKPOINT в ___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption,
    // экран не появляется вообще (отклон 2.8.14(270) по 2.1(a)).
    final plist = read('Runner/Info.plist');

    test('Info.plist объявляет UIApplicationSceneManifest', () {
      final at = plist.indexOf('<key>UIApplicationSceneManifest</key>');
      expect(at, greaterThan(0), reason: 'без манифеста iOS 27 крашит старт');
      final block = plist.substring(at, at + 1200);
      expect(block, contains('<key>UIWindowSceneSessionRoleApplication</key>'));
      // Одна сцена: редактор и плеер живут в одном окне, мультиоконность
      // потребовала бы состояния на каждую сцену.
      expect(
        block,
        contains(
          '<key>UIApplicationSupportsMultipleScenes</key>\n\t\t<false/>',
        ),
      );
      expect(
        block,
        contains(
          '<key>UISceneDelegateClassName</key>\n\t\t\t\t\t<string>'
          r'$(PRODUCT_MODULE_NAME).SceneDelegate'
          '</string>',
        ),
        reason: 'делегат обязан быть наш, SceneDelegate.swift, а не дефолтный',
      );
      expect(
        block,
        contains(
          '<key>UISceneStoryboardFile</key>\n\t\t\t\t\t<string>Main</string>',
        ),
      );
      expect(
        RegExp(
          '<key>UIMainStoryboardFile</key>\\s*<string>(.+?)</string>',
        ).firstMatch(plist)!.group(1),
        'Main',
        reason: 'сториборд сцены и корневой сториборд — один и тот же файл',
      );
    });

    test(
      'SceneDelegate subclass-ит FlutterSceneDelegate и не теряет чужие URL',
      () {
        final file = File('ios/Runner/SceneDelegate.swift');
        expect(file.existsSync(), isTrue);
        final src = file.readAsStringSync();
        expect(src, contains('class SceneDelegate: FlutterSceneDelegate'));
        expect(src, contains('openURLContexts'));
        // Yandex Login приходит по схеме yx… и сам умеет только
        // application(_:open:) — под сценами его зовём мы.
        expect(src, contains('YandexLoginSdkPlugin.handle(openURL:'));
        // Остальные контексты обязаны дойти до плагинов (app_links, supabase).
        expect(src, contains('super.scene(scene, openURLContexts:'));
        expect(
          read('Runner.xcodeproj/project.pbxproj'),
          contains('SceneDelegate.swift in Sources'),
          reason: 'файл вне цели сборки — класс не найдётся в рантайме',
        );
      },
    );

    test('плагины регистрируются на движке сцены, а не на AppDelegate', () {
      final src = read('Runner/AppDelegate.swift');
      expect(src, contains('FlutterImplicitEngineDelegate'));
      expect(src, contains('didInitializeImplicitFlutterEngine'));
      expect(
        src,
        contains(
          'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)',
        ),
      );
      expect(
        src,
        isNot(contains('GeneratedPluginRegistrant.register(with: self)')),
        reason:
            'самописный движок AppDelegate под сценами остаётся без плагинов',
      );
      // application(_:open:) под сценным циклом не вызывается — вся URL-
      // логика обязана жить в SceneDelegate, иначе вход Яндекса молча умрёт.
      expect(src, isNot(contains('open url: URL')));
    });
  });
}
