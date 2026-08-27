import SwiftUI
import SwiftData

/// 成品列表：缩略图 + 参数摘要 + 收藏/上传状态，点击进详情。
struct RenderListView: View {
    let storage: FileStorageService

    @Query(sort: \RenderedVideo.createdAt, order: .reverse) private var renders: [RenderedVideo]
    @Environment(\.modelContext) private var modelContext
    @Environment(UploadQueue.self) private var uploadQueue
    @State private var batchMessage: String?

    var body: some View {
        Group {
            if renders.isEmpty {
                ContentUnavailableView(
                    "还没有成品",
                    systemImage: "film.stack",
                    description: Text("在源片段里选一条做效果并导出")
                )
            } else {
                List {
                    ForEach(renders) { render in
                        renderRow(render)
                    }
                    .onDelete(perform: deleteRenders)
                }
            }
        }
        .navigationTitle("成品（\(renders.count)）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    batchUploadPending()
                } label: {
                    Label("补传全部", systemImage: "icloud.and.arrow.up.fill")
                }
                .disabled(!uploadQueue.isEnabled)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { batchMessage != nil },
            set: { if !$0 { batchMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(batchMessage ?? "")
        }
    }

    /// 把所有「未上传 / 上传失败」的成品一次性排进队列
    /// （典型场景：先拍了片、后配好 COS，历史成品需要补传）。
    private func batchUploadPending() {
        guard uploadQueue.isEnabled else { return }
        var count = 0
        for render in renders {
            switch render.uploadState {
            case .none:
                uploadQueue.enqueue(render)
                count += 1
            case .failed:
                uploadQueue.retryNow(render)
                count += 1
            default:
                break
            }
        }
        batchMessage = count == 0 ? "没有需要补传的成品。" : "已把 \(count) 条排入上传队列。"
    }

    private func renderRow(_ render: RenderedVideo) -> some View {
        NavigationLink {
            RenderDetailView(render: render, storage: storage)
        } label: {
            HStack(spacing: 12) {
                VideoThumbnailView(url: storage.renderURL(fileName: render.fileName))
                VStack(alignment: .leading, spacing: 3) {
                    Text(render.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.medium))
                    Text(render.settingsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if render.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        if render.uploadState != .none {
                            Label(render.uploadState.displayName,
                                  systemImage: render.uploadState.iconName)
                                .font(.caption2)
                                .foregroundStyle(render.uploadState == .failed ? .red : .secondary)
                        }
                    }
                }
            }
        }
    }

    private func deleteRenders(at offsets: IndexSet) {
        for index in offsets {
            let render = renders[index]
            storage.deleteFileIfExists(at: storage.renderURL(fileName: render.fileName))
            modelContext.delete(render)
        }
        try? modelContext.save()
    }
}
