import SwiftUI

@MainActor
struct FilesWorkspaceView: View {
    private struct Presentation: Identifiable {
        enum Kind { case importFile, preview(ManagedFilePresentation), export(ManagedFilePresentation) }
        let id = UUID()
        let kind: Kind
    }
    @Bindable var model: FilesWorkspaceModel
    let onClose: () -> Void
    @State private var presentation: Presentation?
    @State private var pendingRemoval: FileWorkspaceItem?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件").font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                Spacer()
                Button { presentation = Presentation(kind: .importFile) } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .disabled(model.isWorking).accessibilityLabel("导入文件").accessibilityIdentifier("files-import")
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭文件页面").accessibilityIdentifier("files-workspace-close")
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            List {
                if model.items.isEmpty, !model.isLoading {
                    Text("还没有文件").foregroundStyle(.secondary).accessibilityIdentifier("files-workspace-empty")
                }
                ForEach(model.items) { item in
                    HStack(spacing: 8) {
                        Button { present(item, export: false) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc").accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName).foregroundStyle(.primary).lineLimit(2)
                                    Text(details(item)).foregroundStyle(.secondary)
                                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("files-preview-\(item.id)")
                        Button { present(item, export: true) } label: {
                            Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("导出 \(item.displayName)").accessibilityIdentifier("files-export-\(item.id)")
                        Menu {
                            Button("删除", role: .destructive) { pendingRemoval = item }
                                .accessibilityIdentifier("files-remove-\(item.id)")
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("\(item.displayName) 的更多操作")
                    }
                    .buttonStyle(.borderless).disabled(model.isWorking)
                }
                if model.isLoading || model.isWorking { ProgressView() }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.secondary).accessibilityIdentifier("files-workspace-error")
                    Button("重新读取目录") { Task { await model.refresh(clearError: true) } }
                        .disabled(model.isWorking)
                } else if model.hasMore {
                    Button("加载更多") { Task { await model.loadMore() } }.disabled(model.isLoading || model.isWorking)
                }
            }
            .listStyle(.plain)
        }
        .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain).accessibilityIdentifier("files-workspace")
        .task { await model.refresh() }
        .sheet(item: $presentation) { item in
            switch item.kind {
            case .importFile:
                NativeFilePicker(mode: .importFile, onPick: { url in
                    if closePresentation(id: item.id) { Task { await model.importFile(at: url) } }
                }, onCancel: { _ = closePresentation(id: item.id) })
            case .preview(let copy):
                NativeFilePreview(copy: copy, onClose: { _ = closePresentation(id: item.id) })
            case .export(let copy):
                NativeFilePicker(mode: .export(copy), onPick: { _ in _ = closePresentation(id: item.id) },
                    onCancel: { _ = closePresentation(id: item.id) })
                    .accessibilityElement(children: .contain).accessibilityIdentifier("files-native-export")
            }
        }
        .confirmationDialog("删除文件？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            if let item = pendingRemoval {
                Button("删除 \(item.displayName)", role: .destructive) {
                    pendingRemoval = nil
                    Task { await model.removeAsset(id: item.id) }
                }
            }
        } message: { Text("被会话、草稿或待提交附件引用的文件会保留。") }
    }

    private func present(_ item: FileWorkspaceItem, export: Bool) {
        Task {
            guard let copy = await model.preparePresentation(id: item.id) else { return }
            presentation = Presentation(kind: export ? .export(copy) : .preview(copy))
        }
    }

    private func closePresentation(id: UUID) -> Bool {
        guard presentation?.id == id else { return false }
        presentation = nil; return true
    }

    private func details(_ item: FileWorkspaceItem) -> String {
        guard let bytes = item.byteCount else { return "版本信息不可用" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return item.mediaType.map { size + " · " + $0 } ?? size
    }
}
