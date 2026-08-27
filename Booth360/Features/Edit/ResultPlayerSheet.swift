import SwiftUI
import AVKit

/// 预览/成品播放弹层：循环播放；成品模式下提供 分享 + 存相册。
struct ResultPlayerSheet: View {
    let presentation: EditViewModel.PlaybackPresentation
    let onSaveToPhotos: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?
    @State private var didSave = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(presentation.exportedURL == nil ? "效果预览" : "导出完成")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()

            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if let note = presentation.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }

            if let url = presentation.exportedURL {
                HStack(spacing: 14) {
                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        didSave = true
                        onSaveToPhotos(url)
                    } label: {
                        Label(didSave ? "已保存" : "存入相册",
                              systemImage: didSave ? "checkmark" : "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(didSave)
                }
                .padding()
            }
        }
        .onAppear { startPlayback() }
        .onDisappear { stopPlayback() }
    }

    private func startPlayback() {
        let player = AVPlayer(playerItem: presentation.playerItem)
        self.player = player
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: presentation.playerItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
    }

    private func stopPlayback() {
        player?.pause()
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = nil
    }
}
