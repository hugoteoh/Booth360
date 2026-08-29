import SwiftUI
import SwiftData
import AVKit

/// 源片段列表：验证录制结果用（正式 Gallery 在 Phase 3）。
/// 支持播放、删除；文件缺失时标灰提示。
struct ClipListView: View {
    let storage: FileStorageService

    @Query(sort: \SourceClip.createdAt, order: .reverse) private var clips: [SourceClip]
    @Environment(\.modelContext) private var modelContext
    @State private var playingURL: IdentifiableURL?
    /// 列表编辑模式（显式删除入口；左滑删除仍然可用）。
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Group {
            if clips.isEmpty {
                ContentUnavailableView(
                    "还没有片段",
                    systemImage: "video",
                    description: Text("回到拍摄页录一段试试")
                )
            } else {
                List {
                    ForEach(clips) { clip in
                        clipRow(clip)
                    }
                    .onDelete(perform: deleteClips)
                }
                .environment(\.editMode, $editMode)
            }
        }
        .navigationTitle("源片段（\(clips.count)）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !clips.isEmpty {
                    Button(editMode == .active ? "完成" : "编辑") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                }
            }
        }
        .sheet(item: $playingURL) { item in
            VideoPlayerSheet(url: item.url)
        }
    }

    private func clipRow(_ clip: SourceClip) -> some View {
        let url = storage.sourceClipURL(fileName: clip.fileName)
        let exists = storage.fileExists(at: url)
        let sizeMB = Double(storage.fileSizeInBytes(at: url)) / 1_000_000

        return NavigationLink {
            EditView(clip: clip, storage: storage)
        } label: {
            HStack(spacing: 12) {
                Button {
                    if exists { playingURL = IdentifiableURL(url: url) }
                } label: {
                    ZStack {
                        VideoThumbnailView(url: url, width: 64, height: 114)
                        if exists {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                    }
                }
                .buttonStyle(.borderless)

                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.createdAt.formatted(date: .abbreviated, time: .standard))
                        .font(.subheadline.weight(.medium))
                    Text(exists
                         ? "\(clip.summaryText) · \(String(format: "%.0f", sizeMB)) MB"
                         : "文件缺失")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!exists && editMode != .active)
        .foregroundStyle(exists ? .primary : .secondary)
        .contextMenu {
            if exists {
                Button {
                    playingURL = IdentifiableURL(url: url)
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
            }
            Button(role: .destructive) {
                delete(clip)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                delete(clip)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 删除源片段：连同视频文件一起删（已生成的成品不受影响）。
    private func delete(_ clip: SourceClip) {
        storage.deleteFileIfExists(at: storage.sourceClipURL(fileName: clip.fileName))
        modelContext.delete(clip)
        try? modelContext.save()
    }

    private func deleteClips(at offsets: IndexSet) {
        for index in offsets {
            let clip = clips[index]
            storage.deleteFileIfExists(at: storage.sourceClipURL(fileName: clip.fileName))
            modelContext.delete(clip)
        }
        try? modelContext.save()
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 简单全屏播放器。
private struct VideoPlayerSheet: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            .onDisappear {
                player?.pause()
            }
    }
}
