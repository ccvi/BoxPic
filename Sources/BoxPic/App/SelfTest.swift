import Foundation
import AppKit
import ImageIO
import CoreGraphics

// MARK: - 应用内自检
//
// build-app.sh 拿它当发布门禁：返回值非 0 就直接中止打包。
// 只跑 .build 下的裸可执行文件，绝不去 exec .app 里的二进制（家族铁律）。

enum SelfTest {

    private static var failures = 0
    private static var checks = 0

    static func run() -> Bool {
        print("BoxPic 自检")
        print("────────────────────────────────────")

        // 上一轮的残留会让「不覆盖」这类断言读到脏数据，先清干净
        try? FileManager.default.removeItem(at: tempDir())
        try? FileManager.default.createDirectory(at: tempDir(), withIntermediateDirectories: true)

        formatTable()
        sizeMath()
        icoFrames()
        svgInput()
        webpRoundTrip()
        everyFormatEncodes()
        qualityMatters()
        estimateMatchesReality()
        estimateIsStable()
        previewShowsCompression()
        comparisonComposite()
        postScriptInput()
        jxlRoundTrip()
        noOverwrite()

        print("────────────────────────────────────")
        if failures == 0 {
            print("✓ 全部 \(checks) 项通过")
            return true
        }
        print("✗ \(failures) 项失败（共 \(checks) 项）")
        return false
    }

    // MARK: 断言

    private static func check(_ ok: Bool, _ label: String, detail: String = "") {
        checks += 1
        if ok {
            print("✓ \(label)\(detail.isEmpty ? "" : "  \(detail)")")
        } else {
            failures += 1
            print("✗ \(label)\(detail.isEmpty ? "" : "  \(detail)")")
        }
    }

    // MARK: 用例

    /// 格式表：主列表不该混进「更多」，每个 UTI 必须真的可写（WebP 除外，走内置编码器）
    private static func formatTable() {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        var missing: [String] = []
        // JXL 系统只解不写，靠外部 cjxl，不能拿 ImageIO 的可写列表去要求它
        for format in Formats.all where !format.usesLibWebP && !format.isJXL {
            if !writable.contains(format.uti) { missing.append(format.name) }
        }
        check(missing.isEmpty, "格式表与系统 ImageIO 一致",
              detail: missing.isEmpty ? "\(Formats.all.count) 种输出" : "缺：\(missing.joined(separator: ","))")
        check(Formats.inputFormatCount >= 50, "输入格式数 ≥ 50",
              detail: "\(Formats.inputFormatCount) 种")
        check(Formats.all.count >= 19, "输出格式数 ≥ 19", detail: "\(Formats.all.count) 种")
        check(Formats.primary.count == 6, "主菜单 6 项", detail: Formats.primary.map(\.name).joined(separator: "/"))
        // 扩展名不能重复，否则 outputURL 会撞车
        let exts = Formats.all.map(\.ext)
        check(Set(exts).count == exts.count, "扩展名唯一")
    }

    /// 尺寸计算（纯函数，直接对表）
    private static func sizeMath() {
        let source = CGSize(width: 4000, height: 3000)
        func size(_ mode: ResizeMode, limit: Int = 2048, percent: Double = 0.5,
                  exact: (Int, Int) = (1920, 1080), format: OutputFormat = Formats.primary[0]) -> CGSize {
            var options = ConvertOptions(format: format)
            options.resizeMode = mode
            options.limitValue = limit
            options.percent = percent
            options.exactWidth = exact.0
            options.exactHeight = exact.1
            return ImageEngine.targetSize(for: source, options: options)
        }

        check(size(.original) == source, "原始尺寸不变")
        check(size(.percent, percent: 0.5) == CGSize(width: 2000, height: 1500), "50% → 2000×1500")
        check(size(.maxWidth, limit: 2000) == CGSize(width: 2000, height: 1500), "最大宽度 2000 等比")
        check(size(.maxHeight, limit: 1500) == CGSize(width: 2000, height: 1500), "最大高度 1500 等比")
        check(size(.maxWidth, limit: 8000) == source, "上限大于原图时不放大")
        check(size(.exact, exact: (1920, 1080)) == CGSize(width: 1920, height: 1080), "指定宽高")

        // ICO 必须夹到 ≤256，否则 ImageIO Finalize 直接返回 false
        if let ico = Formats.format(ext: "ico") {
            let capped = size(.original, format: ico)
            check(max(capped.width, capped.height) <= 256, "ICO 自动夹到 256",
                  detail: "\(Int(capped.width))×\(Int(capped.height))")
        }
    }

    /// ICO 要封进去的分辨率：目标尺寸决定阶梯
    ///   256 → 16/32/48/64/128/256；128 → 到 128；64 → 到 64；32 → 16/32
    private static func icoFrames() {
        let expect: [(Int, [Int])] = [
            (256, [16, 32, 48, 64, 128, 256]),
            (128, [16, 32, 48, 64, 128]),
            (64,  [16, 32, 48, 64]),
            (32,  [16, 32])
        ]
        for (target, want) in expect {
            let got = ImageEngine.icoFrames(forTarget: target)
            check(got == want, "ICO \(target) 封 \(want.count) 档",
                  detail: got.map(String.init).joined(separator: "/"))
        }

        // 光算函数不算数，还得确认 ImageIO 真把这几张写进目录了
        guard let ico = Formats.format(ext: "ico"),
              let image = makeTestImage(width: 300, height: 200) else {
            check(false, "ICO 目录")
            return
        }
        let scaled = ImageEngine.resize(image, to: CGSize(width: 256, height: 171))
        guard let data = try? ImageEngine.encode(scaled, format: ico, quality: 1, metadata: nil) else {
            check(false, "ICO 目录", detail: "编码失败")
            return
        }
        let sides = icoDirectory(data)
        check(sides.sorted() == [16, 32, 48, 64, 128, 256], "ICO 目录真的封了 6 档",
              detail: "\(Fmt.bytes(Int64(data.count))) · " + sides.map(String.init).joined(separator: "/"))
    }

    /// 读 ICO 目录，返回每个条目的边长（规范里 0 表示 256）
    private static func icoDirectory(_ data: Data) -> [Int] {
        let b = [UInt8](data)
        guard b.count >= 6, b[0] == 0, b[1] == 0, b[2] == 1, b[3] == 0 else { return [] }
        let count = Int(b[4]) | Int(b[5]) << 8
        var sides: [Int] = []
        for i in 0..<count {
            let off = 6 + i * 16
            guard off + 16 <= b.count else { break }
            sides.append(b[off] == 0 ? 256 : Int(b[off]))
        }
        return sides
    }

    /// SVG 输入（ImageIO 不认 SVG，走 NSImage）
    private static func svgInput() {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="180">
          <rect width="320" height="180" fill="#ff9f0a"/>
          <circle cx="160" cy="90" r="60" fill="#ffffff"/>
        </svg>
        """
        let url = tempDir().appendingPathComponent("probe.svg")
        try? svg.data(using: .utf8)?.write(to: url)
        do {
            let loaded = try ImageEngine.load(url: url)
            check(loaded.image.width >= 320, "SVG 解码",
                  detail: "\(loaded.image.width)×\(loaded.image.height)")
        } catch {
            check(false, "SVG 解码", detail: error.localizedDescription)
        }
        check(Formats.isSupportedInput(url), "SVG 被识别为受支持输入")
    }

    /// WebP：编码 → 用系统 ImageIO 解回来（能解说明容器正确）
    private static func webpRoundTrip() {
        guard let image = makeTestImage(width: 240, height: 160) else {
            check(false, "WebP 测试图生成")
            return
        }
        do {
            let data = try WebPEncoder.encode(image, quality: 0.8)
            check(data.count > 100, "WebP 编码", detail: "\(data.count) 字节")
            check(data.prefix(4).elementsEqual(Array("RIFF".utf8)), "WebP RIFF 头正确")
            let size = WebPEncoder.encodedPixelSize(data)
            check(size == CGSize(width: 240, height: 160), "WebP 尺寸回读一致",
                  detail: size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "解不出")
        } catch {
            check(false, "WebP 编码", detail: error.localizedDescription)
        }
    }

    /// 每一种输出格式真的能落盘（空文件 / Finalize false 都算失败）
    private static func everyFormatEncodes() {
        let source = tempDir().appendingPathComponent("src.png")
        guard let image = makeTestImage(width: 512, height: 384),
              let dest = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil) else {
            check(false, "样本图准备")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            check(false, "样本 PNG 落盘")
            return
        }

        var failed: [String] = []
        for format in Formats.all where !(format.isJXL && !JXLEncoder.isAvailable) {
            var options = ConvertOptions(format: format)
            options.resizeMode = .original
            do {
                let loaded = try ImageEngine.load(url: source)
                let outcome = try ImageEngine.convert(loaded: loaded, options: options)
                if outcome.byteCount <= 0 { failed.append("\(format.name)(空)") }
                try? FileManager.default.removeItem(at: outcome.url)
            } catch {
                failed.append("\(format.name)(\(error.localizedDescription))")
            }
        }
        check(failed.isEmpty, "全部 \(Formats.all.count) 种格式可输出",
              detail: failed.isEmpty ? "含 WebP / ICNS / ICO" : failed.joined(separator: " "))
    }

    /// 质量参数必须真的影响体积（只有有损格式才检查）
    private static func qualityMatters() {
        guard let image = makeTestImage(width: 900, height: 700) else { return }
        let lossy = Formats.all.filter { $0.qualityApplies && !$0.usesLibWebP }
        for format in lossy.prefix(4) {
            let high = tempDir().appendingPathComponent("q90.\(format.ext)")
            let low = tempDir().appendingPathComponent("q30.\(format.ext)")
            do {
                try encode(image, format: format, quality: 0.9, to: high)
                try encode(image, format: format, quality: 0.3, to: low)
                let a = fileSize(high), b = fileSize(low)
                check(a > b, "\(format.name) 质量影响体积", detail: "q90 \(Fmt.bytes(a)) > q30 \(Fmt.bytes(b))")
            } catch {
                check(false, "\(format.name) 质量测试", detail: error.localizedDescription)
            }
        }
    }

    /// 拖进来显示的「转换后多大」必须等于真转换后的字节数 —— 这是对用户的承诺
    private static func estimateMatchesReality() {
        let dir = tempDir()
        let source = dir.appendingPathComponent("estimate-src.png")
        guard let image = makeTestImage(width: 720, height: 480),
              let dest = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil) else {
            check(false, "预估测试样本")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }

        for format in [Formats.primary[0]] + [Formats.format(ext: "webp")].compactMap { $0 } {   // JPG / WEBP
            var options = ConvertOptions(format: format)
            options.resizeMode = .percent
            options.percent = 0.5
            options.quality = 0.7
            do {
                let loaded = try ImageEngine.load(url: source)
                let estimated = try ImageEngine.estimate(loaded: loaded, options: options)
                let real = try ImageEngine.convert(loaded: loaded, options: options)
                let same = estimated.bytes == real.byteCount
                check(same, "\(format.name) 预估值 = 实际大小",
                      detail: same ? "\(Fmt.bytes(real.byteCount))"
                                   : "预估 \(estimated.bytes) / 实际 \(real.byteCount)")
                check(estimated.pixel == real.pixelSize, "\(format.name) 预估尺寸 = 实际尺寸",
                      detail: Fmt.pixels(real.pixelSize))
                try? FileManager.default.removeItem(at: real.url)
            } catch {
                check(false, "\(format.name) 预估测试", detail: error.localizedDescription)
            }
        }
    }

    /// 同一组参数连算两次必须完全一样，换参数必须跟着变。
    /// 界面上「卡片显示 92 kB、对比视图显示 83 kB」这类不一致，只允许由参数变化解释，
    /// 不允许来自估算本身的不确定性。
    private static func estimateIsStable() {
        let dir = tempDir()
        let source = dir.appendingPathComponent("stable-src.png")
        guard let image = makeTestImage(width: 640, height: 420),
              let dest = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil) else {
            check(false, "估算稳定性样本")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest), let loaded = try? ImageEngine.load(url: source) else { return }

        func bytes(quality: Double) -> Int64? {
            var options = ConvertOptions(format: Formats.primary[0])   // JPG
            options.resizeMode = .original
            options.quality = quality
            return try? ImageEngine.estimate(loaded: loaded, options: options).bytes
        }

        let first = bytes(quality: 0.85)
        let second = bytes(quality: 0.85)
        check(first != nil && first == second, "同一参数两次估算一致",
              detail: "\(first.map(Fmt.bytes) ?? "nil") / \(second.map(Fmt.bytes) ?? "nil")")

        let lower = bytes(quality: 0.5)
        if let first, let lower {
            check(lower < first, "参数变化反映到预估值",
                  detail: "q85 \(Fmt.bytes(first)) → q50 \(Fmt.bytes(lower))")
        } else {
            check(false, "参数变化反映到预估值")
        }
    }

    /// 预览图必须真的带压缩痕迹 —— 这是「质量拖到 5% 但两张图看起来一样」那个 bug 的防线。
    ///
    /// 量法：把两张预览各用 PNG（无损）重新编码一遍。低质量那张细节少、块效应多，
    /// PNG 压出来反而更小。如果两者字节一样，说明预览拿的还是编码前的原始图。
    private static func previewShowsCompression() {
        let dir = tempDir()
        let source = dir.appendingPathComponent("preview-src.png")
        guard let image = makeTestImage(width: 800, height: 560),
              let dest = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil) else {
            check(false, "预览压缩样本")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest), let loaded = try? ImageEngine.load(url: source) else { return }

        func preview(quality: Double) -> (bytes: Int64, png: Int)? {
            var options = ConvertOptions(format: Formats.primary[0])   // JPG
            options.resizeMode = .original
            options.quality = quality
            guard let result = try? ImageEngine.estimate(loaded: loaded, options: options),
                  let cg = ImageEngine.renderPreview(loaded: loaded, options: options),
                  let png = pngSize(cg) else { return nil }
            return (result.bytes, png)
        }

        guard let low = preview(quality: 0.05), let high = preview(quality: 0.95) else {
            check(false, "预览压缩样本可解码")
            return
        }
        check(low.png < high.png, "预览图反映压缩劣化",
              detail: "q5 细节 \(Fmt.bytes(Int64(low.png))) < q95 \(Fmt.bytes(Int64(high.png)))")
    }

    /// 合成对比图：一张画布，左半取原图、右半取结果，橙线在正中。
    /// 关键断言是「接缝两侧内容对齐」—— 早先做成了左右各塞一张完整缩图，两边内容对不上。
    private static func comparisonComposite() {
        // 渐变图：左半偏橙、右半偏蓝，缩放到 600×400 后位置信息仍然可分
        guard let source = makeTestImage(width: 600, height: 400) else {
            check(false, "对比图样本")
            return
        }
        // 「之后」：把同一张图重编码一次，模拟另一种画质
        let before = ImageEngine.previewImage(source, maxPixel: 600)
        guard let composed = ImageEngine.composeComparison(before: before, after: source) else {
            check(false, "对比图合成")
            return
        }
        check(composed.width == source.width && composed.height == source.height,
              "对比图就是一张正片大小的图",
              detail: "\(composed.width)×\(composed.height)")

        let seam = composed.width / 2
        let gap = max(2, Int((Double(composed.width) * 0.006).rounded()))
        check(composed.width > gap * 3, "橙线宽度合理", detail: "\(gap) px")

        guard let data = composed.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            check(false, "对比图可读像素")
            return
        }
        let bpp = composed.bitsPerPixel / 8
        let rowBytes = composed.bytesPerRow
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * rowBytes + x * bpp
            return (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
        }

        // 橙线在正中
        let y = composed.height / 2
        var orange = false
        for x in (seam - gap)..<(seam + gap) where x >= 0 && x < composed.width {
            let (r, g, b) = pixel(x, y)
            if r > 200 && (60...210).contains(g) && b < 110 { orange = true; break }
        }
        check(orange, "橙线居中且为强调色")

        // 接缝左侧应是原图像素、右侧应是结果像素：拿同一坐标的源图对比
        let probeY = composed.height / 4
        let leftX = seam - gap - 20
        let rightX = seam + gap + 20
        guard let srcData = source.dataProvider?.data, let srcBytes = CFDataGetBytePtr(srcData) else {
            check(false, "源图可读像素")
            return
        }
        let srcBpp = source.bitsPerPixel / 8
        let srcRow = source.bytesPerRow
        func sourcePixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * srcRow + x * srcBpp
            return (Int(srcBytes[o]), Int(srcBytes[o + 1]), Int(srcBytes[o + 2]))
        }
        func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            abs(a.0 - b.0) <= 8 && abs(a.1 - b.1) <= 8 && abs(a.2 - b.2) <= 8
        }
        check(close(pixel(leftX, probeY), sourcePixel(leftX, probeY)), "左半是转换前的像素")
        check(close(pixel(rightX, probeY), sourcePixel(rightX, probeY)), "右半是转换后的像素")
    }

    /// 用 PNG 重编码一遍，拿字节数当「细节量」的代理指标
    private static func pngSize(_ image: CGImage) -> Int? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer.length
    }

    /// EPS 输入。系统没有任何 PostScript 解释器，只能靠 Ghostscript；
    /// 装了就必须真的渲染出正确尺寸，没装就必须给出「去装 Ghostscript」这句人话。
    private static func postScriptInput() {
        let url = tempDir().appendingPathComponent("probe.eps")
        let eps = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 240 120
        %%EndComments
        newpath 0 0 moveto 240 0 lineto 240 120 lineto 0 120 lineto closepath
        0.92 0.25 0.15 setrgbcolor fill
        showpage
        """
        try? eps.data(using: .utf8)?.write(to: url)

        guard PostScript.isAvailable else {
            check(true, "EPS 被识别（未装 Ghostscript，只验识别）",
                  detail: "缺 gs，用户会看到安装提示")
            do {
                _ = try ImageEngine.load(url: url)
                check(false, "没装 Ghostscript 时应该报错")
            } catch {
                let text = error.localizedDescription
                check(text.contains("Ghostscript"), "缺 Ghostscript 的提示可读", detail: text)
            }
            return
        }

        check(Formats.isSupportedInput(url), "EPS 被识别为受支持输入")
        // plan 与实际渲染必须一致，否则网格上的「原始尺寸」会对不上对比视图
        let (_, planned) = PostScript.plan(url: url, maxPixel: 2400)
        do {
            let loaded = try ImageEngine.load(url: url)
            check(loaded.image.width == Int(planned.width) && loaded.image.height == Int(planned.height),
                  "EPS 渲染尺寸与预算一致",
                  detail: "\(loaded.image.width)×\(loaded.image.height)")
            // 那张 EPS 铺满红色块，渲出来必须不是一张白纸
            let mean = meanColor(loaded.image)
            check(mean.g < 200, "EPS 内容真的画出来了",
                  detail: String(format: "平均色 (%.0f, %.0f, %.0f)", mean.r, mean.g, mean.b))
        } catch {
            check(false, "EPS 渲染", detail: error.localizedDescription)
        }
    }

    /// 采样若干点求平均色（用来确认 EPS 不是渲染成一张白纸）
    private static func meanColor(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let w = min(image.width, 200), h = min(image.height, 200)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (255, 255, 255) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return (255, 255, 255) }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            r += Double(p[i]); g += Double(p[i + 1]); b += Double(p[i + 2])
        }
        let n = Double(w * h)
        return (r / n, g / n, b / n)
    }

    /// JPEG XL。系统 ImageIO 只能解、不能写，输出必须靠 cjxl：
    /// 装了就要能编出系统认得的容器，没装就必须给出「brew install jpeg-xl」这句人话。
    private static func jxlRoundTrip() {
        guard let image = makeTestImage(width: 320, height: 240) else {
            check(false, "JXL 测试图生成")
            return
        }
        guard JXLEncoder.isAvailable else {
            check(true, "JPEG XL 已进格式表（未装 cjxl）", detail: "缺 cjxl，转换时会提示安装")
            do {
                _ = try JXLEncoder.encode(image, quality: 0.8, name: "JPEG XL")
                check(false, "缺 cjxl 时应该报错")
            } catch {
                check(error.localizedDescription.contains("jpeg-xl"),
                      "缺 cjxl 的提示可读", detail: error.localizedDescription)
            }
            return
        }
        do {
            let data = try JXLEncoder.encode(image, quality: 0.9, name: "JPEG XL")
            // 顺手报一下用的是包内那份还是系统装的那份，诊断用
            let tool = JXLEncoder.toolPath() ?? "-"
            let bundled = tool.hasPrefix(Bundle.main.bundleURL.path)
            check(data.count > 100, "JXL 编码",
                  detail: "\(Fmt.bytes(Int64(data.count))) · \(bundled ? "包内 cjxl" : "系统 cjxl")")
            // 用系统解码器读回来 —— 能解说明产出的容器是合法的
            let decoded = ImageEngine.decodedPreview(data: data, maxPixel: 1000)
            check(decoded?.width == 320 && decoded?.height == 240, "JXL 能被系统解码回来",
                  detail: decoded.map { "\($0.width)×\($0.height)" } ?? "解不出")
        } catch {
            check(false, "JXL 编码", detail: error.localizedDescription)
        }
    }

    /// 同名文件不能覆盖源图
    private static func noOverwrite() {
        let dir = tempDir()
        let source = dir.appendingPathComponent("photo.png")
        try? "x".data(using: .utf8)?.write(to: source)
        let target = ImageEngine.outputURL(for: source, format: Formats.primary[0], options: ConvertOptions(format: Formats.primary[0]))
        check(target.lastPathComponent == "photo.jpg", "换格式不加序号", detail: target.lastPathComponent)

        try? "x".data(using: .utf8)?.write(to: target)
        let second = ImageEngine.outputURL(for: source, format: Formats.primary[0], options: ConvertOptions(format: Formats.primary[0]))
        check(second.lastPathComponent != target.lastPathComponent && second.lastPathComponent.contains("2"),
              "重名自动加序号", detail: second.lastPathComponent)

        if let png = Formats.format(ext: "png") {
            let same = ImageEngine.outputURL(for: source, format: png, options: ConvertOptions(format: png))
            check(same.standardizedFileURL != source.standardizedFileURL, "同格式也不覆盖源文件",
                  detail: same.lastPathComponent)
        }
    }

    // MARK: 诊断入口

    /// 把「解码 → 预估（含预览）→ 合成对比图」整条链路跑一遍并落盘，
    /// 顺便把两边各自的高频能量打出来 —— 用来确认预览到底有没有带压缩痕迹。
    static func compareProbe(source: URL, output: URL, quality: Double) -> Bool {
        guard let loaded = try? ImageEngine.load(url: source) else {
            print("✗ 读不了 \(source.path)")
            return false
        }
        var options = ConvertOptions(format: Formats.primary[0])
        options.resizeMode = .original
        options.quality = quality
        guard let estimated = try? ImageEngine.estimate(loaded: loaded, options: options) else {
            print("✗ 预估失败")
            return false
        }
        let before = ImageEngine.loadThumbnail(url: source, maxPixel: 2600) ?? loaded.image
        guard let after = ImageEngine.renderPreview(loaded: loaded, options: options, maxPixel: 2600) else {
            print("✗ 预览渲染失败")
            return false
        }
        print("源 \(loaded.image.width)×\(loaded.image.height)  after \(estimated.pixel.width)×\(estimated.pixel.height)")
        print("预估 \(Fmt.bytes(estimated.bytes))  before \(before.width)×\(before.height)  after \(after.width)×\(after.height)")
        print(String(format: "边缘能量 before %.3f / after %.3f", edgeEnergy(before), edgeEnergy(after)))
        guard let composed = ImageEngine.composeComparison(before: before, after: after) else {
            print("✗ 合成失败")
            return false
        }
        print("合成 \(composed.width)×\(composed.height)")
        if let png = pngData(composed) {
            try? png.write(to: output)
            print("已写入 \(output.path)")
        }
        return true
    }

    private static func edgeEnergy(_ image: CGImage) -> Double {
        let w = min(image.width, 900), h = min(image.height, 700)
        guard w > 2, h > 2,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = 0.0, n = 0.0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                let i = (y * w + x) * 4, j = i + 4
                let a = 0.299 * Double(p[i]) + 0.587 * Double(p[i+1]) + 0.114 * Double(p[i+2])
                let b = 0.299 * Double(p[j]) + 0.587 * Double(p[j+1]) + 0.114 * Double(p[j+2])
                sum += abs(a - b); n += 1
            }
        }
        return n > 0 ? sum / n : 0
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }

    // MARK: 工具

    private static func encode(_ image: CGImage, format: OutputFormat, quality: Double, to url: URL) throws {
        if format.usesLibWebP {
            try WebPEncoder.write(image, to: url, quality: quality)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.uti as CFString, 1, nil) else {
            throw ImageEngineError.encodeFailed(format.name)
        }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageEngineError.encodeFailed(format.name)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 渐变 + 圆点：纯色图在很多编码器里会命中极端优化，测不出质量问题
        let colors = [CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 1),
                      CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                                   options: [])
        }
        for i in 0..<80 {
            let x = CGFloat((i * 73) % width)
            let y = CGFloat((i * 37) % height)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: CGFloat(i % 7) / 10.0 + 0.3))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: CGFloat(12 + i % 18), height: CGFloat(12 + i % 18)))
        }
        return ctx.makeImage()
    }

    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boxpic-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
