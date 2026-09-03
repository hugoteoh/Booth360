import SwiftUI

/// 转台蓝牙设置：扫描连接、协议预设、指令配置、测试旋转、设备诊断。
/// 拿到新品牌转台时：连接 → 看诊断 → 试预设/自定义指令，试出来后指令会被记住。
struct TurntableSettingsView: View {
    @Environment(TurntableService.self) private var turntable
    @State private var config = TurntableConfig.load()

    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: turntable.state.displayText)
                if let error = turntable.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if turntable.isConnected {
                    Button("断开并忘记该设备", role: .destructive) {
                        turntable.disconnectAndForget()
                    }
                } else {
                    Button(turntable.state == .scanning ? "停止扫描" : "扫描附近设备") {
                        turntable.state == .scanning ? turntable.stopScan() : turntable.startScan()
                    }
                }
            } header: {
                Text("连接")
            } footer: {
                Text("打开转台电源，点扫描，在列表里点你的转台（通常名字含 BT/BLE/型号缩写，信号最强的往往就是）。连接成功后会记住，嘉宾模式自动重连。")
            }

            if !turntable.isConnected, !turntable.discovered.isEmpty {
                Section("附近设备（按信号强度）") {
                    ForEach(turntable.discovered) { device in
                        Button {
                            turntable.connect(deviceID: device.id)
                        } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            if config.usesMWEFrame {
                Section {
                    Stepper("旋转速度：\(config.speedLevel) 档（1 慢 – 8 快）",
                            value: $config.speedLevel, in: 1...8)
                    Picker("旋转方向", selection: $config.clockwise) {
                        Text("顺时针").tag(true)
                        Text("逆时针").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("旋转参数（360 Controller）")
                } footer: {
                    Text("这台是「360 Controller」底座（MWE 主板），已内置匹配的控制协议。速度和方向在这里调，拍摄时自动套用。")
                }
            }

            Section {
                Picker("协议预设", selection: $config.preset) {
                    ForEach(TurntablePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                if config.preset == .custom {
                    TextField("服务 UUID（如 FFE0）", text: $config.customServiceUUID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    TextField("写入特征 UUID（如 FFE1）", text: $config.customWriteUUID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                if !config.usesMWEFrame {
                    TextField("启动指令（十六进制，如 01 或 A5 01 5A）", text: $config.startHex)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("停止指令", text: $config.stopHex)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("协议")
            } footer: {
                Text("你的转台默认已选「360 Controller」并配好协议，无需改动。换其他品牌转台时才需在此切换预设或填自定义指令。")
            }

            Section("测试") {
                Button {
                    turntable.testSpin(seconds: 3)
                } label: {
                    Label("测试：旋转 3 秒", systemImage: "rotate.3d.circle")
                }
                .disabled(!turntable.isConnected)
            }

            if !turntable.diagnostics.isEmpty {
                Section("设备诊断（发给开发者定制协议用）") {
                    ForEach(Array(turntable.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("转台设备")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { turntable.activate() }
        .onChange(of: config) { _, newValue in
            newValue.save()
            turntable.config = newValue
            turntable.reresolveCharacteristic()
        }
    }
}
