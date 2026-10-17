import SwiftUI
import UIKit
import AVFoundation

/// 电视专用画面，由外接屏幕窗口承载；不复用手机相机预览。
@MainActor
struct ExternalWallView: View {
    @State private var controller = ExternalWallController.shared
    @State private var isVideoReady = false

    var body: some View {
        GeometryReader { geometry in
            let layout = ExternalWallLayout(size: geometry.size)
            ZStack {
                Color.black
                wallContent(layout: layout)
                    .frame(width: layout.width, height: layout.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func wallContent(layout: ExternalWallLayout) -> some View {
        if !controller.isEnabled {
            placeholder(
                title: "电视大屏未开启",
                detail: "请在手机的 Booth360 设置中开启独立电视大屏。",
                symbol: "tv",
                layout: layout
            )
        } else if let item = controller.currentItem {
            playbackContent(item: item, layout: layout)
        } else {
            placeholder(
                title: "等待最新成片",
                detail: "在手机拍摄完成后，视频会在这里自动播放。",
                symbol: "video",
                layout: layout
            )
        }
    }

    private func playbackContent(item: ExternalWallItem, layout: ExternalWallLayout) -> some View {
        HStack(spacing: layout.gap) {
            videoColumn(item: item, layout: layout)
                .frame(width: layout.videoColumnWidth)
            downloadColumn(item: item, layout: layout)
                .frame(width: layout.downloadColumnWidth)
        }
        .padding(layout.padding)
    }

    private func videoColumn(item: ExternalWallItem, layout: ExternalWallLayout) -> some View {
        VStack(spacing: layout.scaled(20)) {
            VStack(spacing: layout.scaled(9)) {
                Text(item.eventName.isEmpty ? "360 环拍精彩回放" : item.eventName)
                    .font(.system(size: layout.scaled(38), weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .multilineTextAlignment(.center)
                Text("精彩回放 · \(item.createdAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: layout.scaled(23)))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(height: layout.scaled(100))

            ExternalWallPlayerLayerView(player: controller.player, isReady: $isVideoReady)
                // Do not retain the previous video's last frame next to a new QR.
                .id(item.id)
                .background(.black)
                .overlay {
                    if !isVideoReady {
                        VStack(spacing: layout.scaled(18)) {
                            ProgressView().tint(.white)
                                .scaleEffect(max(1, layout.scale))
                            Text("正在准备视频…")
                                .font(.system(size: layout.scaled(26)))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if controller.isPlaybackHeld {
                        Label("播放暂时暂停", systemImage: "pause.fill")
                            .font(.system(size: layout.scaled(23), weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, layout.scaled(22))
                            .padding(.vertical, layout.scaled(12))
                            .background(.black.opacity(0.8), in: Capsule())
                            .padding(.bottom, layout.scaled(20))
                    }
                }
                .accessibilityLabel("当前环拍视频")
        }
    }

    private func downloadColumn(item: ExternalWallItem, layout: ExternalWallLayout) -> some View {
        VStack(spacing: layout.scaled(24)) {
            Spacer(minLength: 0)
            Text("扫码下载视频")
                .font(.system(size: layout.scaled(48), weight: .bold))
                .foregroundStyle(.white)
            Text("把这一刻带走")
                .font(.system(size: layout.scaled(27)))
                .foregroundStyle(.white.opacity(0.7))

            qrCard(item: item, layout: layout)

            Text(item.qrPayload == nil ? "成片正在准备下载链接" : "打开微信扫一扫，保存到相册")
                .font(.system(size: layout.scaled(27), weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(controller.statusText)
                .font(.system(size: layout.scaled(22)))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, layout.scaled(10))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func qrCard(item: ExternalWallItem, layout: ExternalWallLayout) -> some View {
        if item.qrPayload != nil, let image = controller.qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: layout.qrSize, height: layout.qrSize)
                .padding(layout.qrQuietZone)
                .background(.white, in: RoundedRectangle(cornerRadius: layout.scaled(20)))
                .accessibilityLabel("当前视频下载二维码")
        } else {
            VStack(spacing: layout.scaled(22)) {
                Image(systemName: "qrcode")
                    .font(.system(size: layout.scaled(90)))
                    .foregroundStyle(.white.opacity(0.35))
                Text(item.qrPayload == nil ? "上传完成后可扫码下载" : "正在准备下载二维码")
                    .font(.system(size: layout.scaled(27), weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .frame(width: layout.qrSize, height: layout.qrSize)
            .padding(layout.qrQuietZone)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: layout.scaled(20)))
        }
    }

    private func placeholder(title: String, detail: String, symbol: String, layout: ExternalWallLayout) -> some View {
        VStack(spacing: layout.scaled(28)) {
            Image(systemName: symbol)
                .font(.system(size: layout.scaled(96), weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text(title)
                .font(.system(size: layout.scaled(46), weight: .semibold))
            Text(detail)
                .font(.system(size: layout.scaled(28)))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Text(controller.statusText)
                .font(.system(size: layout.scaled(23)))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(layout.scaled(96))
    }
}

private struct ExternalWallLayout {
    let scale: CGFloat

    init(size: CGSize) {
        scale = max(0.01, min(size.width / 1920, size.height / 1080))
    }

    var width: CGFloat { scaled(1920) }
    var height: CGFloat { scaled(1080) }
    var padding: CGFloat { scaled(64) }
    var gap: CGFloat { scaled(80) }
    var videoColumnWidth: CGFloat { scaled(1000) }
    var downloadColumnWidth: CGFloat { width - padding * 2 - gap - videoColumnWidth }
    var qrSize: CGFloat { scaled(460) }
    var qrQuietZone: CGFloat { scaled(30) }

    func scaled(_ value: CGFloat) -> CGFloat { value * scale }
}

/// 只承载同一个播放器的本地画面；不提供媒体路由选择或创建额外播放器。
@MainActor
private struct ExternalWallPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    @Binding var isReady: Bool

    func makeUIView(context: Context) -> ExternalWallPlayerSurface {
        let view = ExternalWallPlayerSurface(frame: .zero)
        view.playerLayer.player = player
        context.coordinator.observe(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: ExternalWallPlayerSurface, context: Context) {
        context.coordinator.isReady = $isReady
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = .resizeAspect
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isReady: $isReady)
    }

    static func dismantleUIView(_ uiView: ExternalWallPlayerSurface, coordinator: Coordinator) {
        coordinator.stopObserving()
        uiView.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        var isReady: Binding<Bool>
        private var observation: NSKeyValueObservation?
        private var observationID: UUID?

        init(isReady: Binding<Bool>) {
            self.isReady = isReady
        }

        func observe(_ layer: AVPlayerLayer) {
            stopObserving()
            let id = UUID()
            observationID = id
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor [weak self] in
                    guard let self, self.observationID == id else { return }
                    self.isReady.wrappedValue = ready
                }
            }
        }

        func stopObserving() {
            observationID = nil
            observation?.invalidate()
            observation = nil
        }
    }
}

@MainActor
private final class ExternalWallPlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }
}
