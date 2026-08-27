import Foundation
import UIKit
import Observation

/// 现场稳定性监控：磁盘空间、电量、过热。
/// 阈值：存储 <5GB 提醒、<1GB 禁止新录制；电量 <20% 提醒；热度 serious 起提醒。
@Observable
@MainActor
final class SystemStatusMonitor {

    struct Warning: Identifiable, Equatable {
        let id: String
        let text: String
        let isCritical: Bool
    }

    private(set) var availableBytes: Int64 = .max
    private(set) var batteryLevel: Float = 1
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    private let storage: FileStorageService
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

    static let lowStorageBytes: Int64 = 5_000_000_000
    static let criticalStorageBytes: Int64 = 1_000_000_000
    static let lowBattery: Float = 0.2

    init(storage: FileStorageService) {
        self.storage = storage
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 是否禁止开始新录制（仅剩余空间见底时）。
    var blocksNewRecording: Bool { availableBytes < Self.criticalStorageBytes }

    var warnings: [Warning] {
        var list: [Warning] = []
        if availableBytes < Self.criticalStorageBytes {
            let gb = Double(availableBytes) / 1_000_000_000
            list.append(Warning(
                id: "storage-critical",
                text: String(format: "存储空间只剩 %.1f GB，已暂停新录制，请清理", gb),
                isCritical: true))
        } else if availableBytes < Self.lowStorageBytes {
            let gb = Double(availableBytes) / 1_000_000_000
            list.append(Warning(
                id: "storage-low",
                text: String(format: "存储空间不足（剩 %.1f GB）", gb),
                isCritical: false))
        }
        if batteryLevel >= 0, batteryLevel < Self.lowBattery {
            list.append(Warning(
                id: "battery-low",
                text: "电量低（\(Int(batteryLevel * 100))%），请连接电源",
                isCritical: false))
        }
        switch thermalState {
        case .serious:
            list.append(Warning(id: "thermal", text: "设备温度偏高，建议降低环境温度", isCritical: false))
        case .critical:
            list.append(Warning(id: "thermal", text: "设备过热！性能受限，请立即降温", isCritical: true))
        default:
            break
        }
        return list
    }

    func start() {
        guard refreshTask == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        })
        notificationTokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        })

        // 磁盘空间轮询（30 秒一次足够）
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refresh()
            }
        }
    }

    func refresh() {
        // 查询失败返回 0，保持旧值避免误报“空间见底”
        let bytes = storage.availableDiskSpaceInBytes()
        if bytes > 0 { availableBytes = bytes }
        batteryLevel = UIDevice.current.batteryLevel
        thermalState = ProcessInfo.processInfo.thermalState
        for warning in warnings where warning.isCritical {
            AppLogger.ui.warning("系统警告: \(warning.text, privacy: .public)")
        }
    }
}
