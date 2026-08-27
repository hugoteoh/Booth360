import Foundation
import SwiftData
import AVFoundation

/// 启动兜底：扫描 SourceClips / Renders 目录，为“文件在、数据库记录不在”的孤儿
/// 视频补建记录（数据库写入失败、恢复备份等场景不丢素材）。
/// 记录在、文件丢的情况保持原样（列表以“文件缺失”标灰，由用户决定删除）。
enum LibraryReconciler {

    @MainActor
    static func reconcile(storage: FileStorageService, context: ModelContext) async {
        await reconcileSourceClips(storage: storage, context: context)
        await reconcileRenders(storage: storage, context: context)
    }

    @MainActor
    private static func reconcileSourceClips(storage: FileStorageService, context: ModelContext) async {
        let files = videoFiles(in: storage.url(for: .sourceClips), extensions: ["mov", "mp4"])
        guard !files.isEmpty else { return }
        let known = Set(((try? context.fetch(FetchDescriptor<SourceClip>())) ?? []).map(\.fileName))
        var added = 0
        for url in files where !known.contains(url.lastPathComponent) {
            let info = await probeVideo(url: url)
            let clip = SourceClip(
                fileName: url.lastPathComponent,
                createdAt: creationDate(of: url),
                durationSeconds: info.duration,
                width: info.width,
                height: info.height,
                frameRate: info.frameRate,
                lensRawValue: CameraLens.wide.rawValue
            )
            context.insert(clip)
            added += 1
        }
        if added > 0 {
            try? context.save()
            AppLogger.storage.info("兜底扫描补录源片 \(added) 条")
        }
    }

    @MainActor
    private static func reconcileRenders(storage: FileStorageService, context: ModelContext) async {
        let files = videoFiles(in: storage.url(for: .renders), extensions: ["mp4", "mov"])
        guard !files.isEmpty else { return }
        let known = Set(((try? context.fetch(FetchDescriptor<RenderedVideo>())) ?? []).map(\.fileName))
        var added = 0
        for url in files where !known.contains(url.lastPathComponent) {
            let info = await probeVideo(url: url)
            let render = RenderedVideo(
                fileName: url.lastPathComponent,
                createdAt: creationDate(of: url),
                durationSeconds: info.duration,
                width: info.width,
                height: info.height,
                settingsSummary: "（扫描恢复）",
                sourceClipID: nil
            )
            context.insert(render)
            added += 1
        }
        if added > 0 {
            try? context.save()
            AppLogger.storage.info("兜底扫描补录成品 \(added) 条")
        }
    }

    // MARK: - 工具

    private static func videoFiles(in directory: URL, extensions: [String]) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return contents.filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    private static func creationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
            .flatMap { $0 } ?? Date()
    }

    private struct VideoProbe {
        var duration: Double = 0
        var width: Int = 0
        var height: Int = 0
        var frameRate: Double = 30
    }

    private static func probeVideo(url: URL) async -> VideoProbe {
        var probe = VideoProbe()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
            probe.duration = duration
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let display = CropGeometry.displaySize(naturalSize: size, preferredTransform: transform)
                probe.width = Int(display.width)
                probe.height = Int(display.height)
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                probe.frameRate = Double(rate)
            }
        }
        return probe
    }
}
