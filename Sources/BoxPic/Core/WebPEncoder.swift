import Foundation
import CoreGraphics
import ImageIO
import CLibWebP

// MARK: - WebP 编码

/// WebP 输出。
///
/// 为什么不用 ImageIO：`CGImageDestinationCopyTypeIdentifiers()` 里**没有**
/// `org.webmproject.webp` —— 系统只有 WebP 解码器（ImageIO 读取列表里是有 webp 的），
/// 没有编码器；`sips`、WebKit 的 `canvas.toDataURL('image/webp')` 也都退回 PNG。
/// 所以内置 libwebp 1.5.0 的编码部分（见 Sources/CLibWebP）。
enum WebPEncoder {

    enum EncodeError: LocalizedError {
        case noContext
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noContext: return "无法创建绘图缓冲区"
            case .encodeFailed: return "WebP 编码失败"
            }
        }
    }

    /// 把 CGImage 编成 WebP 落盘。
    /// - Parameter quality: 0...1，映射到 libwebp 的 0...100 质量档
    static func write(_ image: CGImage, to url: URL, quality: Double) throws {
        let data = try encode(image, quality: quality)
        try data.write(to: url, options: .atomic)
    }

    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw EncodeError.encodeFailed }

        // 统一画进 RGBA8（非预乘交给后面反算），保证 alpha 与色彩通道顺序符合 libwebp 期望
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EncodeError.noContext
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data else { throw EncodeError.noContext }

        let stride = ctx.bytesPerRow
        let needUnpremultiply = image.hasAlphaChannel
        if needUnpremultiply {
            // CGContext 出的是预乘 alpha，libwebp 要的是直通 alpha：不还原的话
            // 半透明边缘会偏暗（截图带圆角阴影时肉眼可见）
            let buffer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = buffer + y * stride
                for x in 0..<width {
                    let p = row + x * 4
                    let a = p[3]
                    if a != 0 && a != 255 {
                        p[0] = UInt8(min(255, Int(p[0]) * 255 / Int(a)))
                        p[1] = UInt8(min(255, Int(p[1]) * 255 / Int(a)))
                        p[2] = UInt8(min(255, Int(p[2]) * 255 / Int(a)))
                    }
                }
            }
        }

        let q = Float(min(max(quality, 0.01), 1.0) * 100.0)
        var output: UnsafeMutablePointer<UInt8>?
        let size = WebPEncodeRGBA(base.assumingMemoryBound(to: UInt8.self),
                                  Int32(width), Int32(height), Int32(stride), q, &output)
        guard size > 0, let output else { throw EncodeError.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }

    /// 自检用：编码后立刻解回来比对尺寸（编码器链路是否通的硬证据）。
    static func encodedPixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }
}
