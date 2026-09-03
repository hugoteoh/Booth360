import Foundation
import CoreBluetooth
import CoreMotion
import Observation

/// 转台蓝牙指令的十六进制解析（"A5 01 5A" / "0x01,0x02" / "a5015a" 均可）。纯逻辑，单测覆盖。
enum HexCommand {
    static func parse(_ text: String) -> Data? {
        // 逐 token 校验（不能全局拼接：否则 "0x1 0x2" 两个半字节会被误拼成 0x12）
        let tokens = text
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
        guard !tokens.isEmpty else { return nil }
        var data = Data()
        for token in tokens {
            var hex = String(token)
            if hex.lowercased().hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
            guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
        }
        return data.isEmpty ? nil : data
    }
}

/// 常见转台主板的协议预设（UUID 组合）。指令字节因品牌而异，在设置页可改。
enum TurntablePreset: String, CaseIterable, Identifiable {
    /// 用户实机：「360 Controller_xxxx」底座（KT6368A 模块）——FFF0 服务，FFF1 无响应写+通知
    case controller360
    /// HM-10/BT05 系透传模块（大量国产转台用这个）
    case uartFFE0
    /// FFF0 系透传模块（写在 FFF2 的那一类）
    case uartFFF0
    /// Nordic UART Service
    case nordicUART
    /// 完全自定义 UUID
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .controller360: return "360 Controller（FFF0 / FFF1）"
        case .uartFFE0: return "通用 FFE0（HM-10 系）"
        case .uartFFF0: return "通用 FFF0（写 FFF2）"
        case .nordicUART: return "Nordic UART"
        case .custom: return "自定义 UUID"
        }
    }

    var defaultServiceUUID: String {
        switch self {
        case .controller360: return "FFF0"
        case .uartFFE0: return "FFE0"
        case .uartFFF0: return "FFF0"
        case .nordicUART: return "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        case .custom: return ""
        }
    }

    var defaultWriteUUID: String {
        switch self {
        case .controller360: return "FFF1"
        case .uartFFE0: return "FFE1"
        case .uartFFF0: return "FFF2"
        case .nordicUART: return "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
        case .custom: return ""
        }
    }
}

/// 转台配置（UserDefaults 持久化）。
struct TurntableConfig: Equatable {
    var preset: TurntablePreset = .controller360
    var customServiceUUID: String = ""
    var customWriteUUID: String = ""
    /// 启动/停止指令（十六进制文本）。仅「自定义/通用」预设用；360 Controller 走 MWE 12 字节帧。
    var startHex: String = "01"
    var stopHex: String = "00"
    /// 360 Controller（MWE 主板）参数：速度档位 1–8（越大越快）、方向（顺/逆时针）。
    var speedLevel: Int = 5
    var clockwise: Bool = true
    /// 倒数一开始就起转：录制开始时转台已匀速，成片第一帧就是稳定环绕（ChackTok 同款做法）。
    var spinAtCountdown: Bool = true
    /// 按录制时长自动选档，让每条视频约转 turnsPerShot 圈（需先做「自动校准转速」）。
    var autoMatchTurns: Bool = false
    var turnsPerShot: Int = 1
    /// 校准表：档位 → 每转一圈的秒数（陀螺仪实测）。
    var secondsPerTurn: [Int: Double] = [:]
    var rememberedDeviceID: String?

    /// 给定录制时长应使用的档位：自动匹配时选「圈数最接近 turnsPerShot」的档，否则手动档。
    func speedLevel(forRecordingSeconds seconds: Int) -> Int {
        guard autoMatchTurns, !secondsPerTurn.isEmpty, seconds > 0 else { return speedLevel }
        let wanted = Double(max(turnsPerShot, 1))
        let best = secondsPerTurn.min { a, b in
            abs(Double(seconds) / a.value - wanted) < abs(Double(seconds) / b.value - wanted)
        }
        return best?.key ?? speedLevel
    }

    /// 某档在给定时长下预计转几圈（未校准返回 nil）。
    func predictedTurns(level: Int, recordingSeconds: Int) -> Double? {
        guard let spt = secondsPerTurn[level], spt > 0 else { return nil }
        return Double(recordingSeconds) / spt
    }

    var serviceUUID: String {
        preset == .custom ? customServiceUUID : preset.defaultServiceUUID
    }
    var writeUUID: String {
        preset == .custom ? customWriteUUID : preset.defaultWriteUUID
    }
    /// 该预设是否用 MWE 12 字节帧协议（否则用 startHex/stopHex 原始字节）。
    var usesMWEFrame: Bool { preset == .controller360 }

    private enum Key {
        static let preset = "booth360.turntable.preset"
        static let service = "booth360.turntable.serviceUUID"
        static let write = "booth360.turntable.writeUUID"
        static let start = "booth360.turntable.startHex"
        static let stop = "booth360.turntable.stopHex"
        static let speed = "booth360.turntable.speedLevel"
        static let clockwise = "booth360.turntable.clockwise"
        static let spinAtCountdown = "booth360.turntable.spinAtCountdown"
        static let autoMatchTurns = "booth360.turntable.autoMatchTurns"
        static let turnsPerShot = "booth360.turntable.turnsPerShot"
        static let secondsPerTurn = "booth360.turntable.secondsPerTurn"
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
        if defaults.object(forKey: Key.speed) != nil {
            config.speedLevel = min(max(defaults.integer(forKey: Key.speed), 1), 8)
        }
        if defaults.object(forKey: Key.clockwise) != nil {
            config.clockwise = defaults.bool(forKey: Key.clockwise)
        }
        if defaults.object(forKey: Key.spinAtCountdown) != nil {
            config.spinAtCountdown = defaults.bool(forKey: Key.spinAtCountdown)
        }
        config.autoMatchTurns = defaults.bool(forKey: Key.autoMatchTurns)
        if defaults.object(forKey: Key.turnsPerShot) != nil {
            config.turnsPerShot = min(max(defaults.integer(forKey: Key.turnsPerShot), 1), 3)
        }
        if let json = defaults.string(forKey: Key.secondsPerTurn),
           let data = json.data(using: .utf8),
           let table = try? JSONDecoder().decode([String: Double].self, from: data) {
            config.secondsPerTurn = Dictionary(uniqueKeysWithValues:
                table.compactMap { key, value in Int(key).map { ($0, value) } })
        }
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
        defaults.set(speedLevel, forKey: Key.speed)
        defaults.set(clockwise, forKey: Key.clockwise)
        defaults.set(spinAtCountdown, forKey: Key.spinAtCountdown)
        defaults.set(autoMatchTurns, forKey: Key.autoMatchTurns)
        defaults.set(turnsPerShot, forKey: Key.turnsPerShot)
        let table = Dictionary(uniqueKeysWithValues: secondsPerTurn.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(table), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Key.secondsPerTurn)
        }
        defaults.set(rememberedDeviceID, forKey: Key.device)
    }

    /// MWE 360 Controller 12 字节帧：AA CC [方向] [速度] 22 00 [时长s] 11 00 [校验] CC AA
    /// 校验 = 第 2…8 字节之和的低 8 位。方向 0x11 顺 / 0x22 逆 / 0x33 停；速度 0x11…0x88。
    static func mweFrame(switchByte: UInt8, speedLevel: Int, seconds: Int) -> Data {
        let speeds: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        let sp = speeds[min(max(speedLevel, 1), 8) - 1]
        let t = UInt8(min(max(seconds, 0), 60))
        var b: [UInt8] = [0xAA, 0xCC, switchByte, sp, 0x22, 0x00, t, 0x11, 0x00, 0, 0xCC, 0xAA]
        var sum = 0
        for i in 2...8 { sum += Int(b[i]) }
        b[9] = UInt8(sum & 0xFF)
        return Data(b)
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

    /// 开始旋转（测试/通用入口，用手动档位）。seconds 为帧内自动停止时长（兜底）。
    func sendStart(seconds: Int = 60) {
        startSpin(level: config.speedLevel, seconds: seconds)
    }

    /// 拍摄起转：leadSeconds 是提前量（倒数秒数），recordingSeconds 是录制时长。
    /// 档位按「自动匹配圈数」或手动档决定；帧内自停 = 提前量 + 录制 + 3 秒兜底，录完仍显式发停止。
    func startSpin(recordingSeconds: Int, leadSeconds: Int) {
        let level = config.speedLevel(forRecordingSeconds: recordingSeconds)
        lastUsedSpeedLevel = level
        startSpin(level: level, seconds: leadSeconds + recordingSeconds + 3)
    }

    /// 最近一次拍摄实际用的档位（自动匹配时便于在界面显示）。
    private(set) var lastUsedSpeedLevel: Int?

    private func startSpin(level: Int, seconds: Int) {
        if config.usesMWEFrame {
            let sw: UInt8 = config.clockwise ? 0x11 : 0x22
            sendData(TurntableConfig.mweFrame(switchByte: sw, speedLevel: level, seconds: seconds),
                     label: "启动(\(level)档)")
        } else {
            sendHex(config.startHex, label: "启动")
        }
    }

    // MARK: - 转速自动校准（手机装在转台臂上，用陀螺仪测每档几秒一圈）

    private(set) var isCalibrating = false
    private(set) var calibrationStatus: String?

    /// 逐档起转 → 等 4 秒加速 → 采 4 秒陀螺仪 → 停 2 秒；8 档约 90 秒。结果写入 config.secondsPerTurn。
    func calibrateSpinRates() {
        guard !isCalibrating else { return }
        guard isConnected, config.usesMWEFrame else {
            calibrationStatus = "请先连接 360 Controller 转台"
            return
        }
        let motion = CMMotionManager()
        guard motion.isDeviceMotionAvailable else {
            calibrationStatus = "此设备没有陀螺仪，无法自动校准"
            return
        }
        isCalibrating = true
        calibrationStatus = "准备校准…请确认手机已固定在转台臂上"
        Task { [weak self] in
            guard let self else { return }
            let sampler = SpinRateSampler()
            motion.deviceMotionUpdateInterval = 1.0 / 50.0
            motion.startDeviceMotionUpdates(to: OperationQueue()) { dm, _ in
                guard let dm else { return }
                sampler.add(deviceMotion: dm)
            }
            var table: [Int: Double] = [:]
            var problems: [String] = []
            for level in 1...8 {
                self.calibrationStatus = "第 \(level)/8 档：起转加速中…"
                self.startSpin(level: level, seconds: 12)
                try? await Task.sleep(for: .seconds(4))
                sampler.reset()
                self.calibrationStatus = "第 \(level)/8 档：测速中…"
                try? await Task.sleep(for: .seconds(4))
                let degPerSec = sampler.medianDegreesPerSecond()
                self.sendStop()
                if degPerSec > 5 {
                    table[level] = 360.0 / degPerSec
                    self.calibrationStatus = String(format: "第 %d 档：%.1f 秒/圈", level, 360.0 / degPerSec)
                } else {
                    problems.append("\(level)")
                    self.calibrationStatus = "第 \(level) 档未测到旋转"
                }
                try? await Task.sleep(for: .seconds(2))
            }
            motion.stopDeviceMotionUpdates()
            if !table.isEmpty {
                self.config.secondsPerTurn = table
                self.config.save()
            }
            self.isCalibrating = false
            self.calibrationStatus = problems.isEmpty
                ? "校准完成：8 档转速已记录"
                : "校准完成（第 \(problems.joined(separator: "、")) 档未测到旋转——手机是否固定在转台臂上？）"
        }
    }

    func sendStop() {
        if config.usesMWEFrame {
            sendData(TurntableConfig.mweFrame(switchByte: 0x33, speedLevel: config.speedLevel,
                                              seconds: 0), label: "停止")
        } else {
            sendHex(config.stopHex, label: "停止")
        }
    }

    /// 测试：转 seconds 秒后自动停。
    func testSpin(seconds: Double = 3) {
        sendStart(seconds: Int(seconds))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.sendStop()
        }
    }

    private func sendHex(_ hex: String, label: String) {
        guard let data = HexCommand.parse(hex) else {
            lastError = "\(label)指令不是有效的十六进制：\(hex)"
            return
        }
        sendData(data, label: label)
    }

    private func sendData(_ data: Data, label: String) {
        guard let peripheral, let characteristic = writeCharacteristic else {
            lastError = "未连接转台或未找到可写特征"
            return
        }
        // 360 Controller 的 FFF1 只支持无响应写；有 write 属性时才用带响应写
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
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
            // 之前某个无可写特征的服务可能已把错误挂上，找到目标后清掉
            if lastError == Self.noWritableMessage { lastError = nil }
        } else if pendingCharacteristicDiscoveries == 0 {
            // 只有所有服务的特征都侦察完仍没找到，才算真的没有（避免先到的服务误报）
            diagnostics.append("→ 未找到任何可写特征！")
            lastError = Self.noWritableMessage
        }
    }

    private static let noWritableMessage = "该设备没有可写特征，可能不是转台的控制模块"
    /// 还没返回特征列表的服务数；归零后才能断言“没有可写特征”。
    @ObservationIgnored private var pendingCharacteristicDiscoveries = 0
}

/// 陀螺仪采样：取绕重力轴（竖直轴）的角速度——不管手机怎么装在臂上都成立。线程安全。
final class SpinRateSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []

    func add(deviceMotion dm: CMDeviceMotion) {
        let g = dm.gravity, r = dm.rotationRate
        let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard norm > 0 else { return }
        let radPerSec = (r.x * g.x + r.y * g.y + r.z * g.z) / norm
        lock.lock(); samples.append(abs(radPerSec) * 180 / .pi); lock.unlock()
    }

    func reset() {
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    /// 中位数（度/秒），抗加速段与抖动。
    func medianDegreesPerSecond() -> Double {
        lock.lock(); let s = samples.sorted(); lock.unlock()
        guard !s.isEmpty else { return 0 }
        return s[s.count / 2]
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
            let services = peripheral.services ?? []
            pendingCharacteristicDiscoveries = services.count
            for service in services {
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
            pendingCharacteristicDiscoveries = max(0, pendingCharacteristicDiscoveries - 1)
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
