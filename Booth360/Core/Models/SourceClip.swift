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
    /// 按下开始时的模式快照；活动之后改节奏，不影响这段源片的重新剪辑。
    var shotModeData: Data? = nil

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
        eventID: UUID? = nil,
        shotMode: ShotMode? = nil
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
        self.shotModeData = shotMode.flatMap { try? JSONEncoder().encode($0) }
    }
}

extension SourceClip {
    var capturedShotMode: ShotMode? {
        guard let shotModeData else { return nil }
        return try? JSONDecoder().decode(ShotMode.self, from: shotModeData)
    }

    /// "1920×1080 · 60fps · 12.0s"
    var summaryText: String {
        let seconds = String(format: "%.1f", durationSeconds)
        return "\(width)×\(height) · \(Int(frameRate.rounded()))fps · \(seconds)s"
    }
}
