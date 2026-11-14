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
    // 沉浸式窗口：标题栏透明、内容延伸到标题栏区域，红黄绿三个按钮浮在
    // 应用自己的顶栏之上（Bear / Notion / 语雀桌面版的做法）。Dart 侧为
    // 这三个按钮预留了 28 的顶部安全区（见 main.dart）。
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)
    bridge = XiaojiBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
