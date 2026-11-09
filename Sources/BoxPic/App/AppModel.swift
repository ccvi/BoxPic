import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - 单个任务

enum TaskStatus: Equatable {
    case pending
    case running
    case done(url: URL, byteCount: Int64, pixel: CGSize, seconds: Double)
    case failed(String)

    var isDone: Bool { if case .done = self { return true }; return false }

    var outputURL: URL? {
        if case .done(let url, _, _, _) = self { return url }
        return nil
    }
}

/// 导入时按当前参数预跑一次编码得到的「转换后会多大」。
/// 走的是和真正转换完全相同的代码路径，所以数字就是最终值，不是抽样估算。
///
/// 这里**不存预览图**：对比视图要用时再按当前参数现渲一张。
/// 十几张图各挂一张 1400 px 的位图白占上百 MB，而对比视图一次只看一张。
struct Estimate {
    var bytes: Int64
    var pixel: CGSize
    /// 预计落盘的文件名（还没真生成，但对比视图要先把它显示出来）
    var outputName: String
}

struct PictureTask: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let originalBytes: Int64
    let originalPixel: CGSize
    var thumbnail: CGImage?
    /// 转换结果的小图（预览对比用）
    var afterThumbnail: CGImage?
    var status: TaskStatus = .pending
    /// 预估结果（还没真正落盘）
    var estimate: Estimate?
    /// 正在算预估
    var estimating: Bool = false

    /// 参考图里那一行「3.5 MB → 633 kB」。
    /// 还没点转换时用预估值（带 ≈），转换完成后换成真实值。
    var byteChange: (before: String, after: String, estimated: Bool)? {
        if case .done(_, let bytes, _, _) = status {
            return (Fmt.bytes(originalBytes), Fmt.bytes(bytes), false)
        }
        if let estimate {
            return (Fmt.bytes(originalBytes), Fmt.bytes(estimate.bytes), true)
        }
        return nil
    }

    /// 「4,000 × 3,000 → 2,000 × 1,500」
    var pixelChange: (before: String, after: String, estimated: Bool)? {
        if case .done(_, _, let pixel, _) = status {
            return (Fmt.pixels(originalPixel), Fmt.pixels(pixel), false)
        }
        if let estimate {
            return (Fmt.pixels(originalPixel), Fmt.pixels(estimate.pixel), true)
        }
        return nil
    }
}

// MARK: - 应用状态

@MainActor
final class AppModel: ObservableObject {

    @Published var tasks: [PictureTask] = []
    @Published var prefs: Preferences = {
        var loaded = Preferences.load()
        loaded.normalize()
        return loaded
    }() {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            // 参数一变，之前的转换结果和预估都不再成立 —— 全部作废重算，
            // 否则界面会拿旧参数的数字忽悠人
            invalidateResults()
            scheduleEstimates()
        }
    }
    @Published var previewID: UUID?
    @Published var isRunning = false
    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var lastError: String?
    @Published var toast: String?

    var previewTask: PictureTask? {
        guard let previewID else { return nil }
        return tasks.first { $0.id == previewID }
    }

    var doneCount: Int { tasks.filter { $0.status.isDone }.count }

    // MARK: 增删

    /// 加文件。去重按路径；打不开的先留着占位（缩略图 nil），转换时再报错。
    func add(urls: [URL]) {
        var existing = Set(tasks.map { $0.sourceURL.standardizedFileURL.path })
        var added = 0
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !existing.contains(path) else { continue }
            guard Formats.isSupportedInput(url) else { continue }
            existing.insert(path)

            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attrs?[.size] as? Int64) ?? 0
            let thumb = ImageEngine.loadThumbnail(url: url, maxPixel: 640)
            // 原始尺寸必须读真实像素：缩略图是 640 宽的光栅化结果，
            // 拿它当「之前」会显示 599×640 这种假尺寸（对比视图里一眼就露馅）
            let pixel = sourcePixelSize(url: url) ?? .zero

            tasks.append(PictureTask(sourceURL: url,
                                     originalBytes: bytes,
                                     originalPixel: pixel,
                                     thumbnail: thumb))
            added += 1
        }
        if added > 0 {
            lastError = nil
            // 拖进来就立刻按当前参数算「转换后多大」，不用等点执行
            scheduleEstimates(immediate: true)
        }
        // 导入后一律回到网格：刚拖进来的图还没转换，
        // 直接进对比视图既没内容可对比，也让人以为点错了
        if added > 0 { previewID = nil }
    }

    // MARK: 预估值

    private var estimateJob: Task<Void, Never>?

    /// 参数变了：所有已完成/预估结果作废
    func invalidateResults() {
        estimateJob?.cancel()
        for index in tasks.indices {
            if tasks[index].status.isDone { tasks[index].status = .pending }
            tasks[index].estimate = nil
            tasks[index].estimating = false
            tasks[index].afterThumbnail = nil
        }
        progress = (0, 0)
    }

    /// 只给「还没有预估值」的任务算。改了参数会先清空，所以等于全部重算。
    /// 串行跑（每张内部已是多线程），避免十几张大图同时解码把内存打爆。
    func scheduleEstimates(immediate: Bool = false) {
        estimateJob?.cancel()
        // 上一轮被取消时可能有任务停在 estimating=true 且没拿到结果。
        // 不先清掉的话，下面的过滤会永远跳过它们 —— 卡片就卡在「计算中…」再也不动。
        for index in tasks.indices where tasks[index].estimate == nil {
            tasks[index].estimating = false
        }
        let targets = tasks
            .filter { $0.estimate == nil && !$0.status.isDone }
            .map { ($0.id, $0.sourceURL) }
        guard !targets.isEmpty else { return }

        for (id, _) in targets {
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].estimating = true
            }
        }

        let options = prefs.convertOptions()
        estimateJob = Task { [options, targets] in
            if !immediate {
                // 拖质量条时别每一帧都重算，停手 350ms 再动
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if Task.isCancelled { return }
            for (id, url) in targets {
                if Task.isCancelled { return }
                let result = try? await Task.detached(priority: .utility) { () -> Estimate? in
                    guard let loaded = try? ImageEngine.load(url: url) else { return nil }
                    guard let measured = try? ImageEngine.estimate(loaded: loaded, options: options) else { return nil }
                    let name = ImageEngine.outputURL(for: url, format: options.format, options: options)
                        .lastPathComponent
                    return Estimate(bytes: measured.bytes,
                                    pixel: measured.pixel,
                                    outputName: name)
                }.value
                if Task.isCancelled { return }
                guard let index = self.tasks.firstIndex(where: { $0.id == id }) else { continue }
                self.tasks[index].estimating = false
                if let result {
                    self.tasks[index].estimate = result
                }
            }
        }
    }

    private func sourcePixelSize(url: URL) -> CGSize? {
        // PostScript：按和真正渲染时一致的 dpi 算，避免「之前 / 之后」尺寸对不上
        if PostScript.extensions.contains(url.pathExtension.lowercased()) {
            let (_, pixel) = PostScript.plan(url: url, maxPixel: 2400)
            return pixel
        }
        // SVG：ImageIO 完全不认。这里必须返回**光栅化之后**的像素尺寸，
        // 而不是 NSImage 的 viewBox 尺寸 —— 否则对比视图会出现
        // 「之前 256×256、之后 2,048×2,048」这种像是被偷偷放大 8 倍的假对比。
        if Formats.extraReadExtensions.contains(url.pathExtension.lowercased()) {
            return ImageEngine.svgPixelSize(url: url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    func remove(id: UUID) {
        tasks.removeAll { $0.id == id }
        if previewID == id { previewID = nil }
    }

    func clear() {
        guard !isRunning else { return }
        tasks.removeAll()
        previewID = nil
        progress = (0, 0)
        lastError = nil
    }

    func resetResults() {
        for index in tasks.indices where tasks[index].status.isDone || isFailed(tasks[index].status) {
            tasks[index].status = .pending
            tasks[index].afterThumbnail = nil
        }
        scheduleEstimates(immediate: true)
    }

    private func isFailed(_ status: TaskStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: 转换

    func convertAll() {
        guard !isRunning, !tasks.isEmpty else { return }
        let options = prefs.convertOptions()
        let targets = tasks.map { ($0.id, $0.sourceURL) }
        isRunning = true
        progress = (0, targets.count)
        lastError = nil

        Task {
            var finished = 0
            for (id, url) in targets {
                guard let index = self.tasks.firstIndex(where: { $0.id == id }) else { continue }
                self.tasks[index].status = .running

                do {
                    let result = try await Self.process(url: url, options: options)
                    if let idx = self.tasks.firstIndex(where: { $0.id == id }) {
                        self.tasks[idx].estimating = false
                        self.tasks[idx].afterThumbnail = result.thumb
                        self.tasks[idx].status = .done(url: result.outcome.url,
                                                       byteCount: result.outcome.byteCount,
                                                       pixel: result.outcome.pixelSize,
                                                       seconds: result.outcome.seconds)
                    }
                } catch {
                    if let idx = self.tasks.firstIndex(where: { $0.id == id }) {
                        self.tasks[idx].status = .failed(error.localizedDescription)
                    }
                    self.lastError = error.localizedDescription
                }
                finished += 1
                self.progress = (finished, targets.count)
            }
            self.isRunning = false
            let ok = self.doneCount
            self.toast = ok > 0 ? "已转换 \(ok) 个文件" : nil
            if self.prefs.outputDirectoryURL == nil, let first = targets.first {
                _ = first
            }
            // 转换完把成功的输出目录暴露出来，方便用户「在访达中显示」
            if let last = self.tasks.last(where: { $0.status.isDone }),
               case .done(let url, _, _, _) = last.status {
                self.lastOutputDirectory = url.deletingLastPathComponent()
            }
        }
    }

    @Published var lastOutputDirectory: URL?

    /// 后台线程跑「解码 → 缩放 → 编码」，只把轻量结果传回主线程。
    nonisolated private static func process(url: URL, options: ConvertOptions) async throws -> (outcome: ConvertOutcome, thumb: CGImage?) {
        try await Task.detached(priority: .userInitiated) {
            let loaded = try ImageEngine.load(url: url)
            let outcome = try ImageEngine.convert(loaded: loaded, options: options)
            let thumb = ImageEngine.loadThumbnail(url: outcome.url, maxPixel: 640)
            return (outcome, thumb)
        }.value
    }

    // MARK: 打开文件

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.image, .svg, .pdf]
        // EPS 没有现成的静态 UTType，按扩展名现取（取不到就不加，不影响其他格式）
        if let eps = UTType(filenameExtension: "eps") { types.append(eps) }
        panel.allowedContentTypes = types
        panel.message = "选择要转换的图片"
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func revealLastOutput() {
        guard let dir = lastOutputDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
