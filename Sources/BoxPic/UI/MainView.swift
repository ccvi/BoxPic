import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 主界面

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            titleRow
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 6)

            stage
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ControlBar()
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Theme.ink)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .top) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: 标题行

    private var titleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.filters")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("BoxPic")
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if !model.tasks.isEmpty {
                Text("\(model.tasks.count) 个文件")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                if model.doneCount > 0 {
                    Text("· \(model.doneCount) 已完成")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                }
            }

            Spacer()

            if model.isRunning {
                Text("\(model.progress.done)/\(model.progress.total)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
            }

            if let toast = model.toast, !model.isRunning {
                Button {
                    model.revealLastOutput()
                } label: {
                    Label(toast, systemImage: "folder")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
            }

            iconButton("plus", help: "添加图片（⌘O）") { model.presentOpenPanel() }
            if !model.tasks.isEmpty {
                iconButton("arrow.counterclockwise", help: "重置结果") { model.resetResults() }
                iconButton("trash", help: "清空列表") { model.clear() }
            }
        }
        .frame(height: 22)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 舞台

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.stage)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)

            if let task = model.previewTask {
                CompareView(task: task, options: model.prefs.convertOptions()) {
                    model.previewID = nil
                }
                .transition(.opacity)
            } else if model.tasks.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)

            VStack(spacing: 6) {
                Text("把图片拖进来")
                    .font(Theme.ui(17, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("支持 \(Formats.inputFormatCount) 种输入格式 · 可输出 \(Formats.all.count) 种格式")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.textTertiary)
            }

            Button {
                model.presentOpenPanel()
            } label: {
                Text("选择文件")
                    .font(Theme.ui(12, weight: .medium))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
            .buttonStyle(.plain)

            Text("JPEG · HEIC · AVIF · WEBP · PNG · TIFF · RAW · SVG · PSD …")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashedBorder(cornerRadius: 14, active: isDropTargeted)
        .padding(14)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 216, maximum: 300), spacing: 14)],
                      spacing: 14) {
                ForEach(model.tasks) { task in
                    ThumbnailCard(task: task,
                                  isRunning: model.isRunning,
                                  onPreview: { model.previewID = task.id },
                                  onRemove: { model.remove(id: task.id) })
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
    }

    // MARK: 拖放

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else {
                    // 部分应用只在 file-url（Data）里给路径
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            lock.lock()
                            urls.append(url)
                            lock.unlock()
                        }
                        group.leave()
                    }
                    return
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let files = urls.filter { !$0.hasDirectoryPath }
            var collected: [URL] = []
            for file in files {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
                    // 拖进来的是文件夹：把里面的图片都捞出来（只下一层，别把整块盘卷进来）
                    if let children = try? FileManager.default.contentsOfDirectory(at: file,
                                                                                   includingPropertiesForKeys: nil,
                                                                                   options: [.skipsHiddenFiles]) {
                        collected.append(contentsOf: children.filter { Formats.isSupportedInput($0) })
                    }
                } else {
                    collected.append(file)
                }
            }
            model.add(urls: collected)
            if collected.isEmpty {
                model.lastError = "没有找到可识别的图片文件"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if model.lastError == "没有找到可识别的图片文件" { model.lastError = nil }
            }
        }
        return true
    }
}
