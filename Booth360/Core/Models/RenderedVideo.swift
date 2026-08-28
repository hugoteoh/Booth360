import Foundation
import SwiftData

/// 一条已导出的成品视频记录。文件在 Documents/Renders/ 下，存相对文件名。
/// uploadState 先占位（Phase 3 上传队列使用）。
@Model
final class RenderedVideo {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var createdAt: Date
    var durationSeconds: Double
    var width: Int
    var height: Int
    /// 处理参数描述，如 "慢-快-慢 · Boomerang · 9:16 1080p HEVC"。
    var settingsSummary: String
    /// 来源源片 id（源片被删后仍保留成品，故不用关系只存 id）。
    var sourceClipID: UUID?
    var isFavorite: Bool
    /// "none" / "queued" / "uploading" / "done" / "failed"。
    var uploadStateRawValue: String
    /// 上传成功后的下载链接（COS 预签名 URL），二维码编码此值。
    var remoteURLString: String?
    var uploadAttempts: Int
    var lastUploadError: String?
    /// 所属活动（嘉宾模式产出时记录）。
    var eventID: UUID?
    /// 不在大屏展示（单条隐藏；本地/云端大屏都生效）。
    var hiddenFromWall: Bool = false

    init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Date = Date(),
        durationSeconds: Double,
        width: Int,
        height: Int,
        settingsSummary: String,
        sourceClipID: UUID?,
        isFavorite: Bool = false,
        uploadStateRawValue: String = "none",
        remoteURLString: String? = nil,
        uploadAttempts: Int = 0,
        lastUploadError: String? = nil,
        eventID: UUID? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.settingsSummary = settingsSummary
        self.sourceClipID = sourceClipID
        self.isFavorite = isFavorite
        self.uploadStateRawValue = uploadStateRawValue
        self.remoteURLString = remoteURLString
        self.uploadAttempts = uploadAttempts
        self.lastUploadError = lastUploadError
        self.eventID = eventID
    }
}
