import Foundation
import SwiftData
import UIKit

/// 活动的创建/复制/删除与素材文件管理。
/// 素材布局：Documents/Events/<eventID>/{logo.png, background.png, overlay.png, music.<ext>}
@MainActor
struct EventManager {

    enum AssetKind: String {
        case logo
        case background
        case overlay
        case music
        case overlayVideo
        case intro
        case outro

        /// 图片类统一存 png 名（内容格式由 UIImage 自动识别）；音视频保留扩展名。
        func fileName(originalExtension: String = "") -> String {
            switch self {
            case .logo: return "logo.png"
            case .background: return "background.png"
            case .overlay: return "overlay.png"
            case .music: return "music.\(originalExtension.isEmpty ? "m4a" : originalExtension)"
            case .overlayVideo: return "overlay_video.\(originalExtension.isEmpty ? "mov" : originalExtension)"
            case .intro: return "intro.\(originalExtension.isEmpty ? "mp4" : originalExtension)"
            case .outro: return "outro.\(originalExtension.isEmpty ? "mp4" : originalExtension)"
            }
        }
    }

    let storage: FileStorageService

    private static let activeEventKey = "booth360.activeEventID"

    // MARK: - 活动目录

    func folderURL(for event: EventTemplate) -> URL {
        storage.url(for: .events).appendingPathComponent(event.id.uuidString, isDirectory: true)
    }

    func assetURL(event: EventTemplate, fileName: String) -> URL {
        folderURL(for: event).appendingPathComponent(fileName, isDirectory: false)
    }

    private func ensureFolder(for event: EventTemplate) throws {
        let url = folderURL(for: event)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func createEvent(named name: String, in context: ModelContext) -> EventTemplate {
        let event = EventTemplate(name: name)
        context.insert(event)
        try? context.save()
        if Self.activeEventID == nil { Self.activeEventID = event.id }
        AppLogger.storage.info("创建活动: \(name, privacy: .public)")
        return event
    }

    /// 复制活动：全部字段 + 素材文件夹整体拷贝。
    @discardableResult
    func duplicate(_ event: EventTemplate, in context: ModelContext) -> EventTemplate {
        let copy = EventTemplate(
            name: "\(event.name) 副本",
            welcomeTitle: event.welcomeTitle,
            welcomeSubtitle: event.welcomeSubtitle,
            autoReturnSeconds: event.autoReturnSeconds,
            lensRawValue: event.lensRawValue,
            frameRateRawValue: event.frameRateRawValue,
            countdownSeconds: event.countdownSeconds,
            recordingSeconds: event.recordingSeconds,
            effectSettingsData: event.effectSettingsData
        )
        copy.logoFileName = event.logoFileName
        copy.backgroundFileName = event.backgroundFileName
        copy.overlayFileName = event.overlayFileName
        copy.musicFileName = event.musicFileName
        copy.musicDisplayName = event.musicDisplayName
        copy.overlayVideoFileName = event.overlayVideoFileName
        copy.introFileName = event.introFileName
        copy.outroFileName = event.outroFileName
        copy.motionTriggerEnabled = event.motionTriggerEnabled
        copy.turntableSpinEnabled = event.turntableSpinEnabled
        copy.shotModesData = event.shotModesData
        context.insert(copy)

        let sourceFolder = folderURL(for: event)
        if FileManager.default.fileExists(atPath: sourceFolder.path) {
            try? FileManager.default.copyItem(at: sourceFolder, to: folderURL(for: copy))
        }
        try? context.save()
        return copy
    }

    /// 删除活动与其素材目录。成品/源片记录保留（只解除归属，不删素材视频）。
    func delete(_ event: EventTemplate, in context: ModelContext) {
        if Self.activeEventID == event.id { Self.activeEventID = nil }
        try? FileManager.default.removeItem(at: folderURL(for: event))
        context.delete(event)
        try? context.save()
    }

    // MARK: - 素材导入

    /// 从内存数据导入（PhotosPicker 图片）。返回落地文件名。
    func importAsset(data: Data, kind: AssetKind, into event: EventTemplate) throws -> String {
        try ensureFolder(for: event)
        let fileName = kind.fileName()
        let destination = assetURL(event: event, fileName: fileName)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        apply(fileName: fileName, kind: kind, to: event)
        return fileName
    }

    /// 从安全作用域 URL 导入（fileImporter 音乐）。调用方负责 start/stopAccessing。
    func importAsset(from sourceURL: URL, kind: AssetKind, into event: EventTemplate) throws -> String {
        try ensureFolder(for: event)
        let fileName = kind.fileName(originalExtension: sourceURL.pathExtension)
        let destination = assetURL(event: event, fileName: fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        apply(fileName: fileName, kind: kind, to: event)
        if kind == .music { event.musicDisplayName = sourceURL.lastPathComponent }
        return fileName
    }

    /// 移除某类素材：删文件 + 清空字段（音乐同时清显示名）。
    func removeAsset(kind: AssetKind, from event: EventTemplate) {
        let fileName: String?
        switch kind {
        case .logo: fileName = event.logoFileName
        case .background: fileName = event.backgroundFileName
        case .overlay: fileName = event.overlayFileName
        case .music: fileName = event.musicFileName
        case .overlayVideo: fileName = event.overlayVideoFileName
        case .intro: fileName = event.introFileName
        case .outro: fileName = event.outroFileName
        }
        if let fileName {
            try? FileManager.default.removeItem(at: assetURL(event: event, fileName: fileName))
        }
        switch kind {
        case .logo: event.logoFileName = nil
        case .background: event.backgroundFileName = nil
        case .overlay: event.overlayFileName = nil
        case .music: event.musicFileName = nil; event.musicDisplayName = nil
        case .overlayVideo: event.overlayVideoFileName = nil
        case .intro: event.introFileName = nil
        case .outro: event.outroFileName = nil
        }
        event.updatedAt = Date()
    }

    private func apply(fileName: String, kind: AssetKind, to event: EventTemplate) {
        switch kind {
        case .logo: event.logoFileName = fileName
        case .background: event.backgroundFileName = fileName
        case .overlay: event.overlayFileName = fileName
        case .music: event.musicFileName = fileName
        case .overlayVideo: event.overlayVideoFileName = fileName
        case .intro: event.introFileName = fileName
        case .outro: event.outroFileName = fileName
        }
        event.updatedAt = Date()
    }

    // MARK: - 素材读取

    func loadImage(event: EventTemplate, fileName: String?) -> UIImage? {
        guard let fileName else { return nil }
        return UIImage(contentsOfFile: assetURL(event: event, fileName: fileName).path)
    }

    func musicURL(event: EventTemplate) -> URL? {
        existingAssetURL(event: event, fileName: event.musicFileName)
    }

    func overlayVideoURL(event: EventTemplate) -> URL? {
        existingAssetURL(event: event, fileName: event.overlayVideoFileName)
    }

    func introURL(event: EventTemplate) -> URL? {
        existingAssetURL(event: event, fileName: event.introFileName)
    }

    func outroURL(event: EventTemplate) -> URL? {
        existingAssetURL(event: event, fileName: event.outroFileName)
    }

    private func existingAssetURL(event: EventTemplate, fileName: String?) -> URL? {
        guard let fileName else { return nil }
        let url = assetURL(event: event, fileName: fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 当前活动

    /// nonisolated：UserDefaults 线程安全，允许在 View init 等非主线程上下文读取。
    nonisolated static var activeEventID: UUID? {
        get { UserDefaults.standard.string(forKey: activeEventKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: activeEventKey) }
    }

    static func activeEvent(in context: ModelContext) -> EventTemplate? {
        guard let id = activeEventID else { return nil }
        var descriptor = FetchDescriptor<EventTemplate>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
