import SwiftUI
import AVFoundation
import UIKit

/// Gallery：成品 / 源片段 两个分栏，内容只属于「当前活动」（各活动分开，互不混）。
struct GalleryView: View {
    let storage: FileStorageService
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0

    private var activeEvent: EventTemplate? { EventManager.activeEvent(in: modelContext) }

    var body: some View {
        VStack(spacing: 8) {
            Picker("分类", selection: $selectedTab) {
                Text("成品").tag(0)
                Text("源片段").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if activeEvent == nil {
                Text("未选择活动，显示全部")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if selectedTab == 0 {
                RenderListView(storage: storage, eventID: activeEvent?.id, eventName: activeEvent?.name)
            } else {
                ClipListView(storage: storage, eventID: activeEvent?.id, eventName: activeEvent?.name)
            }
        }
    }
}

/// 视频 37% 位置的静态缩略图；缓存版本避免沿用旧的首帧画面。
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, UIImage>()

    func thumbnail(for url: URL) async -> UIImage? {
        let key = "\(VideoThumbnailTiming.cacheVersion)|\(url.absoluteString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let duration = try await asset.load(.duration)
            let (cgImage, _) = try await generator.image(at: VideoThumbnailTiming.time(for: duration))
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}

/// 通用缩略图视图（列表行用）。默认 9:16 竖版大图，一眼认出画面里是谁。
struct VideoThumbnailView: View {
    let url: URL
    var width: CGFloat = 76
    var height: CGFloat = 135

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray5))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            image = await ThumbnailLoader.shared.thumbnail(for: url)
        }
    }
}
