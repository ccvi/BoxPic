import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 底部控制条
//
// 参考图的结构：一行胶囊控件，用虚线串起来，最右边是橙色的执行键。
// 从左到右：格式 → 调整大小模式 → 大小 → 元数据 → 质量 → 输出目录 → ▶

struct ControlBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showSizePopover = false
    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var customValue = ""

    private var prefs: Preferences { model.prefs }

    var body: some View {
        HStack(spacing: 0) {
            control("格式") {
                formatMenu
            }
            DashedLink()
            control("调整大小模式") {
                modeMenu
            }
            DashedLink()
            control("大小") {
                sizeMenu
            }
            DashedLink()
            control("元数据") {
                metadataToggle
            }
            DashedLink()
            control("质量") {
                qualityControl
            }
            DashedLink()
            control("输出位置") {
                outputControl
            }
            DashedLink()
            convertButton
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.bar)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        )
    }

    // MARK: 每个格子的统一外壳（标签在上，控件在下）

    @ViewBuilder
    private func control<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 5) {
            BarLabel(text: label)
            content()
        }
        .fixedSize()
    }

    // MARK: 格式

    private var formatMenu: some View {
        Menu {
            ForEach(Formats.primary) { format in
                formatButton(format)
            }
            Divider()
            Menu("更多") {
                ForEach(Formats.extra) { format in
                    formatButton(format)
                }
            }
        } label: {
            Pill {
                Image(systemName: "diamond")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(prefs.format.name)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                PillChevron()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func formatButton(_ format: OutputFormat) -> some View {
        Button {
            model.prefs.formatID = format.id
        } label: {
            // 比的是解析后的 id：旧偏好里存的是纯 UTI，直接比字符串会导致「一个勾都不显示」
            if prefs.format.id == format.id {
                Label(menuTitle(format), systemImage: "checkmark")
            } else {
                Text(menuTitle(format))
            }
        }
    }

    /// JXL 要靠外部 cjxl 编码，没装时在菜单里就说清楚，别让用户选完才发现转不了
    private func menuTitle(_ format: OutputFormat) -> String {
        if format.isJXL && !JXLEncoder.isAvailable { return "\(format.name)（需 jpeg-xl）" }
        return format.name
    }

    // MARK: 调整大小模式

    private var modeMenu: some View {
        Menu {
            ForEach(ResizeMode.allCases) { mode in
                Button {
                    model.prefs.resizeMode = mode
                    seedCustomFields()
                } label: {
                    if prefs.resizeMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Pill {
                Image(systemName: modeIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(prefs.resizeMode.title)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textPrimary)
                PillChevron()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var modeIcon: String {
        switch prefs.resizeMode {
        case .original: return "arrow.left.and.right"
        case .maxWidth: return "arrow.left.and.right.square"
        case .maxHeight: return "arrow.up.and.down.square"
        case .percent: return "percent"
        case .exact: return "square.resize"
        }
    }

    // MARK: 大小

    private var sizeMenu: some View {
        Button {
            seedCustomFields()
            showSizePopover = true
        } label: {
            Pill(highlighted: prefs.resizeMode != .original) {
                Text(prefs.sizeLabel)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .disabled(prefs.resizeMode == .original)
        .help(prefs.resizeMode == .original ? "当前保持原始尺寸，先在「调整大小模式」里选一个" : "调整输出尺寸")
        .popover(isPresented: $showSizePopover, arrowEdge: .bottom) {
            sizeEditor
        }
    }

    private var sizeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prefs.resizeMode.title)
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(.primary)

            switch prefs.resizeMode {
            case .original:
                Text("保持原始像素尺寸")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            case .percent:
                HStack(spacing: 8) {
                    TextField("%", text: $customValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .onSubmit(applyCustomValue)
                    Text("%")
                        .font(Theme.ui(11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("应用", action: applyCustomValue)
                        .keyboardShortcut(.defaultAction)
                }
                percentPresets
            case .maxWidth, .maxHeight:
                HStack(spacing: 8) {
                    TextField("px", text: $customValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .onSubmit(applyCustomValue)
                    Text("px")
                        .font(Theme.ui(11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("应用", action: applyCustomValue)
                        .keyboardShortcut(.defaultAction)
                }
                limitPresets
            case .exact:
                HStack(spacing: 8) {
                    TextField("宽", text: $customWidth)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 68)
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("高", text: $customHeight)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 68)
                    Spacer(minLength: 0)
                    Button("应用", action: applyExact)
                        .keyboardShortcut(.defaultAction)
                }
                exactPresets
            }
        }
        .padding(14)
        .frame(width: 268)
    }

    private var percentPresets: some View {
        HStack(spacing: 6) {
            ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                Button(Fmt.percent(value)) {
                    model.prefs.percent = value
                    showSizePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var limitPresets: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([720, 1080, 1440, 1920, 2560, 3840], id: \.self) { value in
                Button {
                    model.prefs.limitValue = value
                    showSizePopover = false
                } label: {
                    HStack {
                        Text("\(Fmt.grouped(value)) px")
                            .font(Theme.mono(11))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var exactPresets: some View {
        HStack(spacing: 6) {
            ForEach([(1920, 1080), (1080, 1080), (1080, 1350), (1200, 630)], id: \.0) { pair in
                Button("\(pair.0)×\(pair.1)") {
                    model.prefs.exactWidth = pair.0
                    model.prefs.exactHeight = pair.1
                    showSizePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func seedCustomFields() {
        customValue = prefs.resizeMode == .percent
            ? String(format: "%.0f", prefs.percent * 100)
            : "\(prefs.limitValue)"
        customWidth = "\(prefs.exactWidth)"
        customHeight = "\(prefs.exactHeight)"
    }

    private func applyCustomValue() {
        let cleaned = customValue.filter { $0.isNumber }
        guard let value = Int(cleaned), value > 0 else { return }
        switch prefs.resizeMode {
        case .percent:
            model.prefs.percent = min(max(Double(value) / 100.0, 0.01), 4.0)
        case .maxWidth, .maxHeight:
            model.prefs.limitValue = min(max(value, 1), 20_000)
        default:
            break
        }
        showSizePopover = false
    }

    private func applyExact() {
        let w = Int(customWidth.filter { $0.isNumber }) ?? prefs.exactWidth
        let h = Int(customHeight.filter { $0.isNumber }) ?? prefs.exactHeight
        guard w > 0, h > 0 else { return }
        model.prefs.exactWidth = min(w, 20_000)
        model.prefs.exactHeight = min(h, 20_000)
        showSizePopover = false
    }

    // MARK: 元数据

    private var metadataToggle: some View {
        HStack(spacing: 0) {
            segment(title: "移除", active: !prefs.keepMetadata) {
                model.prefs.keepMetadata = false
            }
            segment(title: "保留", active: prefs.keepMetadata) {
                model.prefs.keepMetadata = true
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
        )
        .help("元数据包含 EXIF / GPS / 拍摄参数")
    }

    private func segment(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.black : Theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active ? Theme.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 质量

    private var qualityControl: some View {
        HStack(spacing: 8) {
            QualityStripes(value: $model.prefs.quality, enabled: prefs.format.qualityApplies)
            Text(prefs.format.qualityApplies ? "\(Int((prefs.quality * 100).rounded()))" : "无损")
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(prefs.format.qualityApplies ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 30, alignment: .leading)
        }
        .help(prefs.format.qualityApplies
              ? "压缩质量：越高越清晰、体积越大"
              : "\(prefs.format.name) 是无损格式，质量参数对它不起作用")
    }

    // MARK: 输出目录

    private var outputControl: some View {
        Button {
            chooseOutputDirectory()
        } label: {
            Pill {
                Image(systemName: prefs.outputDirectoryURL == nil ? "arrow.turn.down.right" : "folder")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(prefs.outputDirectoryURL == nil ? Theme.textSecondary : Theme.accent)
                Text(outputLabel)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(prefs.outputDirectoryURL?.path ?? "与源文件放在一起")
    }

    private var outputLabel: String {
        guard let dir = prefs.outputDirectoryURL else { return "原目录" }
        if dir.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").standardizedFileURL.path {
            return "桌面"
        }
        let name = dir.lastPathComponent
        return name.isEmpty ? "原目录" : name
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "转换后的图片保存到这里（取消则跟随源文件）"
        if let current = prefs.outputDirectoryURL {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.prefs.outputDirectory = url.path
        }
    }

    // MARK: 执行

    private var convertButton: some View {
        Button {
            model.convertAll()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.tasks.isEmpty ? Theme.hairline : Theme.accent)
                    .frame(width: 38, height: 30)
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(model.tasks.isEmpty ? Theme.textTertiary : Color.black)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.tasks.isEmpty || model.isRunning)
        .help("开始转换（⌘↩）")
        .keyboardShortcut(.return, modifiers: .command)
    }
}
