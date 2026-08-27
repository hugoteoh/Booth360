import Foundation
import CoreMotion
import Observation

/// 旋转判定（纯逻辑，单测覆盖）：
/// 角速度模长持续超过阈值 sustainSeconds 秒 → 触发一次；
/// 触发后 cooldownSeconds 内不再触发（转台还在转时防止连触）。
struct SpinDetector: Equatable {
    /// 触发阈值（rad/s）。1.2 ≈ 69°/s，360 转台起转很快就能超过。
    var thresholdRadPerSec: Double = 1.2
    /// 需要持续超阈的时长（秒），过滤手抖/磕碰。
    var sustainSeconds: Double = 0.5
    /// 触发后的冷却时间（秒）。
    var cooldownSeconds: Double = 8

    private var aboveSince: TimeInterval?
    private var lastTriggerAt: TimeInterval?

    /// 输入一帧角速度模长与时间戳，返回是否应当触发。
    mutating func process(rate: Double, at time: TimeInterval) -> Bool {
        if let lastTriggerAt, time - lastTriggerAt < cooldownSeconds {
            aboveSince = nil
            return false
        }
        guard rate >= thresholdRadPerSec else {
            aboveSince = nil
            return false
        }
        guard let since = aboveSince else {
            aboveSince = time
            return false
        }
        if time - since >= sustainSeconds {
            lastTriggerAt = time
            aboveSince = nil
            return true
        }
        return false
    }

    mutating func reset() {
        aboveSince = nil
        lastTriggerAt = nil
    }
}

/// CoreMotion 封装：监听设备角速度，转台起转时回调 onTrigger。
/// 只在嘉宾模式 welcome 页开启（由 GuestFlowViewModel 控制）。
@Observable
@MainActor
final class MotionTriggerService {

    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private var detector = SpinDetector()

    private(set) var isListening = false
    var onTrigger: (() -> Void)?

    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    func start() {
        guard isAvailable, !isListening else { return }
        detector.reset()
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let rotation = motion.rotationRate
            let magnitude = (rotation.x * rotation.x
                + rotation.y * rotation.y
                + rotation.z * rotation.z).squareRoot()
            if self.detector.process(rate: magnitude, at: motion.timestamp) {
                AppLogger.camera.info("Motion Trigger 触发（角速度 \(String(format: "%.2f", magnitude), privacy: .public) rad/s）")
                self.onTrigger?()
            }
        }
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        motionManager.stopDeviceMotionUpdates()
        isListening = false
    }
}
