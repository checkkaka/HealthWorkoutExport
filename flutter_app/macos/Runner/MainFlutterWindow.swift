import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    KeychainPlugin.register(with: flutterViewController.registrar(forPlugin: "KeychainPlugin"))
    PreferencesPlugin.register(
      with: flutterViewController.registrar(forPlugin: "PreferencesPlugin"))
    ThirdPartyVaultPlugin.register(
      with: flutterViewController.registrar(forPlugin: "ThirdPartyVaultPlugin"))
    SyncFilesPlugin.register(with: flutterViewController.registrar(forPlugin: "SyncFilesPlugin"))
    HealthKitPlugin.register(with: flutterViewController.registrar(forPlugin: "HealthKitPlugin"))
    StravaOAuthPlugin.register(
      with: flutterViewController.registrar(forPlugin: "StravaOAuthPlugin"))
    StravaWebPlugin.register(with: flutterViewController.registrar(forPlugin: "StravaWebPlugin"))
    FilesPlugin.register(with: flutterViewController.registrar(forPlugin: "FilesPlugin"))

    super.awakeFromNib()
  }
}
