import Foundation

enum CameraError: LocalizedError, Equatable {
    case permissionDenied
    case microphonePermissionDenied
    case deviceUnavailable(CameraLens)
    case formatUnsupported(String)
    case configurationFailed(String)
    case recordingFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "相机权限被拒绝。请到 设置 → Booth360 打开相机权限。"
        case .microphonePermissionDenied:
            return "麦克风权限被拒绝。请到 设置 → Booth360 打开麦克风权限。"
        case .deviceUnavailable(let lens):
            return "此设备没有可用的\(lens.displayName)镜头。"
        case .formatUnsupported(let detail):
            return "当前镜头不支持所选格式：\(detail)"
        case .configurationFailed(let detail):
            return "相机配置失败：\(detail)"
        case .recordingFailed(let detail):
            return "录制失败：\(detail)"
        case .busy:
            return "相机正忙，请稍候。"
        }
    }
}
