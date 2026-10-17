import SwiftUI
import UIKit
import AVFoundation

/// 与网页大屏共用三种排版；只有当前卡片承载播放器，其余使用缓存静态画面。
@MainActor
struct ExternalWallView: View {
    @State private var controller = ExternalWallController.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                wallBackground(size: geometry.size)
                if !controller.isEnabled {
                    waitingView(title: "电视大屏未开启", detail: "在手机设置中开启独立电视大屏", size: geometry.size)
                } else if controller.items.isEmpty {
                    waitingView(title: "精彩即将开始…", detail: "Waiting for the first video…", size: geometry.size)
                } else {
                    wallCards(size: geometry.size)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var activeIndex: Int {
        controller.items.firstIndex { $0.id == controller.currentItem?.id } ?? 0
    }

    private func wallBackground(size: CGSize) -> some View {
        ZStack {
            Color(red: 6 / 255, green: 8 / 255, blue: 13 / 255)
            RadialGradient(
                stops: [.init(color: .clear, location: 0.62),
                        .init(color: .black.opacity(0.34), location: 1)],
                center: UnitPoint(x: 0.5, y: 0.4),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.9
            )
        }
        .allowsHitTesting(false)
    }

    private func wallCards(size: CGSize) -> some View {
        let placements = ExternalWallLayout.placements(
            size: size, count: controller.items.count,
            activeIndex: activeIndex, mode: controller.layoutMode
        )
        let cards = placements.compactMap { placement -> ExternalWallPositionedItem? in
            guard controller.items.indices.contains(placement.index) else { return nil }
            return ExternalWallPositionedItem(item: controller.items[placement.index],
                                              videoFrame: placement.videoFrame, qrFrame: placement.qrFrame)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(cards) { card in
                videoCard(item: card.item, frame: card.videoFrame, size: size)
                qrCard(item: card.item, frame: card.qrFrame)
            }
            if controller.layoutMode == .cinema, let placement = placements.first {
                cinemaCounter(size: size, qrFrame: placement.qrFrame)
                cinemaProgressBar(size: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func videoCard(item: ExternalWallItem, frame: CGRect, size: CGSize) -> some View {
        let scale = max(0.1, min(size.width / 1920, size.height / 1080))
        let cornerRadius = controller.layoutMode == .cinema ? 6 * scale : 3 * scale
        return Group {
            if item.id == controller.currentItem?.id {
                ExternalWallActiveVideo(
                    player: controller.player, poster: controller.posterImages[item.id],
                    isPlaybackHeld: controller.isPlaybackHeld, scale: scale
                )
                // A new identity cannot retain the previous player's last frame or readiness.
                .id(item.id)
            } else {
                ExternalWallPoster(image: controller.posterImages[item.id], scale: scale)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.5), radius: 17 * scale, x: 0, y: 14 * scale)
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel("环拍视频")
    }

    private func qrCard(item: ExternalWallItem, frame: CGRect) -> some View {
        let currentImage = item.id == controller.currentItem?.id ? controller.qrImage : nil
        let image = item.qrPayload == nil ? nil : (controller.qrImages[item.id] ?? currentImage)
        return ExternalWallQRCard(image: image, isUploaded: item.qrPayload != nil, side: frame.width)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private func cinemaCounter(size: CGSize, qrFrame: CGRect) -> some View {
        let scale = max(0.1, min(size.width / 1920, size.height / 1080))
        return Text(String(format: "%02d / %02d", activeIndex + 1, controller.items.count))
            .font(.system(size: 20 * scale, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Color(red: 154 / 255, green: 166 / 255, blue: 178 / 255))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, max(0, size.width - qrFrame.maxX))
            .padding(.bottom, max(0, size.height - qrFrame.maxY))
    }

    private func cinemaProgressBar(size: CGSize) -> some View {
        let height = 4 * max(0.1, min(size.width / 1920, size.height / 1080))
        let progress = CGFloat(min(1, max(0, controller.cinemaProgress)))
        return Color.white.opacity(0.65)
            .frame(width: size.width * progress, height: height)
            .frame(width: size.width, height: height, alignment: .leading)
            .background(.white.opacity(0.08))
            .position(x: size.width / 2, y: size.height - height / 2)
            .accessibilityHidden(true)
    }

    private func waitingView(title: String, detail: String, size: CGSize) -> some View {
        VStack(spacing: max(8, size.height * 0.014)) {
            Image(systemName: "video.fill")
                .font(.system(size: min(120, max(44, size.width * 0.07))))
                .foregroundStyle(.white.opacity(0.8))
            Text(title)
                .font(.system(size: min(58, max(26, size.width * 0.034)), weight: .heavy))
                .foregroundStyle(.white.opacity(0.94))
            Text(detail)
                .font(.system(size: min(26, max(14, size.width * 0.015)), weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(controller.statusText)
                .font(.system(size: min(20, max(12, size.width * 0.011))))
                .foregroundStyle(.white.opacity(0.4))
        }
        .multilineTextAlignment(.center)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExternalWallPositionedItem: Identifiable {
    let item: ExternalWallItem
    let videoFrame: CGRect
    let qrFrame: CGRect
    var id: UUID { item.id }
}

private struct ExternalWallPoster: View {
    let image: UIImage?
    let scale: CGFloat

    var body: some View {
        ZStack {
            Color(red: 11 / 255, green: 14 / 255, blue: 19 / 255)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "video")
                    .font(.system(size: max(16, 36 * scale), weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .clipped()
    }
}

/// Mounted only for the active card, with a fresh readiness state for each video ID.
@MainActor
private struct ExternalWallActiveVideo: View {
    let player: AVPlayer
    let poster: UIImage?
    let isPlaybackHeld: Bool
    let scale: CGFloat
    @State private var isReady = false

    var body: some View {
        ZStack {
            ExternalWallPoster(image: poster, scale: scale)
            ExternalWallPlayerLayerView(player: player, isReady: $isReady)
                .opacity(isReady ? 1 : 0)
            if !isReady {
                Text("载入中…")
                    .font(.system(size: max(10, 18 * scale), weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(8 * scale)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            if isPlaybackHeld {
                Image(systemName: "pause.fill")
                    .font(.system(size: max(10, 18 * scale), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(10 * scale)
                    .background(.black.opacity(0.55), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12 * scale)
                    .accessibilityLabel("播放暂时暂停，拍摄优先")
            }
        }
    }
}

private struct ExternalWallQRCard: View {
    let image: UIImage?
    let isUploaded: Bool
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(3, side / 16)).fill(.white)
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(max(4, side * 0.085))
            } else {
                VStack(spacing: max(2, side * 0.04)) {
                    Image(systemName: isUploaded ? "qrcode" : "icloud.and.arrow.up")
                        .font(.system(size: max(10, side * 0.2)))
                    Text(isUploaded ? "二维码\n准备中" : "上传完成后\n可扫码下载")
                        .font(.system(size: max(7, side * 0.105)))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(Color(white: 0.4))
                .padding(max(3, side * 0.04))
            }
        }
        .shadow(color: .black.opacity(0.45), radius: side * 0.11, x: 0, y: side * 0.08)
        .accessibilityLabel(image == nil ? (isUploaded ? "正在准备下载二维码" : "上传完成后可扫码下载") : "当前视频下载二维码")
    }
}

/// Only the active video mounts this layer; it never creates another player or route.
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
        uiView.playerLayer.videoGravity = .resizeAspectFill
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
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspectFill
    }
}
