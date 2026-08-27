import SwiftUI
import AVFoundation
import UIKit

/// Gallery：成品 / 源片段 两个分栏。
struct GalleryView: View {
    let storage: FileStorageService
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 8) {
            Picker("分类", selection: $selectedTab) {
                Text("成品").tag(0)
                Text("源片段").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if selectedTab == 0 {
                RenderListView(storage: storage)
            } else {
                ClipListView(storage: storage)
            }
        }
    }
}

/// 视频首帧缩略图（NSCache 缓存，key 为文件 URL）。
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSURL, UIImage>()

    func thumbnail(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            return nil
        }
    }
}

/// 通用缩略图视图（列表行用）。
struct VideoThumbnailView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
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
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            image = await ThumbnailLoader.shared.thumbnail(for: url)
        }
    }
}
