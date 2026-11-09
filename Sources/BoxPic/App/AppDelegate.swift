import AppKit
import SwiftUI

// MARK: - 应用委托

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = AppModel()
    private var window: NSWindow?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注册服务提供者，NSServices 声明的「在 BoxPic 中打开」才会真的被调用
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        buildMenu()
        buildWindow()
        if !pendingURLs.isEmpty {
            model.add(urls: pendingURLs)
            pendingURLs.removeAll()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 双击图片 / 拖到 Dock 图标 / Finder 扩展转发，都从这里进来
    func application(_ application: NSApplication, open urls: [URL]) {
        guard window != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        model.previewID = nil
        model.add(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: 服务（右键菜单）

    /// 对应 Info.plist 里 NSServices 的 NSMessage = openImageInBoxPic。
    /// 签名必须严格是这个形态，否则系统不会把服务派发进来。
    @objc func openImageInBoxPic(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            error?.pointee = "没有读到文件" as NSString
            return
        }
        model.previewID = nil
        model.add(urls: urls)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: 窗口

    private func buildWindow() {
        let hosting = NSHostingView(rootView: MainView().environmentObject(model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BoxPic"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.039, green: 0.039, blue: 0.039, alpha: 1)
        window.minSize = NSSize(width: 900, height: 620)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("BoxPicMainWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 BoxPic", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BoxPic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 BoxPic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 文件
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        let openItem = fileMenu.addItem(withTitle: "添加图片…", action: #selector(openFiles), keyEquivalent: "o")
        openItem.target = self
        let resetItem = fileMenu.addItem(withTitle: "重新转换", action: #selector(resetResults), keyEquivalent: "r")
        resetItem.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 编辑（没有这一段，输入框里 ⌘C/⌘V 全失效）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func openFiles() {
        model.presentOpenPanel()
    }

    @objc private func resetResults() {
        model.resetResults()
    }

    @objc private func showAbout() {
        // 关于面板只负责把 credits 整块居中放，块内每一行默认还是左对齐 ——
        // 必须显式给段落样式，否则「图像格式转换工具 / 作者 / 邮箱」会顶着左边
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "图像格式转换工具\n\n作者：ccvi1223\n邮箱：ccvi1223@qq.com",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
