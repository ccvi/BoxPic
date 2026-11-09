import Foundation
import CoreGraphics
import ImageIO

// MARK: - EPS / PostScript 输入
//
// macOS 26 自带的东西里**没有任何 PostScript 解释器**，四条路都试过：
//   · ImageIO：CGImageSourceCreateWithURL 对 .eps 返回 count = 0
//   · NSImage(data:)：直接返回 nil
//   · CGPSConverter（CoreGraphics 里的老 API）：dlsym 调得到，Convert 返回 true，
//     但产出 0 字节 —— 只剩个空壳；而且它在 Swift 里已被标成 obsoleted
//   · cupsfilter / sips：一个报「无滤镜可从 application/postscript 转换」，一个静默失败
//
// 所以只能外部渲染。Ghostscript 是事实标准，本机 brew 装的一般在 /opt/homebrew/bin/gs。
// 这里做成运行时探测：装了就能转，没装就给一句明确的话，而不是让用户对着
// 「不支持的格式」发呆。

enum PostScript {

    /// 我们认的 PostScript 家族扩展名
    static let extensions: Set<String> = ["eps", "epsf", "ps"]

    /// 找 Ghostscript 可执行文件。先看常见安装位置，再退到 PATH。
    static func ghostscriptPath() -> String? {
        let fixed = [
            "/opt/homebrew/bin/gs",
            "/usr/local/bin/gs",
            "/opt/local/bin/gs",
            "/usr/bin/gs",
            "/Library/TeX/texbin/gs"
        ]
        if let hit = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/gs"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var isAvailable: Bool { ghostscriptPath() != nil }

    /// 解析 %%BoundingBox / %%HiResBoundingBox（单位 pt），算出按目标像素渲染时该用多少 dpi。
    /// 只读文件头，不渲染 —— 网格里的「原始尺寸」靠它，不必为了量尺寸先跑一遍 gs。
    static func plan(url: URL, maxPixel: Int) -> (dpi: Int, pixel: CGSize) {
        let box = boundingBox(url: url)
        let wPt = max(1, box.width)
        let hPt = max(1, box.height)
        let longest = max(wPt, hPt)
        // dpi 取整到 1，保证 plan 与实际渲染出来的像素数一致
        let dpi = min(max(Int((Double(maxPixel) * 72.0 / Double(longest)).rounded()), 36), 2400)
        let pixel = CGSize(width: max(1, (Double(wPt) * Double(dpi) / 72.0).rounded()),
                           height: max(1, (Double(hPt) * Double(dpi) / 72.0).rounded()))
        return (dpi, pixel)
    }

    /// 用 Ghostscript 把 EPS 光栅化成 CGImage。
    /// `png16m` 是白底设备 —— EPS 的「背景」本来就是纸，白底比透明更贴近它该有的样子，
    /// 也避免转 JPEG 时透明区被写成黑块。
    static func render(url: URL, maxPixel: Int) throws -> CGImage {
        guard let gs = ghostscriptPath() else {
            throw ImageEngineError.needsGhostscript(url.lastPathComponent)
        }
        let (dpi, _) = plan(url: url, maxPixel: maxPixel)
        let ext = url.pathExtension.lowercased()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxpic-ps-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        var args = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER",
                    "-sDEVICE=png16m",
                    "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4",
                    "-r\(dpi)",
                    "-sOutputFile=\(out.path)"]
        // EPS 要按自己的 BoundingBox 裁页面；裸 .ps 有固定纸张，不能裁
        if ext != "ps" { args.append("-dEPSCrop") }
        args.append(url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gs)
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            throw ImageEngineError.decodeFailed(url.lastPathComponent)
        }
        // 坏文件可能让 gs 卡住（复杂 PS 会跑很久），30 秒还没完就掐掉
        if done.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            throw ImageEngineError.postScriptTimeout(url.lastPathComponent)
        }

        guard let source = CGImageSourceCreateWithURL(out as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              // 🔴 必须立刻解码进内存：这个临时 PNG 在函数返回时就被 defer 删掉了，
              //    而 CGImageSourceCreateImageAtIndex 默认是懒加载的 ——
              //    不带上这个 key，返回出去的 CGImage 是一张「文件已经不在了」的空图，
              //    后面画出来全黑（自检里就是这么发现平均色是 0,0,0 的）。
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ImageEngineError.postScriptFailed(url.lastPathComponent, message.isEmpty ? "gs 没有产出图像" : message)
        }
        return image
    }

    /// 从文件头找 BoundingBox；找不到就退回 A4（595×842 pt）。
    private static func boundingBox(url: URL) -> CGSize {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return CGSize(width: 595, height: 842)
        }
        defer { try? handle.close() }
        // BoundingBox 一定在开头的注释区，读 16 KB 足够
        let data = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .isoLatin1) else {
            return CGSize(width: 595, height: 842)
        }
        func box(from key: String) -> CGSize? {
            for line in text.split(separator: "\n") where line.contains(key) {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" })
                    .compactMap { Double($0) }
                // 行内会有 4 个数字（llx lly urx ury），前面可能混进 key 本身，取最后四个
                guard parts.count >= 4 else { continue }
                let tail = parts.suffix(4)
                let w = tail[tail.startIndex + 2] - tail[tail.startIndex]
                let h = tail[tail.startIndex + 3] - tail[tail.startIndex + 1]
                if w > 0, h > 0 { return CGSize(width: w, height: h) }
            }
            return nil
        }
        if let hi = box(from: "HiResBoundingBox") { return hi }
        if let normal = box(from: "BoundingBox") { return normal }
        return CGSize(width: 595, height: 842)
    }
}
