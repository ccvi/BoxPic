import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 输出格式

/// 一种可输出的图片格式。
///
/// `id` 用 UTI（WebP 用自定义的 `org.webmproject.webp`，由内置 libwebp 处理），
/// 这样 UI、编码器、自检都只认一个 key，不会出现「菜单写 webp、编码器认 WEBP」的错位。
struct OutputFormat: Identifiable, Hashable {
    /// 编码用的 UTI（交给 ImageIO 或内置 libwebp）
    let uti: String
    /// 落盘扩展名（不含点）
    let ext: String
    /// 菜单里显示的名字
    let name: String
    /// 有损格式才真正吃「质量」参数（ImageIO 对 PNG/TIFF/PDF 等无损容器会忽略它）
    let lossy: Bool
    /// 编码时要不要先把边长夹到这个上限（ICO 只接受 ≤256）
    let maxPixel: Int?
    /// 是否进「更多」子菜单
    let isExtra: Bool

    /// 唯一标识：同一个 UTI 可以有多个扩展名（JPG / JPEG 都是 public.jpeg），
    /// 所以菜单身份不能只认 UTI，否则两者会互相覆盖
    var id: String { "\(uti)#\(ext)" }

    var displayName: String { name }

    /// 质量滑杆是否对该格式生效。无损格式照样可以给出「无损」提示，
    /// 而不是让用户拖了半天发现体积一动不动。
    var qualityApplies: Bool { lossy }

    static let webpID = "org.webmproject.webp"

    var usesLibWebP: Bool { uti == Self.webpID }
    var isICNS: Bool { uti == "com.apple.icns" }
    var isICO: Bool { uti == "com.microsoft.ico" }
}

enum Formats {

    /// 主列表（菜单里直接露出的 5 个）
    static let primary: [OutputFormat] = [
        OutputFormat(uti: "public.jpeg", ext: "jpg", name: "JPG", lossy: true, maxPixel: nil, isExtra: false),
        OutputFormat(uti: "public.jpeg", ext: "jpeg", name: "JPEG", lossy: true, maxPixel: nil, isExtra: false),
        OutputFormat(uti: "public.heic", ext: "heic", name: "HEIC", lossy: true, maxPixel: nil, isExtra: false),
        OutputFormat(uti: "public.png", ext: "png", name: "PNG", lossy: false, maxPixel: nil, isExtra: false),
        OutputFormat(uti: OutputFormat.webpID, ext: "webp", name: "WEBP", lossy: true, maxPixel: nil, isExtra: false),
        OutputFormat(uti: "public.avif", ext: "avif", name: "AVIF", lossy: true, maxPixel: nil, isExtra: false)
    ]

    /// 「更多」子菜单 —— 顺序照参考图排（短的在前，纹理格式垫底）
    static let extra: [OutputFormat] = [
        OutputFormat(uti: "org.khronos.astc", ext: "astc", name: "ASTC", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.microsoft.bmp", ext: "bmp", name: "BMP", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.ilm.openexr-image", ext: "exr", name: "EXR", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.compuserve.gif", ext: "gif", name: "GIF", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "public.heics", ext: "heics", name: "HEICS", lossy: true, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.apple.icns", ext: "icns", name: "ICNS", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.microsoft.ico", ext: "ico", name: "ICO", lossy: false, maxPixel: 256, isExtra: true),
        OutputFormat(uti: "public.jpeg-2000", ext: "jp2", name: "JP2", lossy: true, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "org.khronos.ktx", ext: "ktx", name: "KTX", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "public.pbm", ext: "pbm", name: "PBM", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.adobe.pdf", ext: "pdf", name: "PDF", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.adobe.photoshop-image", ext: "psd", name: "PSD", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "com.truevision.tga-image", ext: "tga", name: "TGA", lossy: false, maxPixel: nil, isExtra: true),
        OutputFormat(uti: "public.tiff", ext: "tiff", name: "TIFF", lossy: false, maxPixel: nil, isExtra: true)
    ]

    static let all: [OutputFormat] = primary + extra

    static func format(id: String) -> OutputFormat? {
        if let exact = all.first(where: { $0.id == id }) { return exact }
        // 旧版本/手写偏好里可能只存了 UTI（如 public.jpeg），取第一个同名项
        return all.first { $0.uti == id }
    }

    static func format(ext: String) -> OutputFormat? {
        let lower = ext.lowercased()
        return all.first { $0.ext == lower }
    }

    // MARK: 输入

    /// 系统 ImageIO 能解的类型（62 种，运行期取，不写死 —— 换系统版本自动跟着变）。
    static let systemReadIdentifiers: [String] = {
        (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
    }()

    /// 额外支持：SVG 走 NSImage（ImageIO 不认识 SVG）。
    static let extraReadExtensions: Set<String> = ["svg", "svgz"]

    /// EPS / PostScript 也要单独列：它们靠外部 Ghostscript 渲染（见 PostScript.swift）
    static let postScriptExtensions: Set<String> = PostScript.extensions

    /// 输入总数量（用于「支持 N 种格式」的文案，不硬编码）
    static var inputFormatCount: Int {
        var seen = Set<String>()
        for id in systemReadIdentifiers {
            if let ext = UTType(id)?.preferredFilenameExtension { seen.insert(ext) }
        }
        seen.formUnion(extraReadExtensions)
        seen.formUnion(postScriptExtensions)
        return seen.count
    }

    /// 拖放 / 打开对话框允许的扩展名（给 NSOpenPanel 与拖放过滤用）
    static let acceptedExtensions: [String] = {
        var set = Set<String>()
        for id in systemReadIdentifiers {
            if let t = UTType(id) {
                if let e = t.preferredFilenameExtension { set.insert(e) }
                // 有些类型的首选扩展名和实际文件后缀不一致（如 tif/raw），把所有标签补上
                for tag in t.tags[.filenameExtension] ?? [] { set.insert(tag) }
            }
        }
        set.formUnion(extraReadExtensions)
        set.formUnion(postScriptExtensions)
        return set.sorted()
    }()

    /// 是不是我们认得的图片文件（按扩展名判断，够快且不触发文件读取）
    static func isSupportedInput(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return acceptedExtensions.contains(ext)
            || extraReadExtensions.contains(ext)
            || postScriptExtensions.contains(ext)
    }
}
