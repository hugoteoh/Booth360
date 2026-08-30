import Foundation
import AVFoundation

/// 拍摄镜头 / 焦段。
/// 0.5× 与 1× 是物理镜头；0.6×–0.9× 在超广角上用传感器裁切实现——
/// 专为转台构图设的过渡档：比 0.5× 畸变小、比 1× 拍得全，帧率与防抖全部保留。
enum CameraLens: String, CaseIterable, Identifiable, Codable {
    case ultraWide
    case uw0_6
    case uw0_7
    case uw0_8
    case uw0_9
    case wide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ultraWide: return "超广角 0.5×"
        case .uw0_6: return "0.6×"
        case .uw0_7: return "0.7×"
        case .uw0_8: return "0.8×"
        case .uw0_9: return "0.9×"
        case .wide: return "广角 1×"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide: return .builtInWideAngleCamera
        default: return .builtInUltraWideCamera
        }
    }

    /// 在所选物理镜头上应用的变焦倍率（超广角 ×2 ≈ 主摄 1× 视角）。
    var zoomFactor: CGFloat {
        switch self {
        case .ultraWide, .wide: return 1.0
        case .uw0_6: return 1.2
        case .uw0_7: return 1.4
        case .uw0_8: return 1.6
        case .uw0_9: return 1.8
        }
    }
}

/// 录制分辨率。Phase 1 只开放 1080p；4K 枚举先就位，Phase 2 起在 UI 开放。
enum CaptureResolution: String, CaseIterable, Identifiable, Codable {
    case hd1080
    case uhd4K

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hd1080: return "1080p"
        case .uhd4K: return "4K"
        }
    }

    /// 传感器输出为横向尺寸（宽 > 高），竖拍由 rotation 元数据处理。
    var width: Int32 {
        switch self {
        case .hd1080: return 1920
        case .uhd4K: return 3840
        }
    }

    var height: Int32 {
        switch self {
        case .hd1080: return 1080
        case .uhd4K: return 2160
        }
    }
}

/// 录制帧率。120/240 枚举就位，Phase 2 起按设备能力开放。
enum CaptureFrameRate: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120
    case fps240 = 240

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) FPS" }
    var doubleValue: Double { Double(rawValue) }
}

/// 相机会话配置。改动任意一项都需要 reconfigure。
struct CameraConfiguration: Equatable {
    var lens: CameraLens = .wide
    var resolution: CaptureResolution = .hd1080
    var frameRate: CaptureFrameRate = .fps60
    var recordsAudio: Bool = true

    static let phase1Default = CameraConfiguration()
}

/// 单次拍摄参数（与会话配置分离：改这些不需要重建会话）。
struct RecordingSettings: Equatable {
    /// 倒数秒数，0 表示不倒数。
    var countdownSeconds: Int = 3
    /// 录制时长（到时自动停止）。
    var recordingSeconds: Int = 15

    static let countdownChoices = [0, 3, 5, 10]
    static let durationChoices = [5, 10, 15, 20, 30, 45, 60]
}
