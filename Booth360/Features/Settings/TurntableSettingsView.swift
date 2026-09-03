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
                        .disabled(config.autoMatchTurns)
                    Picker("旋转方向", selection: $config.clockwise) {
                        Text("顺时针").tag(true)
                        Text("逆时针").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle("倒数时提前起转", isOn: $config.spinAtCountdown)
                } header: {
                    Text("旋转参数（360 Controller）")
                } footer: {
                    Text("倒数时提前起转：按下快门倒数一开始转台就起转，倒数结束时已匀速，成片第一帧就是稳定环绕（推荐开启）。")
                }

                Section {
                    Toggle("按录制时长自动匹配圈数", isOn: $config.autoMatchTurns)
                        .disabled(config.secondsPerTurn.isEmpty)
                    if config.autoMatchTurns {
                        Stepper("每条视频转 \(config.turnsPerShot) 圈", value: $config.turnsPerShot, in: 1...3)
                    }
                    Button {
                        turntable.calibrateSpinRates()
                    } label: {
                        Label(turntable.isCalibrating ? "校准中…" : "自动校准转速（约 90 秒）",
                              systemImage: "gyroscope")
                    }
                    .disabled(!turntable.isConnected || turntable.isCalibrating)
                    if let status = turntable.calibrationStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if !config.secondsPerTurn.isEmpty {
                        ForEach(config.secondsPerTurn.keys.sorted(), id: \.self) { level in
                            LabeledContent("第 \(level) 档",
                                           value: String(format: "%.1f 秒/圈", config.secondsPerTurn[level] ?? 0))
                                .font(.caption)
                        }
                        ForEach([5, 8, 10, 15], id: \.self) { secs in
                            let level = config.speedLevel(forRecordingSeconds: secs)
                            let turns = config.predictedTurns(level: level, recordingSeconds: secs) ?? 0
                            LabeledContent("录 \(secs) 秒 → 第 \(level) 档",
                                           value: String(format: "≈ %.2f 圈", turns))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("一圈自动匹配")
                } footer: {
                    Text("校准时把手机固定在转台臂上、清空转台，点按钮后 App 逐档起转并用陀螺仪测出每档几秒一圈。之后开启自动匹配，拍摄时会按该模式的录制时长自动选最接近整圈的档位。")
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
        // 校准结束后把服务里写入的校准表同步回本页
        .onChange(of: turntable.isCalibrating) { _, calibrating in
            if !calibrating { config = turntable.config }
        }
    }
}
