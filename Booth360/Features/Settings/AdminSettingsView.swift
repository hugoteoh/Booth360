import SwiftUI

/// 管理员设置：嘉宾模式 PIN、上传后端（Mock / 腾讯云 COS）、系统状态。
struct AdminSettingsView: View {
    @Environment(SystemStatusMonitor.self) private var monitor
    @Environment(LANControlServer.self) private var lanServer
    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(TurntableService.self) private var turntable

    private var turntableStateBrief: String {
        if case .connected(let name) = turntable.state { return name }
        return "未连接"
    }

    @State private var pin = PINPadView.storedPIN
    @State private var uploadMode = UploadMode.current
    @State private var cosConfig = COSConfig.load()
    @State private var profile = AccountStore.load()
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("管理员 PIN")
                    Spacer()
                    TextField("4 位数字", text: $pin)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .onChange(of: pin) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(4))
                            pin = digits
                            if digits.count == 4 {
                                UserDefaults.standard.set(digits, forKey: "booth360.adminPIN")
                            }
                        }
                }
            } header: {
                Text("嘉宾模式")
            } footer: {
                Text("嘉宾模式中长按屏幕左上角 2 秒，输入 PIN 退出。默认 1234。现场建议同时开启 iOS「引导式访问」（设置 → 辅助功能）防止误触退出 App。")
            }

            Section {
                Picker("上传方式", selection: $uploadMode) {
                    ForEach(UploadMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: uploadMode) { _, newValue in
                    UploadMode.current = newValue
                    // 打开上传即自动补传所有历史成品，无需手动
                    uploadQueue.enqueueAllPending()
                }

                if uploadMode == .cos {
                    TextField("Region（如 ap-shanghai）", text: $cosConfig.region)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Bucket（含 APPID，如 name-1250000000）", text: $cosConfig.bucket)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("SecretId", text: $cosConfig.secretId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("SecretKey（存入 Keychain）", text: $cosConfig.secretKey)
                    Button("保存 COS 配置") {
                        cosConfig.save()
                        if cosConfig.isComplete {
                            uploadQueue.enqueueAllPending()
                            message = "已保存。所有未上传的成品已自动排入上传队列。"
                        } else {
                            message = "已保存，但配置不完整，上传会失败。"
                        }
                    }
                    Toggle("云端大屏（不同网络的大屏用）", isOn: Binding(
                        get: { UploadQueue.cloudWallEnabled },
                        set: { UploadQueue.cloudWallEnabled = $0 }
                    ))
                    if UploadQueue.cloudWallEnabled, cosConfig.isComplete,
                       let wallURL = CloudWallPublisher.pageURLString {
                        LabeledContent("云端大屏地址", value: wallURL)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("上传 / 二维码")
            } footer: {
                if uploadMode == .cos {
                    Text("视频上传到你的腾讯云 COS 桶（对象键 booth360/<id>/<文件名>），二维码为 7 天有效的预签名下载链接。SecretKey 只存在本机 Keychain。\n\n云端大屏：每次上传完成自动把节目单发布到桶里，任何网络的电脑打开上面地址即可全屏展示（无需与手机同网）；页面公开可读，知道链接的人都能看，活动结束可到 COS 控制台删除 booth360/wall/ 目录下架。")
                } else if uploadMode == .mock {
                    Text("Mock 模式只在本机模拟上传流程（2 秒延时 + 假链接），用于无网/未配置时联调。")
                }
            }

            Section {
                NavigationLink {
                    TurntableSettingsView()
                } label: {
                    LabeledContent("转台设备（蓝牙）") {
                        Text(turntableStateBrief)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("360 转台")
            } footer: {
                Text("连接转台后，在活动设置里打开「拍摄时蓝牙控制转台旋转」，嘉宾点开始转台自动转、录完自动停。")
            }

            Section {
                Toggle("局域网控制", isOn: Binding(
                    get: { lanServer.isRunning },
                    set: { $0 ? lanServer.start() : lanServer.stop() }
                ))
                if lanServer.isRunning, let url = lanServer.displayURL {
                    LabeledContent("控制台地址", value: url)
                        .textSelection(.enabled)
                    LabeledContent("大屏展示页", value: "\(url)/wall")
                        .textSelection(.enabled)
                }
                if let error = lanServer.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Windows 局域网控制")
            } footer: {
                Text("开启后，同一 Wi-Fi 的电脑用浏览器打开「控制台地址」可查看状态、切换活动、远程开始拍摄（操作需 PIN）；打开「大屏展示页」并按 F11 全屏投到大电视——最新视频自动上屏循环播放、嘉宾扫旁边二维码下载（视频走局域网，二维码在上传完成后自动出现）。首次开启 iOS 会请求“本地网络”权限，请允许。现场没有路由器时，手机开「个人热点」让电脑连上来即可。")
            }

            Section {
                TextField("门店 / 团队名称（显示在欢迎页底部）", text: $profile.studioName)
                    .onChange(of: profile.studioName) { _, _ in AccountStore.save(profile) }
                TextField("联系方式（仅本机备查）", text: $profile.contact)
                    .onChange(of: profile.contact) { _, _ in AccountStore.save(profile) }
            } header: {
                Text("运营信息")
            } footer: {
                Text("多设备账号与云端同步需要配套后端，规划在后续版本。")
            }

            Section("系统状态") {
                LabeledContent("剩余存储", value: String(
                    format: "%.1f GB", Double(monitor.availableBytes) / 1_000_000_000))
                LabeledContent("电量", value: monitor.batteryLevel < 0
                    ? "未知" : "\(Int(monitor.batteryLevel * 100))%")
                LabeledContent("温度状态", value: thermalText)
                ForEach(monitor.warnings) { warning in
                    Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(warning.isCritical ? .red : .yellow)
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "0.1.0 (Phase 3)")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { monitor.refresh() }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var thermalText: String {
        switch monitor.thermalState {
        case .nominal: return "正常"
        case .fair: return "略热"
        case .serious: return "偏高"
        case .critical: return "过热！"
        @unknown default: return "未知"
        }
    }
}
