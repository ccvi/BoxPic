import SwiftUI
import AppKit

// MARK: - 转换前后对比（点缩略图进来）
//
// 参考图：左边「之前」，中间大图，右边「之后」；点图回到缩略图网格。

struct CompareView: View {
    let task: PictureTask
    /// 还没真正转换时，「之后」要按这组参数现转一遍再解码 —— 没有参数就渲不出真实画质
    let options: ConvertOptions
    let onBack: () -> Void

    @State private var stageImage: CGImage?
    @State private var loading = true
    /// true = 按真实像素显示（看清压缩痕迹），false = 适应窗口
    @State private var actualPixels = false

    private var isDone: Bool { task.status.isDone }

    var body: some View {
        HStack(spacing: 18) {
            infoColumn(
                title: "之前：",
                name: task.sourceURL.lastPathComponent,
                size: Fmt.bytes(task.originalBytes),
                pixel: Fmt.pixels(task.originalPixel),
                highlight: false
            )
            .frame(width: 168, alignment: .leading)

            imageStage

            infoColumn(
                title: "之后：",
                name: outputName,
                size: outputSizeText,
                pixel: outputPixelText,
                highlight: isDone || task.estimate != nil
            )
            .frame(width: 168, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .overlay(alignment: .topLeading) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .bold))
                    Text("缩略图")
                        .font(Theme.ui(10))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("返回缩略图（Esc）")
        }
        // id 里带上「有没有预估值 / 有没有转换完」，估算结果回来时会自动重载
        .task(id: "\(task.id)-\(task.estimate?.bytes ?? -1)-\(task.status.isDone)") {
            await loadImages()
        }
        .onExitCommand(perform: onBack)
    }

    /// 1:1 = 一个图像像素对着一个屏幕物理像素。
    /// 这个视图是必需的：适应窗口时 900 px 的图被压到 55% 显示、2048 px 的图只剩 12%，
    /// 重采样会把块效应和色渗全部抹平 —— 质量拖到 5% 也看不出差别，用户会以为参数没生效。
    private var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    /// 把 1:1 视图滚到接缝（图像正中）。布局还没稳定时 scrollTo 会被丢掉，补一次。
    private func centerOnSeam(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("seam", anchor: .center)
        DispatchQueue.main.async {
            proxy.scrollTo("seam", anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            proxy.scrollTo("seam", anchor: .center)
        }
    }

    /// 已转换用真实文件名；还没转换就显示预计的文件名
    private var outputName: String {
        if let url = task.status.outputURL { return url.lastPathComponent }
        if let estimate = task.estimate { return estimate.outputName }
        return task.estimating ? "计算中…" : "—"
    }

    private var outputSizeText: String {
        if case .done(_, let bytes, _, _) = task.status { return Fmt.bytes(bytes) }
        if case .failed(let message) = task.status { return message }
        if let estimate = task.estimate { return "≈ \(Fmt.bytes(estimate.bytes))" }
        return task.estimating ? "计算中…" : "—"
    }

    private var outputPixelText: String {
        if case .done(_, _, let pixel, _) = task.status { return Fmt.pixels(pixel) }
        if let estimate = task.estimate { return Fmt.pixels(estimate.pixel) }
        return "—"
    }

    private func infoColumn(title: String, name: String, size: String, pixel: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textSecondary)
            Text(name)
                .font(Theme.ui(11, weight: .medium))
                .foregroundStyle(highlight ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Text(size)
                .font(Theme.mono(14, weight: .semibold))
                .foregroundStyle(highlight ? Theme.accent : Theme.textPrimary)
            Text(pixel)
                .font(Theme.mono(11))
                .foregroundStyle(highlight ? Theme.accent.opacity(0.9) : Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 22)
    }

    private var imageStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)

            if loading {
                ProgressView().controlSize(.small)
            } else if let stageImage {
                if actualPixels {
                    // 1:1：一个像素对一个屏幕物理像素，压缩痕迹在这个倍率下才是真实的。
                    // 进入时必须定位到正中 —— 橙线就是接缝，左右两半在这一处才挨在一起；
                    // 默认停在左上角只能看到左图的边角，什么也对比不出来。
                    GeometryReader { geo in
                        ScrollViewReader { proxy in
                            ScrollView([.horizontal, .vertical]) {
                                Image(decorative: stageImage, scale: backingScale)
                                    .overlay(alignment: .center) {
                                        Color.clear
                                            .frame(width: 1, height: 1)
                                            .id("seam")
                                    }
                                    .padding(10)
                                    // 图比窗口小时也要居中，否则会缩在左上角
                                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                            }
                            .defaultScrollAnchor(.center)
                            .onAppear { centerOnSeam(proxy) }
                        }
                    }
                } else {
                    // 一张拼好的图：左「之前」| 橙线 | 右「之后」。
                    // 不用两个并排的 Image —— 那样宽高比不同就会中间露黑缝、甚至一高一低。
                    Image(decorative: stageImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                }
            } else {
                Text("暂时没有可对比的图像")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if stageImage != nil && !loading {
                Button {
                    actualPixels.toggle()
                } label: {
                    Text(actualPixels ? "适应窗口" : "1:1")
                        .font(Theme.ui(10, weight: .medium))
                        .foregroundStyle(actualPixels ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .padding(10)
                .help(actualPixels ? "缩放到适应窗口" : "按真实像素查看，能看清压缩痕迹")
            }
        }
        .contentShape(Rectangle())
        // 1:1 时不要把点击当成「返回」，否则拖动画面查看细节会误触退出
        .onTapGesture { if !actualPixels { onBack() } }
    }

    private func loadImages() async {
        loading = true
        let sourceURL = task.sourceURL
        let outputURL = task.status.outputURL
        let options = self.options
        let composed = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            // 两边都取同样的上限，接缝两侧才对得齐
            let before = ImageEngine.loadThumbnail(url: sourceURL, maxPixel: 2600)
            let after: CGImage?
            if let outputURL {
                after = ImageEngine.loadThumbnail(url: outputURL, maxPixel: 2600)
            } else if let loaded = try? ImageEngine.load(url: sourceURL) {
                // 还没转换：按当前参数真的转一遍，再从编码后的字节解码 —— 这才是真实画质
                after = ImageEngine.renderPreview(loaded: loaded, options: options, maxPixel: 2600)
            } else {
                after = nil
            }
            switch (before, after) {
            case let (b?, a?):
                return ImageEngine.composeComparison(before: b, after: a) ?? b
            case let (b?, nil):
                return b
            case let (nil, a?):
                return a
            case (nil, nil):
                return nil
            }
        }.value
        stageImage = composed
        loading = false
    }
}
