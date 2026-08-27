import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// 活动编辑：名称/文案、素材（Logo/背景/Overlay/音乐）、拍摄参数、效果参数。
/// SwiftData @Model 可直接 @Bindable 双向绑定，改动即持久化。
struct EventEditView: View {
    @Bindable var event: EventTemplate
    let storage: FileStorageService

    @Environment(\.modelContext) private var modelContext
    @State private var logoPickerItem: PhotosPickerItem?
    @State private var backgroundPickerItem: PhotosPickerItem?
    @State private var overlayPickerItem: PhotosPickerItem?
    /// 当前正在通过文件选择器导入的素材类型（音乐/片头/片尾/动态 Overlay）。
    @State private var importKind: EventManager.AssetKind?
    @State private var errorMessage: String?
    /// 效果参数以值类型草稿绑定，onChange 回写 Data。
    @State private var effectDraft = EffectSettings()

    private var manager: EventManager { EventManager(storage: storage) }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("活动名称", text: $event.name)
                TextField("欢迎标题", text: $event.welcomeTitle)
                TextField("欢迎副标题", text: $event.welcomeSubtitle)
                Stepper("成品页 \(event.autoReturnSeconds)s 后自动返回",
                        value: $event.autoReturnSeconds, in: 5...120, step: 5)
            }

            Section("品牌素材") {
                assetPickerRow(title: "Logo", fileName: event.logoFileName, item: $logoPickerItem)
                assetPickerRow(title: "欢迎页背景", fileName: event.backgroundFileName, item: $backgroundPickerItem)
                assetPickerRow(title: "Overlay（透明 PNG）", fileName: event.overlayFileName, item: $overlayPickerItem)
                fileAssetRow(title: "背景音乐", value: event.musicDisplayName, kind: .music)
                fileAssetRow(title: "动态 Overlay（透明 HEVC 视频）",
                             value: event.overlayVideoFileName, kind: .overlayVideo)
                fileAssetRow(title: "片头视频（Intro）", value: event.introFileName, kind: .intro)
                fileAssetRow(title: "片尾视频（Outro）", value: event.outroFileName, kind: .outro)
            }

            Section("拍摄参数") {
                Picker("镜头", selection: $event.lensRawValue) {
                    ForEach(CameraLens.allCases) { lens in
                        Text(lens.displayName).tag(lens.rawValue)
                    }
                }
                Picker("帧率（设备不支持时自动降级）", selection: $event.frameRateRawValue) {
                    ForEach(CaptureFrameRate.allCases) { rate in
                        Text(rate.displayName).tag(rate.rawValue)
                    }
                }
                Picker("倒数", selection: $event.countdownSeconds) {
                    ForEach(RecordingSettings.countdownChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "不倒数" : "\(seconds) 秒").tag(seconds)
                    }
                }
                Picker("录制时长", selection: $event.recordingSeconds) {
                    ForEach(RecordingSettings.durationChoices, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                Toggle("转台起转自动开拍", isOn: $event.motionTriggerEnabled)
                Toggle("拍摄时蓝牙控制转台旋转", isOn: $event.turntableSpinEnabled)
            }

            Section("效果参数") {
                Picker("变速", selection: $effectDraft.speed) {
                    ForEach(SpeedEffect.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("播放方式", selection: $effectDraft.style) {
                    ForEach(PlaybackStyle.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("循环 ×\(effectDraft.loopCount)", value: $effectDraft.loopCount, in: 1...3)
                Toggle("美颜（磨皮 · 柔光 · 提亮）", isOn: $effectDraft.beautyEnabled)
                if effectDraft.beautyEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("美颜强度")
                            Spacer()
                            Text("\(Int(effectDraft.beautyStrength * 100))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $effectDraft.beautyStrength, in: 0...1)
                    }
                }
                Picker("滤镜", selection: $effectDraft.filterPreset) {
                    ForEach(FilterPreset.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("使用 Overlay", isOn: $effectDraft.overlayEnabled)
                    .disabled(event.overlayFileName == nil)
                Toggle("使用动态 Overlay", isOn: $effectDraft.overlayVideoEnabled)
                    .disabled(event.overlayVideoFileName == nil)
                Toggle("拼接片头", isOn: $effectDraft.introEnabled)
                    .disabled(event.introFileName == nil)
                Toggle("拼接片尾", isOn: $effectDraft.outroEnabled)
                    .disabled(event.outroFileName == nil)
                Toggle("背景音乐", isOn: $effectDraft.musicEnabled)
                    .disabled(event.musicFileName == nil)
                if effectDraft.musicEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("音乐音量")
                            Spacer()
                            Text("\(Int(effectDraft.musicVolume * 100))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $effectDraft.musicVolume, in: 0...1)
                    }
                }
                Picker("画幅", selection: $effectDraft.aspect) {
                    ForEach(OutputAspect.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("编码", selection: $effectDraft.codec) {
                    ForEach(OutputCodec.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { effectDraft = event.effectSettings }
        .onChange(of: effectDraft) { _, newValue in
            event.effectSettings = newValue
            try? modelContext.save()
        }
        .onChange(of: logoPickerItem) { _, item in importImage(item, kind: .logo) }
        .onChange(of: backgroundPickerItem) { _, item in importImage(item, kind: .background) }
        .onChange(of: overlayPickerItem) { _, item in importImage(item, kind: .overlay) }
        .fileImporter(
            isPresented: Binding(
                get: { importKind != nil },
                set: { if !$0 { importKind = nil } }
            ),
            allowedContentTypes: importKind == .music ? [.audio] : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { result in
            importFile(result)
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 行组件

    private func assetPickerRow(
        title: String,
        fileName: String?,
        item: Binding<PhotosPickerItem?>
    ) -> some View {
        PhotosPicker(selection: item, matching: .images) {
            HStack {
                Text(title)
                Spacer()
                if let fileName,
                   let image = manager.loadImage(event: event, fileName: fileName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("未设置").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 导入

    private func importImage(_ item: PhotosPickerItem?, kind: EventManager.AssetKind) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    errorMessage = "无法读取所选图片"
                    return
                }
                _ = try manager.importAsset(data: data, kind: kind, into: event)
                if kind == .overlay { syncDraftToggles() }
                try? modelContext.save()
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    /// 音乐/片头/片尾/动态 Overlay 的文件导入行。
    private func fileAssetRow(title: String, value: String?, kind: EventManager.AssetKind) -> some View {
        Button {
            importKind = kind
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value ?? "未设置")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.primary)
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard let kind = importKind else { return }
        importKind = nil
        switch result {
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try manager.importAsset(from: url, kind: kind, into: event)
                syncDraftToggles()
                try? modelContext.save()
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }

    /// 素材刚导入时自动打开对应开关（常见预期）。
    private func syncDraftToggles() {
        if event.overlayFileName != nil { effectDraft.overlayEnabled = true }
        if event.musicFileName != nil { effectDraft.musicEnabled = true }
        if event.overlayVideoFileName != nil { effectDraft.overlayVideoEnabled = true }
        if event.introFileName != nil { effectDraft.introEnabled = true }
        if event.outroFileName != nil { effectDraft.outroEnabled = true }
    }
}
