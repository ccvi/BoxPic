import Foundation
import AppKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - 尺寸策略

enum ResizeMode: String, CaseIterable, Identifiable, Codable {
    case original
    case maxWidth
    case maxHeight
    case percent
    case exact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原始尺寸"
        case .maxWidth: return "最大宽度"
        case .maxHeight: return "最大高度"
        case .percent: return "百分比"
        case .exact: return "指定宽高"
        }
    }
}

/// 一次转换用到的全部参数。
struct ConvertOptions {
    var format: OutputFormat
    var resizeMode: ResizeMode = .original
    /// maxWidth / maxHeight 用（像素）
    var limitValue: Int = 2048
    /// percent 用（0.01 ... 4.0，1.0 = 100%）
    var percent: Double = 1.0
    /// exact 用（像素）
    var exactWidth: Int = 1920
    var exactHeight: Int = 1080
    /// 0 ... 1
    var quality: Double = 0.8
    /// 是否保留 EXIF / GPS / IPTC 等元数据
    var keepMetadata: Bool = true
    /// 输出目录；nil 表示与源文件同目录
    var outputDirectory: URL?
}

/// 一张已解码的源图 + 它出生时的信息。
struct LoadedImage {
    let url: URL
    let image: CGImage
    /// 源文件字节数
    let byteCount: Int64
    /// 解码后的像素尺寸（已应用 EXIF 方向）
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

struct ConvertOutcome {
    let url: URL
    let byteCount: Int64
    let pixelSize: CGSize
    let seconds: Double
}

enum ImageEngineError: LocalizedError {
    case cannotOpen(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case unsupported(String)
    case needsGhostscript(String)
    case postScriptTimeout(String)
    case postScriptFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): return "打不开「\(name)」"
        case .decodeFailed(let name): return "「\(name)」解不出图像数据"
        case .encodeFailed(let fmt): return "编码为 \(fmt) 失败"
        case .unsupported(let ext): return "不支持的格式（\(ext)）"
        case .needsGhostscript(let name):
            return "「\(name)」需要 Ghostscript 才能渲染。macOS 自 macOS 10.15 起已不带 PostScript 解释器，"
                 + "在终端执行 brew install ghostscript 后重新拖入即可。"
        case .postScriptTimeout(let name):
            return "「\(name)」渲染超时（30 秒），文件可能损坏或过于复杂"
        case .postScriptFailed(let name, let message):
            return "「\(name)」PostScript 渲染失败：\(message)"
        }
    }
}

enum ImageEngine {

    // MARK: - 解码

    /// 读一张图（全尺寸，已按 EXIF 摆正）。
    ///
    /// 三条路径：
    ///   · SVG —— ImageIO 完全不认识，交给 NSImage（_NSSVGImageRep）矢量化光栅；
    ///   · 相机 RAW —— 用 CreateThumbnailAtIndex + CreateThumbnailFromImageAlways
    ///     让系统走 RAW 管线（直接 CreateImageAtIndex 对部分机型出的是小预览图）；
    ///   · 其余 —— CGImageSourceCreateImageAtIndex。
    static func load(url: URL) throws -> LoadedImage {
        let ext = url.pathExtension.lowercased()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            throw ImageEngineError.cannotOpen(url.lastPathComponent)
        }

        // PostScript：系统没有任何解释器，交给外部 Ghostscript 光栅化
        if PostScript.extensions.contains(ext) {
            let image = try PostScript.render(url: url, maxPixel: 2400)
            return LoadedImage(url: url, image: image, byteCount: size)
        }

        // SVG：NSImage 能读，但读出来是矢量 rep，必须自己决定光栅化尺寸
        if Formats.extraReadExtensions.contains(ext) {
            guard let data = try? Data(contentsOf: url),
                  let cg = rasterizeSVG(data: data, targetPixelWidth: 2400) else {
                throw ImageEngineError.decodeFailed(url.lastPathComponent)
            }
            return LoadedImage(url: url, image: cg, byteCount: size)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageEngineError.cannotOpen(url.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw ImageEngineError.decodeFailed(url.lastPathComponent)
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let isRAW = isRawIdentifier(CGImageSourceGetType(source) as String? ?? "")

        var cgImage: CGImage?
        if isRAW {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 12_000,
                kCGImageSourceShouldCacheImmediately: true
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        }
        if cgImage == nil {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let decoded = cgImage else {
            throw ImageEngineError.decodeFailed(url.lastPathComponent)
        }

        // 非 RAW 路径不会自动应用 EXIF 方向，这里补上
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let upright = (orientation == 1) ? decoded : applyOrientation(decoded, orientation: orientation)
        return LoadedImage(url: url, image: upright, byteCount: size)
    }

    /// 缩略图（网格用）。比全尺寸解码快一个量级，大图批量导入时才不卡。
    static func loadThumbnail(url: URL, maxPixel: Int = 560) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if PostScript.extensions.contains(ext) {
            // 基准光栅化就是 2400（和 load 一致），要更大只会是重采样出来的糊图，
            // 而且会让对比视图的「之前」和「之后」来自两个不同 dpi 的渲染
            return try? PostScript.render(url: url, maxPixel: min(maxPixel, 2400))
        }
        if Formats.extraReadExtensions.contains(ext) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return rasterizeSVG(data: data, targetPixelWidth: maxPixel)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    private static func isRawIdentifier(_ id: String) -> Bool {
        id.contains("raw-image") || id.contains("raw")
    }

    /// EXIF 方向 → 真正旋转像素。
    private static func applyOrientation(_ image: CGImage, orientation: UInt32) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        // 用 CoreImage 做方向变换最省事，也最不容易把正负号写反
        let ci = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = ciCtx.createCGImage(ci, from: ci.extent) else { return image }
        return out
    }

    /// SVG → 位图。等比铺满 targetPixelWidth（不超过原始 viewBox 尺寸的 4 倍，避免糊）。
    static func rasterizeSVG(data: Data, targetPixelWidth: Int) -> CGImage? {
        guard let nsImage = NSImage(data: data) else { return nil }
        var box = nsImage.size
        if box.width <= 0 || box.height <= 0 { box = CGSize(width: 512, height: 512) }
        let scale = min(Double(targetPixelWidth) / box.width, 8.0)
        let pixelW = max(1, Int((box.width * scale).rounded()))
        let pixelH = max(1, Int((box.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        nsImage.draw(in: NSRect(x: 0, y: 0, width: pixelW, height: pixelH),
                     from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: - 尺寸计算

    /// 算出输出像素尺寸。纯函数，自检直接打表比对。
    static func targetSize(for source: CGSize, options: ConvertOptions) -> CGSize {
        let w = max(1, Int(source.width.rounded()))
        let h = max(1, Int(source.height.rounded()))
        var result: CGSize

        switch options.resizeMode {
        case .original:
            result = CGSize(width: w, height: h)
        case .maxWidth:
            let limit = max(1, options.limitValue)
            if w <= limit { result = CGSize(width: w, height: h) }
            else {
                let ratio = Double(limit) / Double(w)
                result = CGSize(width: limit, height: max(1, Int((Double(h) * ratio).rounded())))
            }
        case .maxHeight:
            let limit = max(1, options.limitValue)
            if h <= limit { result = CGSize(width: w, height: h) }
            else {
                let ratio = Double(limit) / Double(h)
                result = CGSize(width: max(1, Int((Double(w) * ratio).rounded())), height: limit)
            }
        case .percent:
            let p = min(max(options.percent, 0.01), 4.0)
            result = CGSize(width: max(1, Int((Double(w) * p).rounded())),
                            height: max(1, Int((Double(h) * p).rounded())))
        case .exact:
            result = CGSize(width: max(1, options.exactWidth), height: max(1, options.exactHeight))
        }

        if let cap = options.format.maxPixel {
            let longest = max(result.width, result.height)
            if longest > CGFloat(cap) {
                let ratio = CGFloat(cap) / longest
                result = CGSize(width: max(1, (result.width * ratio).rounded()),
                                height: max(1, (result.height * ratio).rounded()))
            }
        }
        return result
    }

    /// 高质量缩放：缩得比一半还小的时候先对半砍，避免一次插值掉细节。
    static func resize(_ image: CGImage, to target: CGSize) -> CGImage {
        let tw = max(1, Int(target.width)), th = max(1, Int(target.height))
        if tw == image.width && th == image.height { return image }

        var current = image
        while current.width / 2 >= tw && current.height / 2 >= th && max(tw, th) > 0 {
            let halfW = max(tw, current.width / 2)
            let halfH = max(th, current.height / 2)
            guard let step = draw(current, width: halfW, height: halfH) else { break }
            current = step
            if halfW == tw && halfH == th { break }
        }
        return draw(current, width: tw, height: th) ?? current
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo = image.hasAlphaChannel ? .premultipliedLast : .noneSkipLast
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: space, bitmapInfo: alpha.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - 编码

    /// 一步到位：解码 → 缩放 → 编码 → 落盘。
    static func convert(loaded: LoadedImage, options: ConvertOptions) throws -> ConvertOutcome {
        let started = CFAbsoluteTimeGetCurrent()
        let size = targetSize(for: loaded.pixelSize, options: options)
        let scaled = resize(loaded.image, to: size)
        let metadata = options.keepMetadata ? sourceMetadata(loaded.url) : nil
        let data = try encode(scaled, format: options.format, quality: options.quality, metadata: metadata)

        let destination = outputURL(for: loaded.url, format: options.format, options: options)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        // 原地同名会覆盖源文件 —— 这一步是防线：源文件绝不被动
        if destination.standardizedFileURL == loaded.url.standardizedFileURL {
            throw ImageEngineError.encodeFailed(options.format.name)
        }

        return ConvertOutcome(url: destination,
                              byteCount: Int64(data.count),
                              pixelSize: CGSize(width: scaled.width, height: scaled.height),
                              seconds: CFAbsoluteTimeGetCurrent() - started)
    }

    /// 只编码不落盘 —— 拖进来时用它算「转换后大概多大」。
    /// 走的是和真正转换**完全相同**的代码路径，所以数字就是最终值，不是抽样估计。
    static func estimate(loaded: LoadedImage, options: ConvertOptions) throws -> (bytes: Int64, pixel: CGSize) {
        let size = targetSize(for: loaded.pixelSize, options: options)
        let scaled = resize(loaded.image, to: size)
        let metadata = options.keepMetadata ? sourceMetadata(loaded.url) : nil
        let data = try encode(scaled, format: options.format, quality: options.quality, metadata: metadata)
        return (Int64(data.count), CGSize(width: scaled.width, height: scaled.height))
    }

    /// 按当前参数真的转一遍，再把**编码后的字节**解回来当预览。
    ///
    /// 🔴 必须从字节解码，不能拿编码前的 `scaled` 缩一张：压缩劣化发生在编码这一步，
    /// 用编码前的图做预览，质量拖到 5% 也照样清晰 —— 用户会以为参数没生效。
    static func renderPreview(loaded: LoadedImage, options: ConvertOptions, maxPixel: Int = 2600) -> CGImage? {
        let size = targetSize(for: loaded.pixelSize, options: options)
        let scaled = resize(loaded.image, to: size)
        guard let data = try? encode(scaled, format: options.format, quality: options.quality, metadata: nil) else {
            return previewImage(scaled, maxPixel: maxPixel)
        }
        // 解码回来的才是用户真正会看到的画质；解不回来（ASTC/KTX 之类）才退回无损缩图
        return decodedPreview(data: data, maxPixel: maxPixel) ?? previewImage(scaled, maxPixel: maxPixel)
    }

    /// 把一段已编码的图像数据解成不超过 maxPixel 的小图。
    static func decodedPreview(data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    // MARK: - 对比图合成

    /// 把「之前 / 之后」拼成**一张图**：左半张取转换前的像素，右半张取转换后的像素，
    /// 中间一条橙线。接缝两侧是同一张画的内容，位置完全对得上，
    /// 所以看起来就是一张完整的图 —— 只有画质在橙线处变了。
    ///
    /// 早先做成「左右各塞一张完整的缩图」，两侧内容对不上、接缝处画面跳变；
    /// 而且整套图被压到窗口大小去显示，缩得越小越看不出压缩痕迹。
    static func composeComparison(before: CGImage, after: CGImage, maxSide: Int = 2800) -> CGImage? {
        // 画布以「之后」为准 —— 用户真正关心的是输出那张图
        var canvasW = after.width, canvasH = after.height
        let longest = max(canvasW, canvasH)
        if longest > maxSide {
            let ratio = Double(maxSide) / Double(longest)
            canvasW = max(2, Int((Double(canvasW) * ratio).rounded()))
            canvasH = max(2, Int((Double(canvasH) * ratio).rounded()))
        }
        guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(full)

        // 改了尺寸时两边像素数不同，各自等比放进同一块画布（居中），接缝才对得齐
        let seam = canvasW / 2
        let gap = max(2, Int((Double(canvasW) * 0.006).rounded()))
        let leftRect = fitRect(for: before, in: full)
        let rightRect = fitRect(for: after, in: full)

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: seam, height: canvasH))
        ctx.draw(before, in: leftRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: CGRect(x: seam, y: 0, width: canvasW - seam, height: canvasH))
        ctx.draw(after, in: rightRect)
        ctx.restoreGState()

        // 橙线：和界面强调色同色（#FF9F0A），压在接缝正中
        ctx.setFillColor(CGColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1))
        ctx.fill(CGRect(x: seam - gap / 2, y: 0, width: gap, height: canvasH))
        return ctx.makeImage()
    }

    /// 等比放进 rect 后的实际绘制区域（居中）
    private static func fitRect(for image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// SVG 实际会被光栅化到多大 —— 和 `load` 用同一套算法，
    /// 否则「之前 256×256、之后 2048×2048」这种对比会让人以为尺寸被偷偷改过。
    static func svgPixelSize(url: URL, targetPixelWidth: Int = 2400) -> CGSize? {
        guard let data = try? Data(contentsOf: url), let nsImage = NSImage(data: data) else { return nil }
        var box = nsImage.size
        if box.width <= 0 || box.height <= 0 { box = CGSize(width: 512, height: 512) }
        let scale = min(Double(targetPixelWidth) / box.width, 8.0)
        return CGSize(width: max(1, (box.width * scale).rounded()),
                      height: max(1, (box.height * scale).rounded()))
    }

    /// 预览用的小图（不落盘，纯内存）
    static func previewImage(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let ratio = Double(maxPixel) / Double(longest)
        let target = CGSize(width: max(1, (Double(image.width) * ratio).rounded()),
                            height: max(1, (Double(image.height) * ratio).rounded()))
        return resize(image, to: target)
    }

    /// 所有格式的统一出口：先拿到字节，再由调用方决定写盘还是丢弃。
    static func encode(_ image: CGImage, format: OutputFormat, quality: Double,
                       metadata: [CFString: Any]?) throws -> Data {
        if format.usesLibWebP {
            return try WebPEncoder.encode(image, quality: quality)
        }
        if format.isICNS {
            return try icnsData(image)
        }
        if format.isICO {
            return try icoData(image)
        }
        return try imageIOData(image, format: format, quality: quality, metadata: metadata)
    }

    /// 目标文件名：原名 + 新扩展名；与源同目录同格式时自动加序号，绝不覆盖。
    static func outputURL(for source: URL, format: OutputFormat, options: ConvertOptions) -> URL {
        let dir = options.outputDirectory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base).\(format.ext)")
        var index = 2
        // 同格式 + 同目录时，第一个候选正好就是源文件本身 —— 必须往后让，
        // 而且每轮都要重新判断（写成循环外的常量会让循环一路涨到 9999）
        while FileManager.default.fileExists(atPath: candidate.path)
                || candidate.standardizedFileURL == source.standardizedFileURL {
            if index > 999 {
                let stamp = Int(Date().timeIntervalSince1970)
                return dir.appendingPathComponent("\(base)-\(stamp).\(format.ext)")
            }
            candidate = dir.appendingPathComponent("\(base) \(index).\(format.ext)")
            index += 1
        }
        return candidate
    }

    /// 源文件的元数据字典（Exif / GPS / TIFF / IPTC / XMP）。
    private static func sourceMetadata(_ url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        var keep: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImageProperty8BIMDictionary] {
            if let value = props[key] { keep[key] = value }
        }
        return keep.isEmpty ? nil : keep
    }

    private static func imageIOData(_ image: CGImage, format: OutputFormat,
                                    quality: Double, metadata: [CFString: Any]?) throws -> Data {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData, format.uti as CFString, 1, nil) else {
            throw ImageEngineError.encodeFailed(format.name)
        }
        var props: [CFString: Any] = [:]
        if format.lossy {
            props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.01), 1.0)
        }
        if let metadata { for (k, v) in metadata { props[k] = v } }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageEngineError.encodeFailed(format.name)
        }
        return buffer as Data
    }

    /// ICNS 不吃单张图，也不接受 1~9999 之外的尺寸组合。
    /// ImageIO 的 ICNS 写入在 macOS 26 上直接 Finalize 失败，所以自己拼容器：
    ///   'icns' + 总长度 + 若干 (4 字节类型 + 4 字节长度 + PNG)
    /// 现代 macOS 认 PNG 压缩块，不需要 iconutil。
    private static func icnsData(_ image: CGImage) throws -> Data {
        // 类型码 → 边长（含 @2x 变体，Retina 下才不会糊）
        let entries: [(String, Int)] = [
            ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
            ("ic07", 128), ("ic13", 256), ("ic08", 256),
            ("ic14", 512), ("ic09", 512), ("ic10", 1024)
        ]
        var body = Data()
        for (type, side) in entries {
            guard let rep = draw(image, width: side, height: side),
                  let png = pngData(rep) else { continue }
            var length = UInt32(png.count + 8).bigEndian
            body.append(contentsOf: Array(type.utf8))
            body.append(Data(bytes: &length, count: 4))
            body.append(png)
        }
        guard !body.isEmpty else { throw ImageEngineError.encodeFailed("ICNS") }
        var total = UInt32(body.count + 8).bigEndian
        var out = Data("icns".utf8)
        out.append(Data(bytes: &total, count: 4))
        out.append(body)
        return out
    }

    /// ICO 必须是正方形，且边长只能取 16/24/32/48/64/128/256。
    /// 非正方形源图等比缩到 ≤256 后居中放进透明画布（不裁剪内容）。
    private static func icoData(_ image: CGImage) throws -> Data {
        let side = 256
        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let drawW = max(1, Int((Double(image.width) * scale).rounded()))
        let drawH = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageEngineError.encodeFailed("ICO")
        }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(image, in: CGRect(x: (side - drawW) / 2, y: (side - drawH) / 2,
                                   width: drawW, height: drawH))
        let buffer = NSMutableData()
        guard let square = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(buffer as CFMutableData, "com.microsoft.ico" as CFString, 1, nil) else {
            throw ImageEngineError.encodeFailed("ICO")
        }
        CGImageDestinationAddImage(dest, square, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageEngineError.encodeFailed("ICO")
        }
        return buffer as Data
    }

    /// CGImage → PNG 字节（ICNS 内嵌块用）
    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
