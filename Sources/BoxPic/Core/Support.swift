import Foundation
import CoreGraphics

// MARK: - 显示用的格式化

enum Fmt {

    /// 文件大小：参考图里是「690 kB / 3.5 MB / 136 kB」这种短写法。
    static func bytes(_ value: Int64) -> String {
        if value < 1024 { return "\(value) B" }
        let kb = Double(value) / 1024.0
        if kb < 1024 {
            return kb < 10 ? String(format: "%.1f kB", kb) : String(format: "%.0f kB", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024 {
            return mb < 10 ? String(format: "%.1f MB", mb) : String(format: "%.0f MB", mb)
        }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    /// 像素尺寸：4,000 × 3,000
    static func pixels(_ size: CGSize) -> String {
        "\(grouped(Int(size.width.rounded()))) × \(grouped(Int(size.height.rounded())))"
    }

    static func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 百分比：50% / 125%
    static func percent(_ value: Double) -> String {
        let pct = value * 100
        return abs(pct.rounded() - pct) < 0.05 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}

// MARK: - 小工具

extension CGImage {
    /// CGImage 没有 hasAlpha 属性（那是 NSImage 的），按 alphaInfo 判断
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .premultipliedLast, .premultipliedFirst, .last, .first:
            return true
        default:
            return false
        }
    }
}
