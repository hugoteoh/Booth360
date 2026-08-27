import Foundation
import SwiftData

/// 一段已保存的源视频的元数据。视频文件本体在 Documents/SourceClips/ 下，
/// 这里只存相对文件名（沙盒绝对路径在重装/系统迁移后会变化）。
@Model
final class SourceClip {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var createdAt: Date
    var durationSeconds: Double
    var width: Int
    var height: Int
    var frameRate: Double
    /// 拍摄镜头："wide" / "ultraWide"
    var lensRawValue: String
    var isFavorite: Bool
    /// 所属活动（嘉宾模式拍摄时记录）。
    var eventID: UUID?

    init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Date = Date(),
        durationSeconds: Double,
        width: Int,
        height: Int,
        frameRate: Double,
        lensRawValue: String,
        isFavorite: Bool = false,
        eventID: UUID? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.lensRawValue = lensRawValue
        self.isFavorite = isFavorite
        self.eventID = eventID
    }
}

extension SourceClip {
    /// "1920×1080 · 60fps · 12.0s"
    var summaryText: String {
        let seconds = String(format: "%.1f", durationSeconds)
        return "\(width)×\(height) · \(Int(frameRate.rounded()))fps · \(seconds)s"
    }
}
