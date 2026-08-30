import Foundation
import AVFoundation

/// 拍摄镜头 / 焦段。
/// 0.5× 与 1× 是物理镜头；1.5×/2×/3× 在主摄上用传感器裁切变焦实现
/// （与系统相机 App 的 2× 同原理，高帧率与防抖全部保留，1080p 输出画质无感损失）。
enum CameraLens: String, CaseIterable, Identifiable, Codable {
    case ultraWide
    case wide
    case wide1_5
    case wide2
    case wide3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ultraWide: return "超广角 0.5×"
        case .wide: return "广角 1×"
        case .wide1_5: return "1.5×"
        case .wide2: return "2×"
        case .wide3: return "3×"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .wide1_5, .wide2, .wide3: return .builtInWideAngleCamera
        }
    }

    /// 在所选物理镜头上应用的变焦倍率。
    var zoomFactor: CGFloat {
        switch self {
        case .ultraWide, .wide: return 1.0
        case .wide1_5: return 1.5
        case .wide2: return 2.0
        case .wide3: return 3.0
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
