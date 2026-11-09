import SwiftUI

// MARK: - 网格里的缩略图卡片

struct ThumbnailCard: View {
    let task: PictureTask
    let isRunning: Bool
    let onPreview: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            infoArea
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? Theme.hairlineStrong : Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering && !isRunning {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("从这个列表移除")
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPreview)
        .help("点击查看转换前后对比")
    }

    private var imageArea: some View {
        ZStack {
            Color.black
            if let cg = task.thumbnail {
                Image(decorative: cg, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }

            if case .running = task.status {
                Color.black.opacity(0.45)
                ProgressView().controlSize(.small)
            }
            if case .failed = task.status {
                VStack(spacing: 4) {
                    Image(systemName: "xmark.octagon")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.danger)
                    Text(failureText)
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
        }
        .frame(height: 172)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var failureText: String {
        if case .failed(let message) = task.status { return message }
        return "转换失败"
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(task.sourceURL.lastPathComponent)
                .font(Theme.ui(11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            // 体积：3.5 MB → 633 kB（还没转换的是预估值，带 ≈ 前缀）
            HStack(spacing: 5) {
                Text(Fmt.bytes(task.originalBytes))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                if let change = task.byteChange {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                    Tag(text: change.estimated ? "≈ \(change.after)" : change.after,
                        tint: Theme.accent,
                        filled: true)
                } else if task.estimating {
                    Text("计算中…")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            // 尺寸：4,000 × 3,000 → 2,000 × 1,500
            HStack(spacing: 5) {
                Text(Fmt.pixels(task.originalPixel))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                if let change = task.pixelChange {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                    Tag(text: change.after, tint: Theme.accent, filled: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55))
    }
}

/// 小胶囊标签
struct Tag: View {
    let text: String
    var tint: Color = Theme.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(Theme.mono(10, weight: .semibold))
            .foregroundStyle(filled ? Color.black : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(filled ? .clear : tint.opacity(0.4), lineWidth: 0.8)
            )
    }
}
