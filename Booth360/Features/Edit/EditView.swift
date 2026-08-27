import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// 编辑/导出入口。VM 在 MainActor 的 .task 里创建，避免在 View.init 里触碰 @MainActor 类型。
struct EditView: View {
    let clip: SourceClip
    let storage: FileStorageService
    @State private var viewModel: EditViewModel?

    var body: some View {
        Group {
            if let viewModel {
                EditFormView(viewModel: viewModel)
            } else {
                ProgressView()
                    .task { viewModel = EditViewModel(clip: clip, storage: storage) }
            }
        }
        .navigationTitle("效果与导出")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EditFormView: View {
    @Bindable var viewModel: EditViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(UploadQueue.self) private var uploadQueue
    @State private var overlayPickerItem: PhotosPickerItem?

    private enum FileImportTarget {
        case music
        case overlayVideo
    }
    @State private var importTarget: FileImportTarget?

    var body: some View {
        ZStack {
            form
            if viewModel.engine.isBusy {
                processingOverlay
            }
        }
        .sheet(item: $viewModel.presentation) { presentation in
            ResultPlayerSheet(
                presentation: presentation,
                onSaveToPhotos: { url in Task { await viewModel.saveToPhotos(url: url) } }
            )
        }
        .alert("出错了", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: overlayPickerItem) { _, newItem in
            Task { await viewModel.importOverlay(newItem) }
        }
        .onChange(of: viewModel.settings.overlayEnabled) { _, _ in viewModel.persistToggles() }
        .onChange(of: viewModel.settings.musicEnabled) { _, _ in viewModel.persistToggles() }
        .onChange(of: viewModel.settings.overlayVideoEnabled) { _, _ in viewModel.persistToggles() }
        .fileImporter(
            isPresented: Binding(
                get: { importTarget != nil },
                set: { if !$0 { importTarget = nil } }
            ),
            allowedContentTypes: importTarget == .music
                ? [.audio] : [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            onCompletion: { result in
                let target = importTarget
                importTarget = nil
                switch target {
                case .music: viewModel.importMusic(result: result)
                case .overlayVideo: viewModel.importOverlayVideo(result: result)
                case nil: break
                }
            }
        )
    }

    // MARK: - 表单

    private var form: some View {
        Form {
            Section("源片段") {
                LabeledContent("素材", value: viewModel.clip.summaryText)
                LabeledContent("成品预计时长",
                               value: String(format: "%.1f 秒", viewModel.estimatedOutputSeconds))
            }

            Section("效果") {
                Picker("变速", selection: $viewModel.settings.speed) {
                    ForEach(SpeedEffect.allCases) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
                Picker("播放方式", selection: $viewModel.settings.style) {
                    ForEach(PlaybackStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Stepper("循环 ×\(viewModel.settings.loopCount)",
                        value: $viewModel.settings.loopCount, in: 1...3)
            }

            Section {
                Toggle("使用 Overlay", isOn: $viewModel.settings.overlayEnabled)
                    .disabled(viewModel.overlayImage == nil)
                PhotosPicker(selection: $overlayPickerItem, matching: .images) {
                    HStack {
                        Text(viewModel.overlayImage == nil ? "选择 Overlay 图片…" : "更换 Overlay 图片…")
                        Spacer()
                        if let image = viewModel.overlayImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                Toggle("使用动态 Overlay（视频）", isOn: $viewModel.settings.overlayVideoEnabled)
                    .disabled(viewModel.overlayVideoFileName == nil)
                Button(viewModel.overlayVideoFileName == nil ? "选择动态 Overlay 视频…" : "更换动态 Overlay 视频…") {
                    importTarget = .overlayVideo
                }
            } header: {
                Text("Overlay")
            } footer: {
                Text("静态图推荐与输出画幅一致的透明 PNG（如 1080×1920）。动态 Overlay 需要带透明通道的 HEVC .mov（不透明视频会完全盖住画面），预览与导出都会生效。")
            }

            Section {
                Toggle("背景音乐", isOn: $viewModel.settings.musicEnabled)
                    .disabled(viewModel.musicFileName == nil)
                Button(viewModel.musicFileName == nil ? "选择音乐文件…" : "更换音乐文件…") {
                    importTarget = .music
                }
                if let name = viewModel.musicDisplayName {
                    LabeledContent("当前音乐", value: name)
                }
                if viewModel.settings.musicEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("音乐音量")
                            Spacer()
                            Text("\(Int(viewModel.settings.musicVolume * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $viewModel.settings.musicVolume, in: 0...1)
                    }
                }
            } header: {
                Text("音乐")
            }

            Section {
                Toggle("保留原视频声音", isOn: $viewModel.settings.originalAudioEnabled)
                    .disabled(!viewModel.settings.canUseOriginalAudio)
            } footer: {
                if !viewModel.settings.canUseOriginalAudio {
                    Text("变速 / 倒放 / Boomerang 会导致声音变调或倒转，这些效果下原声自动关闭。")
                }
            }

            Section("输出") {
                Picker("画幅", selection: $viewModel.settings.aspect) {
                    ForEach(OutputAspect.allCases) { aspect in
                        Text(aspect.displayName).tag(aspect)
                    }
                }
                Picker("分辨率", selection: $viewModel.settings.resolution) {
                    // 4K 输出需要 4K 源片（1080p 源放大画质无提升）
                    ForEach(OutputResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                Picker("编码", selection: $viewModel.settings.codec) {
                    ForEach(OutputCodec.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
            }

            Section {
                Button {
                    Task { await viewModel.previewTapped() }
                } label: {
                    Label("预览效果", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    Task { await viewModel.exportTapped(modelContext: modelContext, uploadQueue: uploadQueue) }
                } label: {
                    Label("导出成品", systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
        .disabled(viewModel.engine.isBusy)
    }

    // MARK: - 处理中覆盖层

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView(value: viewModel.engine.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(viewModel.engine.stage.displayText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text("\(Int(viewModel.engine.progress * 100))%")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                Button("取消") {
                    viewModel.engine.cancel()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
