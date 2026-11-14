import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 原生通道要一直活着，否则 Flutter 侧调用会掉回 MissingPlugin。
  private var bridge: XiaojiBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 桌面端窗口习惯：给一个能放下「列表 + 正文」的最小尺寸，
    // 再记住上次的位置和大小（用户下次打开不用重新摆）。
    self.minSize = NSSize(width: 560, height: 480)
    self.setFrameAutosaveName("XiaojiMainWindow")
    self.title = "小记"
    // 列表是主体内容，标题栏不做全透明，避免拖动窗口时内容穿帮。
    self.titlebarAppearsTransparent = false

    RegisterGeneratedPlugins(registry: flutterViewController)
    bridge = XiaojiBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
