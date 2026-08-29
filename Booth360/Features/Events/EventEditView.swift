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
    /// 注意：类型与“选择器是否打开”必须是两个状态——fileImporter 会先关闭再回调，
    /// 若用同一个 Optional 承担两职，回调时类型已被清空，导入会静默失败。
    @State private var importTarget: EventManager.AssetKind = .music
    @State private var importerPresented = false
    @State private var errorMessage: String?
    /// 效果参数以值类型草稿绑定，onChange 回写 Data。
    @State private var effectDraft = EffectSettings()
    /// 拍摄模式草稿（勾选启用 + 每模式时长）。
    @State private var shotModesDraft: [ShotMode] = []

    private var manager: EventManager { EventManager(storage: storage) }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("活动名称", text: $event.name)
                Stepper("成品页 \(event.autoReturnSeconds)s 后自动返回",
                        value: $event.autoReturnSeconds, in: 5...120, step: 5)
            }

            Section {
                assetPickerRow(title: "Logo", fileName: event.logoFileName,
                               item: $logoPickerItem, kind: .logo)
                assetPickerRow(title: "欢迎页背景", fileName: event.backgroundFileName,
                               item: $backgroundPickerItem, kind: .background)
                assetPickerRow(title: "Overlay（透明 PNG）", fileName: event.overlayFileName,
                               item: $overlayPickerItem, kind: .overlay)
                fileAssetRow(title: "背景音乐", value: event.musicDisplayName, kind: .music)
                fileAssetRow(title: "动态 Overlay（透明 HEVC 视频）",
                             value: event.overlayVideoFileName, kind: .overlayVideo)
                fileAssetRow(title: "片头视频（Intro）", value: event.introFileName, kind: .intro)
                fileAssetRow(title: "片尾视频（Outro）", value: event.outroFileName, kind: .outro)
            } header: {
                Text("品牌素材")
            } footer: {
                Text("长按已设置的素材行可移除。")
            }

            // 镜头/帧率/倒数在拍摄页直接调（右上角光圈菜单 + 底部倒数胶囊），不进活动模板
            Section("转台") {
                Toggle("转台起转自动开拍", isOn: $event.motionTriggerEnabled)
                Toggle("拍摄时蓝牙控制转台旋转", isOn: $event.turntableSpinEnabled)
            }

            Section {
                ForEach($shotModesDraft) { $mode in
                    HStack(spacing: 12) {
                        Toggle(isOn: $mode.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(mode.kind.displayName, systemImage: mode.kind.sfSymbol)
                                Text(mode.kind.curveDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Menu {
                            ForEach(Array(ShotModeKind.secondsRange), id: \.self) { seconds in
                                Button("\(seconds) 秒") { mode.recordingSeconds = seconds }
                            }
                        } label: {
                            Text("\(mode.recordingSeconds)s")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(.systemGray5), in: Capsule())
                        }
                    }
                }
            } header: {
                Text("拍摄模式（勾选的会出现在拍摄页底部）")
            } footer: {
                Text("每个模式可设独立录制时长；含「回旋」的模式处理时间稍长（需生成倒放素材，二次起走缓存）。")
            }

            Section("效果参数") {
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
        .onAppear {
            effectDraft = event.effectSettings
            shotModesDraft = event.shotModes
        }
        .onChange(of: effectDraft) { _, newValue in
            event.effectSettings = newValue
            try? modelContext.save()
        }
        .onChange(of: shotModesDraft) { _, newValue in
            event.shotModes = newValue
            try? modelContext.save()
        }
        .onChange(of: logoPickerItem) { _, item in importImage(item, kind: .logo) }
        .onChange(of: backgroundPickerItem) { _, item in importImage(item, kind: .background) }
        .onChange(of: overlayPickerItem) { _, item in importImage(item, kind: .overlay) }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: importTarget == .music ? [.audio] : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { result in
            importFile(result, kind: importTarget)
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
        item: Binding<PhotosPickerItem?>,
        kind: EventManager.AssetKind
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
        .contextMenu {
            if fileName != nil {
                Button(role: .destructive) {
                    removeAsset(kind)
                } label: {
                    Label("移除\(title)", systemImage: "trash")
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
            importTarget = kind
            importerPresented = true
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
        .contextMenu {
            if value != nil {
                Button(role: .destructive) {
                    removeAsset(kind)
                } label: {
                    Label("移除\(title)", systemImage: "trash")
                }
            }
        }
    }

    /// 移除素材：删文件 + 清字段，并关掉对应效果开关。
    private func removeAsset(_ kind: EventManager.AssetKind) {
        manager.removeAsset(kind: kind, from: event)
        switch kind {
        case .overlay: effectDraft.overlayEnabled = false
        case .music: effectDraft.musicEnabled = false
        case .overlayVideo: effectDraft.overlayVideoEnabled = false
        case .intro: effectDraft.introEnabled = false
        case .outro: effectDraft.outroEnabled = false
        case .logo, .background: break
        }
        try? modelContext.save()
    }

    private func importFile(_ result: Result<URL, Error>, kind: EventManager.AssetKind) {
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
