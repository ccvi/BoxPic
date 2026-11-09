import AppKit

// 入口。
//
// --selftest：跑应用内自检（打包脚本拿它当门禁），结果打到 stdout，退出码即结论。
// 其余情况正常启动 GUI。
//
// 注意：绝不通过 exec .app/Contents/MacOS/BoxPic 来做验证 —— macOS 26 上那样做
// 会让 bundle 的 LaunchServices 登记失效。要验就走 .build 下的裸产物。

let arguments = CommandLine.arguments

// --compare-probe <源图> <输出.png> [质量]：把「预估 → 合成对比图」整条链路跑一遍并落盘。
// 用来排查「对比视图看不出压缩劣化」这类只发生在界面上的问题：
// 如果这里 dump 出来的图左右差异明显、界面上却没有，那问题就在渲染，不在这条链路。
if let probeIndex = arguments.firstIndex(of: "--compare-probe") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let rest = Array(arguments.dropFirst(probeIndex + 1))
        guard rest.count >= 2 else {
            print("用法：--compare-probe <源图> <输出.png> [质量]")
            exit(2)
        }
        let source = URL(fileURLWithPath: rest[0])
        let output = URL(fileURLWithPath: rest[1])
        let quality = rest.count >= 3 ? (Double(rest[2]) ?? 0.05) : 0.05
        exit(SelfTest.compareProbe(source: source, output: output, quality: quality) ? 0 : 1)
    }
}

if arguments.contains("--selftest") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared        // AppKit 先初始化，NSImage / NSGraphicsContext 才可用
        exit(SelfTest.run() ? 0 : 1)
    }
}

if arguments.contains("--version") {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        ?? (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "unknown"
    print("BoxPic \(version)")
    exit(0)
}

@MainActor
private func startApplication() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    // NSApplication.delegate 是 weak，这里必须自己握住，否则窗口刚建好就跟着 delegate 一起走
    objc_setAssociatedObject(app, "boxpic.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
    exit(0)
}

MainActor.assumeIsolated { startApplication() }
