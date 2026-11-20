import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    NSLog("[Meander] application didFinishLaunching")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Плагины регистрируются на движке, который создаёт сцена, а не на
  /// `self`: под UIScene-жизненным циклом движок появляется позже
  /// `didFinishLaunchingWithOptions`, и регистрация в нём же дала бы
  /// второй движок без плагина.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    NSLog("[Meander] didInitializeImplicitFlutterEngine")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NSLog("[Meander] GeneratedPluginRegistrant registered")
  }
}
