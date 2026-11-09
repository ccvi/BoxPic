import Foundation
import CoreGraphics
import ImageIO

// MARK: - JPEG XL 输出
//
// macOS 26 的 ImageIO **能读不能写** JXL：
//   · CGImageSourceCopyTypeIdentifiers() 里有 public.jpeg-xl（解码没问题）
//   · CGImageDestinationCopyTypeIdentifiers() 只有 22 种，没有任何 jxl
//   · 直接拿 "public.jpeg-xl" / "org.iso.jpeg-xl" 去建 CGImageDestination，一律返回 nil
//   · sips -s format jxl 也是打印了目标路径却不写文件
//
// 所以输出只能走外部 cjxl，和 EPS 靠 Ghostscript 是同一个套路：
// 运行时探测，有就用，没有就把话说清楚。
//
// 打包时会把 cjxl 和它依赖的 12 个 dylib 一起放进 BoxPic.app
// （Contents/MacOS/cjxl + Contents/Frameworks/*.dylib，路径已改写成 @executable_path
//  和 @loader_path，不再依赖 Homebrew），所以正常用户拿到 dmg 就能直接出 JXL。
// 下面这个顺序是「先包内、后系统装」，包内的优先。

enum JXLEncoder {

    /// cjxl 的查找顺序：包内 → Homebrew/常见目录 → PATH
    static func toolPath() -> String? {
        // 1. 包内（同目录下就是 Contents/MacOS/cjxl）
        if let exec = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundled = exec.appendingPathComponent("cjxl").path
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        // 2. 系统安装的
        let fixed = [
            "/opt/homebrew/bin/cjxl",
            "/usr/local/bin/cjxl",
            "/opt/local/bin/cjxl",
            "/usr/bin/cjxl"
        ]
        if let hit = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/cjxl"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var isAvailable: Bool { toolPath() != nil }

    /// 编码成 JXL 字节。
    /// cjxl 只吃 PNG / PNM / PFM / JPEG，所以先落一张临时 PNG 让它读。
    static func encode(_ image: CGImage, quality: Double, name: String) throws -> Data {
        guard let tool = toolPath() else {
            throw ImageEngineError.needsJXLTool(name)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxpic-jxl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("in.png")
        let target = dir.appendingPathComponent("out.jxl")

        // 先写 PNG 交给 cjxl。用无损 PNG，免得在编码前先被压一次
        guard let dest = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil) else {
            throw ImageEngineError.encodeFailed("JPG XL")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageEngineError.encodeFailed("JPG XL")
        }

        // -q 100 是 cjxl 的无损档；把 0…1 的滑块直接映射到 0…100
        let q = Int((min(max(quality, 0.01), 1.0) * 100).rounded())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [source.path, target.path, "-q", String(q)]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            throw ImageEngineError.encodeFailed("JPG XL")
        }
        if done.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            throw ImageEngineError.encodeTimeout(name)
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: target), !data.isEmpty else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ImageEngineError.postScriptFailed(name, message.isEmpty ? "cjxl 没有产出文件" : message)
        }
        return data
    }
}
