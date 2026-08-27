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
            }
        }
        .navigationTitle("源片段（\(clips.count)）")
        .navigationBarTitleDisplayMode(.inline)
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
                    Image(systemName: exists ? "play.circle.fill" : "questionmark.circle")
                        .font(.title2)
                        .foregroundStyle(exists ? Color.accentColor : .secondary)
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
        .disabled(!exists)
        .foregroundStyle(exists ? .primary : .secondary)
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
