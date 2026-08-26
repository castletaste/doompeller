import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var doomAudioBackend: DoomAudioBackend?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    doomAudioBackend = DoomAudioBackend(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}
