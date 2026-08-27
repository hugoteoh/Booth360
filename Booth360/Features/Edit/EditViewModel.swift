import Foundation
import SwiftUI
import SwiftData
import AVFoundation
import Photos
import PhotosUI
import UIKit
import Observation

/// 编辑/导出页状态。持有自己的 VideoProcessingEngine 实例。
@Observable
@MainActor
final class EditViewModel {

    /// 结果播放弹层（预览或成品）。
    struct PlaybackPresentation: Identifiable {
        let id = UUID()
        let playerItem: AVPlayerItem
        /// 非 nil = 已导出成品，可分享/存相册。
        let exportedURL: URL?
        let note: String?
    }

    let clip: SourceClip
    let storage: FileStorageService
    let engine: VideoProcessingEngine

    var settings = EffectSettings()
    var presentation: PlaybackPresentation?
    var errorMessage: String?
    var toastMessage: String?

    private(set) var overlayFileName: String?
    private(set) var overlayImage: UIImage?
    private(set) var musicFileName: String?
    private(set) var musicDisplayName: String?
    private(set) var overlayVideoFileName: String?

    private enum DefaultsKey {
        static let overlayFileName = "booth360.overlayFileName"
        static let musicFileName = "booth360.musicFileName"
        static let musicDisplayName = "booth360.musicDisplayName"
        static let overlayVideoFileName = "booth360.overlayVideoFileName"
    }

    init(clip: SourceClip, storage: FileStorageService) {
        self.clip = clip
        self.storage = storage
        self.engine = VideoProcessingEngine()

        let defaults = UserDefaults.standard
        overlayFileName = defaults.string(forKey: DefaultsKey.overlayFileName)
        musicFileName = defaults.string(forKey: DefaultsKey.musicFileName)
        musicDisplayName = defaults.string(forKey: DefaultsKey.musicDisplayName)
        overlayVideoFileName = defaults.string(forKey: DefaultsKey.overlayVideoFileName)
        if let overlayFileName {
            overlayImage = UIImage(contentsOfFile: storage.assetURL(fileName: overlayFileName).path)
        }
        settings.overlayEnabled = overlayImage != nil && defaults.bool(forKey: "booth360.overlayEnabled")
        settings.musicEnabled = musicFileName != nil && defaults.bool(forKey: "booth360.musicEnabled")
        settings.overlayVideoEnabled = overlayVideoFileName != nil
            && defaults.bool(forKey: "booth360.overlayVideoEnabled")
    }

    var sourceURL: URL { storage.sourceClipURL(fileName: clip.fileName) }

    /// 成品预计时长（按当前设置估算）。
    var estimatedOutputSeconds: Double {
        TimelineBuilder.totalDuration(of: TimelineBuilder.build(
            clipDurationSeconds: clip.durationSeconds,
            effect: settings.speed,
            style: settings.style,
            loopCount: settings.loopCount
        ))
    }

    // MARK: - 素材导入

    func importOverlay(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "无法读取所选图片"
                return
            }
            let fileName = try storage.importAsset(data: data, preferredName: "overlay.png")
            overlayFileName = fileName
            overlayImage = image
            settings.overlayEnabled = true
            UserDefaults.standard.set(fileName, forKey: DefaultsKey.overlayFileName)
            AppLogger.processing.info("已导入 Overlay 图片")
        } catch {
            errorMessage = "导入 Overlay 失败：\(error.localizedDescription)"
        }
    }

    /// fileImporter 回调（安全作用域 URL）。
    func importMusic(result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let didAccess = pickedURL.startAccessingSecurityScopedResource()
            defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }
            do {
                let ext = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension
                let fileName = try storage.importAsset(from: pickedURL, preferredName: "music.\(ext)")
                musicFileName = fileName
                musicDisplayName = pickedURL.lastPathComponent
                settings.musicEnabled = true
                UserDefaults.standard.set(fileName, forKey: DefaultsKey.musicFileName)
                UserDefaults.standard.set(pickedURL.lastPathComponent, forKey: DefaultsKey.musicDisplayName)
                AppLogger.processing.info("已导入音乐: \(pickedURL.lastPathComponent, privacy: .public)")
            } catch {
                errorMessage = "导入音乐失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "选择音乐失败：\(error.localizedDescription)"
        }
    }

    /// 动态 Overlay 导入（fileImporter 回调，安全作用域 URL）。
    func importOverlayVideo(result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            let didAccess = pickedURL.startAccessingSecurityScopedResource()
            defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }
            do {
                let ext = pickedURL.pathExtension.isEmpty ? "mov" : pickedURL.pathExtension
                let fileName = try storage.importAsset(from: pickedURL, preferredName: "overlay_video.\(ext)")
                overlayVideoFileName = fileName
                settings.overlayVideoEnabled = true
                UserDefaults.standard.set(fileName, forKey: DefaultsKey.overlayVideoFileName)
            } catch {
                errorMessage = "导入动态 Overlay 失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }

    /// 开关状态持久化（下次进入编辑页保持）。
    func persistToggles() {
        UserDefaults.standard.set(settings.overlayEnabled, forKey: "booth360.overlayEnabled")
        UserDefaults.standard.set(settings.musicEnabled, forKey: "booth360.musicEnabled")
        UserDefaults.standard.set(settings.overlayVideoEnabled, forKey: "booth360.overlayVideoEnabled")
    }

    // MARK: - 预览 / 导出

    func previewTapped() async {
        guard !engine.isBusy else { return }
        errorMessage = nil
        do {
            // outputURL 仅占位，预览不落盘
            let item = try await engine.makePreviewItem(VideoProcessingEngine.RenderRequest(
                sourceURL: sourceURL,
                settings: settings,
                overlayVideoURL: overlayVideoURL,
                musicURL: musicURL,
                outputURL: storage.newRenderURL()
            ))
            presentation = PlaybackPresentation(
                playerItem: item,
                exportedURL: nil,
                note: settings.overlayEnabled ? "预览不含静态图 Overlay，导出后生效" : nil
            )
        } catch {
            handleProcessingFailure(error)
        }
    }

    func exportTapped(modelContext: ModelContext, uploadQueue: UploadQueue?) async {
        guard !engine.isBusy else { return }
        errorMessage = nil
        let outputURL = storage.newRenderURL()
        let request = VideoProcessingEngine.RenderRequest(
            sourceURL: sourceURL,
            settings: settings,
            overlayImage: overlayImage?.cgImage,
            overlayVideoURL: overlayVideoURL,
            musicURL: musicURL,
            outputURL: outputURL
        )
        do {
            let result = try await engine.export(request)
            let rendered = RenderedVideo(
                fileName: result.outputURL.lastPathComponent,
                durationSeconds: result.durationSeconds,
                width: Int(result.renderSize.width),
                height: Int(result.renderSize.height),
                settingsSummary: settings.summaryText,
                sourceClipID: clip.id
            )
            modelContext.insert(rendered)
            try? modelContext.save()
            // 导出即自动上传（上传功能开启时），无需手动
            if let uploadQueue, uploadQueue.isEnabled {
                uploadQueue.enqueue(rendered)
            }
            presentation = PlaybackPresentation(
                playerItem: AVPlayerItem(url: result.outputURL),
                exportedURL: result.outputURL,
                note: nil
            )
        } catch {
            handleProcessingFailure(error)
        }
    }

    private func handleProcessingFailure(_ error: Error) {
        if (error as? ProcessingError) == .cancelled { return }
        errorMessage = error.localizedDescription
    }

    private var musicURL: URL? {
        guard settings.musicEnabled, let musicFileName else { return nil }
        return storage.assetURL(fileName: musicFileName)
    }

    private var overlayVideoURL: URL? {
        guard settings.overlayVideoEnabled, let overlayVideoFileName else { return nil }
        return storage.assetURL(fileName: overlayVideoFileName)
    }

    // MARK: - 存相册

    func saveToPhotos(url: URL) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            toastMessage = "已保存到相册"
            AppLogger.processing.info("成品已存入系统相册")
        } catch {
            errorMessage = "保存到相册失败：\(error.localizedDescription)（请在 设置 → Booth360 允许添加照片）"
        }
    }
}
