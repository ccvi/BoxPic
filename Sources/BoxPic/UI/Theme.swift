import SwiftUI

// MARK: - 视觉规范
//
// 照着参考图来的：纯黑舞台 + 一条贯穿底部的虚线 + 胶囊控件 + 橙色条纹的质量条。
// 所有颜色写在这里，别在视图里散落硬编码。

enum Theme {
    static let ink = Color(hex: 0x0A0A0A)          // 窗口底
    static let stage = Color(hex: 0x0E0E0E)        // 舞台（图片区）底
    static let bar = Color(hex: 0x111111)          // 底部控制条
    static let card = Color(hex: 0x161616)         // 卡片底

    static let hairline = Color.white.opacity(0.16)
    static let hairlineStrong = Color.white.opacity(0.30)

    static let accent = Color(hex: 0xFF9F0A)       // 橙
    static let accentDim = Color(hex: 0x6B4A12)
    static let accentSoft = Color(hex: 0xFFB84D)

    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.34)

    static let danger = Color(hex: 0xFF5F56)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }
}

// MARK: - 通用零件

/// 控制条上的胶囊：文字 + 上下小箭头（参考图里每个控件都是这个形状）
struct Pill<Content: View>: View {
    var highlighted: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Theme.accent.opacity(0.16) : Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(highlighted ? Theme.accent.opacity(0.85) : Theme.hairlineStrong,
                              lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 胶囊右侧那个「⌃⌄」指示符
struct PillChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// 控制条上的标签（格式 / 调整大小模式 / 大小 / 元数据 / 质量）
struct BarLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.ui(11))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// 虚线连接段：把各控件串成一根线。
/// 宽度交给 HStack 分配（maxWidth: .infinity），这样控件能铺满整条控制条，
/// 而不是挤在中间留一大片黑。
struct DashedLink: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 3
            while x < size.width - 1 {
                context.fill(Path(CGRect(x: x, y: 0, width: 2.5, height: 1.2)),
                             with: .color(Color.white.opacity(0.42)))
                x += 7
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 1.2)
        .padding(.horizontal, 6)
    }
}

/// 质量条纹条（参考图里那条橙色竖纹）。
/// 一格 = 5%，20 格到满。拖动按格吸附，不会出现 94 这种莫名其妙的值。
struct QualityStripes: View {
    @Binding var value: Double        // 0...1，实际只取 0.05 的整数倍
    var enabled: Bool = true

    static let stepCount = 20
    private var filledCount: Int { Int((value * Double(Self.stepCount)).rounded()) }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(Self.stepCount - 1)) / CGFloat(Self.stepCount))
            HStack(spacing: spacing) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < filledCount
                              ? (enabled ? Theme.accent : Theme.hairlineStrong)
                              : (enabled ? Theme.accentDim.opacity(0.55) : Theme.hairline))
                        .frame(width: barWidth, height: 16)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard enabled else { return }
                        // 以「落在第几格」为准，最少 1 格（5%），最多 20 格（100%）
                        let raw = drag.location.x / geo.size.width * CGFloat(Self.stepCount)
                        let steps = min(max(Int(raw.rounded(.up)), 1), Self.stepCount)
                        value = Double(steps) / Double(Self.stepCount)
                    }
            )
        }
        .frame(width: 150, height: 18)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// 空状态的虚线框
struct DashedBorder: ViewModifier {
    var cornerRadius: CGFloat = 14
    var active: Bool = false

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    active ? Theme.accent : Theme.hairline,
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
                )
        )
    }
}

extension View {
    func dashedBorder(cornerRadius: CGFloat = 14, active: Bool = false) -> some View {
        modifier(DashedBorder(cornerRadius: cornerRadius, active: active))
    }
}
