import Foundation

enum ProcessingError: LocalizedError, Equatable {
    case sourceFileMissing
    case noVideoTrack
    case reverseFailed(String)
    case compositionFailed(String)
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceFileMissing:
            return "源视频文件不存在（可能已被删除）。"
        case .noVideoTrack:
            return "源视频没有可用的视频轨道。"
        case .reverseFailed(let detail):
            return "生成倒放素材失败：\(detail)"
        case .compositionFailed(let detail):
            return "时间轴合成失败：\(detail)"
        case .exportFailed(let detail):
            return "导出失败：\(detail)"
        case .cancelled:
            return "已取消。"
        }
    }
}
