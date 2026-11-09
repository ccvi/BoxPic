import Foundation
import CoreGraphics

// MARK: - 偏好设置

/// 转换参数 + 界面偏好，全部落 UserDefaults。
///
/// 只存「值」，不存 OutputFormat 结构体：格式会随系统 ImageIO 变化，
/// 存 UTI 字符串最稳，读回来时按 id 查表，查不到就回落到 JPEG。
struct Preferences: Codable, Equatable {
    var formatID: String = "public.jpeg#jpg"
    var resizeMode: ResizeMode = .original
    var limitValue: Int = 2048
    var percent: Double = 0.5
    var exactWidth: Int = 1920
    var exactHeight: Int = 1080
    var quality: Double = 0.8
    var keepMetadata: Bool = false
    /// 输出目录；nil = 源文件同目录
    var outputDirectory: String?

    var format: OutputFormat {
        Formats.format(id: formatID) ?? Formats.primary[0]
    }

    /// 把可能残留的旧写法（纯 UTI）规整成 `<uti>#<ext>`
    mutating func normalize() {
        formatID = format.id
        // 质量只认 5% 的整数倍（UI 是 20 格），历史值可能是 0.94 这种
        let steps = (quality * 20).rounded()
        quality = min(max(steps / 20, 0.05), 1.0)
    }

    var outputDirectoryURL: URL? {
        guard let outputDirectory, !outputDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: outputDirectory, isDirectory: true)
    }

    /// 转成引擎参数
    func convertOptions(format override: OutputFormat? = nil) -> ConvertOptions {
        ConvertOptions(format: override ?? format,
                       resizeMode: resizeMode,
                       limitValue: limitValue,
                       percent: percent,
                       exactWidth: exactWidth,
                       exactHeight: exactHeight,
                       quality: quality,
                       keepMetadata: keepMetadata,
                       outputDirectory: outputDirectoryURL)
    }

    /// 大小控件的显示文本（参考图里那一格：100% / 50% / 2,000 px）
    var sizeLabel: String {
        switch resizeMode {
        case .original: return "100%"
        case .percent: return Fmt.percent(percent)
        case .maxWidth, .maxHeight: return "\(Fmt.grouped(limitValue)) px"
        case .exact: return "\(Fmt.grouped(exactWidth))×\(Fmt.grouped(exactHeight))"
        }
    }

    static let storageKey = "BoxPic.Preferences.v1"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
