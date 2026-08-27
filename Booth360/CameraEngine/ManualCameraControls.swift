import Foundation
import CoreMedia

/// 手动控制的 UI 侧数值（全部为 0…1 或物理值，与具体设备无关）。
struct ManualControlState: Equatable {
    var exposureLocked: Bool = false
    /// ISO（物理值），仅 exposureLocked 时生效。
    var iso: Float = 100
    /// 快门时长（秒），仅 exposureLocked 时生效。如 1/120 = 0.00833。
    var shutterSeconds: Double = 1.0 / 120.0
    /// EV 偏移，自动曝光模式下生效。
    var exposureBias: Float = 0

    var focusLocked: Bool = false
    /// 镜头位置 0（最近）…1（无穷远），仅 focusLocked 时生效。
    var lensPosition: Float = 0.5

    var whiteBalanceLocked: Bool = false
    /// 色温（K），仅 whiteBalanceLocked 时生效。
    var temperature: Float = 5000
    /// 色调 -150…150。
    var tint: Float = 0
}

/// 设备能力范围（从 AVCaptureDevice/Format 提取成纯数据，便于钳制逻辑单测）。
struct ManualControlLimits: Equatable {
    var minISO: Float = 32
    var maxISO: Float = 3200
    var minShutterSeconds: Double = 1.0 / 8000.0
    var maxShutterSeconds: Double = 1.0 / 3.0
    var minExposureBias: Float = -8
    var maxExposureBias: Float = 8
    var maxWhiteBalanceGain: Float = 4
}

/// 纯函数钳制，单测覆盖。所有下发给 AVCaptureDevice 的值必须先经过这里，
/// 否则超范围会直接抛 NSException 崩溃。
enum ControlClamp {
    static func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    static func iso(_ value: Float, limits: ManualControlLimits) -> Float {
        clamp(value, min: limits.minISO, max: limits.maxISO)
    }

    static func shutterSeconds(_ value: Double, limits: ManualControlLimits) -> Double {
        clamp(value, min: limits.minShutterSeconds, max: limits.maxShutterSeconds)
    }

    static func exposureBias(_ value: Float, limits: ManualControlLimits) -> Float {
        clamp(value, min: limits.minExposureBias, max: limits.maxExposureBias)
    }

    static func lensPosition(_ value: Float) -> Float {
        clamp(value, min: 0, max: 1)
    }

    static func temperature(_ value: Float) -> Float {
        clamp(value, min: 2500, max: 8000)
    }

    static func tint(_ value: Float) -> Float {
        clamp(value, min: -150, max: 150)
    }

    /// 白平衡增益逐通道钳制到 [1, maxGain]，超范围同样会崩溃。
    static func whiteBalanceGain(_ value: Float, maxGain: Float) -> Float {
        clamp(value, min: 1, max: maxGain)
    }
}

extension ManualControlState {
    /// 常用快门档位（供 UI 选择）。
    static let shutterChoices: [Double] = [
        1.0 / 30, 1.0 / 60, 1.0 / 120, 1.0 / 250, 1.0 / 500, 1.0 / 1000,
    ]

    static func shutterLabel(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.0fs", seconds) : "1/\(Int((1.0 / seconds).rounded()))"
    }
}
