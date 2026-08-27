import Foundation
import CoreBluetooth
import Observation

/// 转台蓝牙指令的十六进制解析（"A5 01 5A" / "0x01,0x02" / "a5015a" 均可）。纯逻辑，单测覆盖。
enum HexCommand {
    static func parse(_ text: String) -> Data? {
        let cleaned = text
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined()
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// 常见转台主板的协议预设（UUID 组合）。指令字节因品牌而异，在设置页可改。
enum TurntablePreset: String, CaseIterable, Identifiable {
    /// HM-10/BT05 系透传模块（大量国产转台用这个）
    case uartFFE0
    /// FFF0 系透传模块
    case uartFFF0
    /// Nordic UART Service
    case nordicUART
    /// 完全自定义 UUID
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .uartFFE0: return "通用 FFE0（HM-10 系）"
        case .uartFFF0: return "通用 FFF0"
        case .nordicUART: return "Nordic UART"
        case .custom: return "自定义 UUID"
        }
    }

    var defaultServiceUUID: String {
        switch self {
        case .uartFFE0: return "FFE0"
        case .uartFFF0: return "FFF0"
        case .nordicUART: return "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        case .custom: return ""
        }
    }

    var defaultWriteUUID: String {
        switch self {
        case .uartFFE0: return "FFE1"
        case .uartFFF0: return "FFF2"
        case .nordicUART: return "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
        case .custom: return ""
        }
    }
}

/// 转台配置（UserDefaults 持久化）。
struct TurntableConfig: Equatable {
    var preset: TurntablePreset = .uartFFE0
    var customServiceUUID: String = ""
    var customWriteUUID: String = ""
    /// 启动/停止指令（十六进制文本）。默认 01/00，拿到实机后按品牌调。
    var startHex: String = "01"
    var stopHex: String = "00"
    var rememberedDeviceID: String?

    var serviceUUID: String {
        preset == .custom ? customServiceUUID : preset.defaultServiceUUID
    }
    var writeUUID: String {
        preset == .custom ? customWriteUUID : preset.defaultWriteUUID
    }

    private enum Key {
        static let preset = "booth360.turntable.preset"
        static let service = "booth360.turntable.serviceUUID"
        static let write = "booth360.turntable.writeUUID"
        static let start = "booth360.turntable.startHex"
        static let stop = "booth360.turntable.stopHex"
        static let device = "booth360.turntable.deviceID"
    }

    static func load() -> TurntableConfig {
        let defaults = UserDefaults.standard
        var config = TurntableConfig()
        if let raw = defaults.string(forKey: Key.preset),
           let preset = TurntablePreset(rawValue: raw) {
            config.preset = preset
        }
        config.customServiceUUID = defaults.string(forKey: Key.service) ?? ""
        config.customWriteUUID = defaults.string(forKey: Key.write) ?? ""
        config.startHex = defaults.string(forKey: Key.start) ?? "01"
        config.stopHex = defaults.string(forKey: Key.stop) ?? "00"
        config.rememberedDeviceID = defaults.string(forKey: Key.device)
        return config
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(preset.rawValue, forKey: Key.preset)
        defaults.set(customServiceUUID, forKey: Key.service)
        defaults.set(customWriteUUID, forKey: Key.write)
        defaults.set(startHex, forKey: Key.start)
        defaults.set(stopHex, forKey: Key.stop)
        defaults.set(rememberedDeviceID, forKey: Key.device)
    }
}

/// 360 转台蓝牙控制：扫描/连接/记住设备、发送启动停止指令、设备诊断。
/// 指令写入目标：优先按配置的 服务/特征 UUID 匹配；找不到就退而选第一个可写特征
/// （未知品牌也能先连上试指令）。
@Observable
@MainActor
final class TurntableService: NSObject {

    enum ConnectionState: Equatable {
        case bluetoothOff
        case unauthorized
        case idle
        case scanning
        case connecting
        case connected(String)

        var displayText: String {
            switch self {
            case .bluetoothOff: return "蓝牙未开启"
            case .unauthorized: return "无蓝牙权限（请到系统设置允许）"
            case .idle: return "未连接"
            case .scanning: return "扫描中…"
            case .connecting: return "连接中…"
            case .connected(let name): return "已连接：\(name)"
            }
        }
    }

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    private(set) var state: ConnectionState = .idle
    private(set) var discovered: [DiscoveredDevice] = []
    /// 连接后设备的服务/特征清单（对未知品牌做协议侦察用）。
    private(set) var diagnostics: [String] = []
    private(set) var lastError: String?
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var config = TurntableConfig.load()

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?

    /// 首次使用（进入转台设置页/嘉宾模式需要时）才初始化蓝牙，避免一启动就弹权限框。
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 扫描与连接

    func startScan() {
        activate()
        guard let central, central.state == .poweredOn else { return }
        discovered = []
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() {
        central?.stopScan()
        if case .scanning = state { state = .idle }
    }

    func connect(deviceID: UUID) {
        guard let central else { return }
        central.stopScan()
        guard let target = central.retrievePeripherals(withIdentifiers: [deviceID]).first else {
            lastError = "找不到该设备，请重新扫描"
            return
        }
        state = .connecting
        peripheral = target
        target.delegate = self
        central.connect(target, options: nil)
    }

    func disconnectAndForget() {
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeCharacteristic = nil
        config.rememberedDeviceID = nil
        config.save()
        state = .idle
        diagnostics = []
    }

    /// 启动时/进嘉宾模式时尝试重连记住的设备。
    func reconnectRememberedIfNeeded() {
        activate()
        guard !isConnected,
              let idText = config.rememberedDeviceID,
              let id = UUID(uuidString: idText),
              let central, central.state == .poweredOn else { return }
        connect(deviceID: id)
    }

    // MARK: - 指令

    func sendStart() {
        send(hex: config.startHex, label: "启动")
    }

    func sendStop() {
        send(hex: config.stopHex, label: "停止")
    }

    /// 测试：转 seconds 秒后自动停。
    func testSpin(seconds: Double = 3) {
        sendStart()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.sendStop()
        }
    }

    private func send(hex: String, label: String) {
        guard let peripheral, let characteristic = writeCharacteristic else {
            lastError = "未连接转台或未找到可写特征"
            return
        }
        guard let data = HexCommand.parse(hex) else {
            lastError = "\(label)指令不是有效的十六进制：\(hex)"
            return
        }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        AppLogger.ui.info("转台\(label, privacy: .public)指令已发送: \(hex, privacy: .public)")
    }

    /// 配置变化后重新在已发现的特征里挑写入目标。
    func reresolveCharacteristic() {
        guard let peripheral else { return }
        pickWriteCharacteristic(for: peripheral)
    }

    private func pickWriteCharacteristic(for peripheral: CBPeripheral) {
        let wantedService = config.serviceUUID.uppercased()
        let wantedChar = config.writeUUID.uppercased()
        var fallback: CBCharacteristic?
        var exact: CBCharacteristic?

        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] {
                let writable = characteristic.properties.contains(.write)
                    || characteristic.properties.contains(.writeWithoutResponse)
                guard writable else { continue }
                if fallback == nil { fallback = characteristic }
                if service.uuid.uuidString.uppercased() == wantedService,
                   characteristic.uuid.uuidString.uppercased() == wantedChar {
                    exact = characteristic
                }
            }
        }
        writeCharacteristic = exact ?? fallback
        if let chosen = writeCharacteristic {
            diagnostics.append("→ 写入目标: \(chosen.service?.uuid.uuidString ?? "?")/\(chosen.uuid.uuidString)\(exact == nil ? "（按第一个可写特征回退）" : "（精确匹配）")")
        } else {
            diagnostics.append("→ 未找到任何可写特征！")
            lastError = "该设备没有可写特征，可能不是转台的控制模块"
        }
    }
}

// MARK: - CoreBluetooth 代理（回调都在 main queue，assumeIsolated 转回 MainActor）

extension TurntableService: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if case .connected = state { return }
                state = .idle
                reconnectRememberedIfNeeded()
            case .poweredOff:
                state = .bluetoothOff
            case .unauthorized:
                state = .unauthorized
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            let name = peripheral.name
                ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? "未知设备"
            let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let index = discovered.firstIndex(where: { $0.id == device.id }) {
                discovered[index] = device
            } else {
                discovered.append(device)
                discovered.sort { $0.rssi > $1.rssi }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            state = .connected(peripheral.name ?? "转台")
            config.rememberedDeviceID = peripheral.identifier.uuidString
            config.save()
            diagnostics = ["已连接 \(peripheral.name ?? peripheral.identifier.uuidString)，正在侦察服务…"]
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            state = .idle
            lastError = "连接失败：\(error?.localizedDescription ?? "未知错误")"
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            writeCharacteristic = nil
            state = .idle
            if error != nil {
                lastError = "转台连接断开，将在下次进入嘉宾模式时自动重连"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                diagnostics.append("服务 \(service.uuid.uuidString)")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                var props: [String] = []
                if characteristic.properties.contains(.write) { props.append("write") }
                if characteristic.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
                if characteristic.properties.contains(.notify) { props.append("notify") }
                if characteristic.properties.contains(.read) { props.append("read") }
                diagnostics.append("  特征 \(characteristic.uuid.uuidString) [\(props.joined(separator: ","))]")
            }
            pickWriteCharacteristic(for: peripheral)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                lastError = "指令写入失败：\(error.localizedDescription)"
            }
        }
    }
}
