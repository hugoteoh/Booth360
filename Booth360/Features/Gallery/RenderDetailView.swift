import SwiftUI
import SwiftData
import AVKit
import Photos

/// 成品详情：播放、收藏、分享、存相册、上传/重试、二维码、重剪、删除。
struct RenderDetailView: View {
    @Bindable var render: RenderedVideo
    let storage: FileStorageService

    @Query private var sourceClips: [SourceClip]
    @Environment(\.modelContext) private var modelContext
    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var showQRSheet = false
    @State private var showDeleteConfirm = false
    @State private var message: String?

    init(render: RenderedVideo, storage: FileStorageService) {
        self.render = render
        self.storage = storage
        let sourceID = render.sourceClipID ?? UUID()
        _sourceClips = Query(filter: #Predicate<SourceClip> { $0.id == sourceID })
    }

    private var fileURL: URL { storage.renderURL(fileName: render.fileName) }
    private var fileExists: Bool { storage.fileExists(at: fileURL) }

    var body: some View {
        List {
            Section {
                // 固定容器 + 播放器自居中：避免 List 内 aspectRatio 首次布局把视频锚到左侧的系统 bug
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 430)
                    .background(Color.black)
                    .listRowInsets(EdgeInsets())
                    .onAppear {
                        guard fileExists else { return }
                        let player = AVPlayer(url: fileURL)
                        self.player = player
                        player.play()
                    }
                    .onDisappear { player?.pause() }
            }

            Section("信息") {
                LabeledContent("参数", value: render.settingsSummary)
                LabeledContent("时长", value: String(format: "%.1f 秒", render.durationSeconds))
                LabeledContent("尺寸", value: "\(render.width)×\(render.height)")
                LabeledContent("大小", value: String(
                    format: "%.0f MB", Double(storage.fileSizeInBytes(at: fileURL)) / 1_000_000))
                LabeledContent("上传状态") {
                    Label(render.uploadState.displayName, systemImage: render.uploadState.iconName)
                        .foregroundStyle(render.uploadState == .failed ? .red : .secondary)
                }
                if let error = render.lastUploadError, render.uploadState == .failed {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("操作") {
                Toggle(isOn: $render.isFavorite) {
                    Label("收藏", systemImage: "star")
                }
                .onChange(of: render.isFavorite) { _, _ in try? modelContext.save() }

                Toggle(isOn: $render.hiddenFromWall) {
                    Label("隐藏，不上大屏", systemImage: "eye.slash")
                }
                .onChange(of: render.hiddenFromWall) { _, _ in
                    try? modelContext.save()
                    // 云端大屏立即刷新（本地大屏下一次轮询自动生效）
                    uploadQueue.republishWall()
                }

                ShareLink(item: fileURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .disabled(!fileExists)

                Button {
                    Task { await saveToPhotos() }
                } label: {
                    Label("存入相册", systemImage: "photo.badge.plus")
                }
                .disabled(!fileExists)

                uploadRow

                if render.uploadState == .done, render.remoteURLString != nil {
                    Button {
                        showQRSheet = true
                    } label: {
                        Label("显示下载二维码", systemImage: "qrcode")
                    }
                }

                if let sourceClip = sourceClips.first {
                    NavigationLink {
                        EditView(clip: sourceClip, storage: storage)
                    } label: {
                        Label("用源片重剪 / 重新导出", systemImage: "wand.and.stars")
                    }
                }

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除成品", systemImage: "trash")
                }
            }
        }
        .navigationTitle("成品详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showQRSheet) {
            if let urlString = render.remoteURLString {
                QRCodeSheet(urlString: urlString)
            }
        }
        .confirmationDialog("确认删除这个成品？源片段不受影响。",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                storage.deleteFileIfExists(at: fileURL)
                modelContext.delete(render)
                try? modelContext.save()
                dismiss()
            }
        }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private var uploadRow: some View {
        switch render.uploadState {
        case .none:
            Button {
                if uploadQueue.isEnabled {
                    uploadQueue.enqueue(render)
                } else {
                    message = "上传功能未开启。请到 设置 → 上传 选择 Mock 或腾讯云 COS。"
                }
            } label: {
                Label("上传并生成二维码", systemImage: "icloud.and.arrow.up")
            }
            .disabled(!fileExists)
        case .failed:
            Button {
                uploadQueue.retryNow(render)
            } label: {
                Label("重试上传", systemImage: "arrow.clockwise.icloud")
            }
        case .queued, .uploading:
            HStack {
                Label(render.uploadState.displayName, systemImage: render.uploadState.iconName)
                Spacer()
                if let progress = uploadQueue.progressByID[render.id] {
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .frame(width: 70)
                } else {
                    ProgressView()
                }
            }
        case .done:
            EmptyView()
        }
    }

    private func saveToPhotos() async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
            message = "已保存到相册"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 二维码弹层：扫码下载 + 复制/分享链接。
struct QRCodeSheet: View {
    let urlString: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text("扫码下载视频")
                .font(.title2.weight(.semibold))
            if let image = QRCodeGenerator.image(for: urlString) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            } else {
                Text("二维码生成失败").foregroundStyle(.red)
            }
            Text(urlString)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(.horizontal)
            if let url = URL(string: urlString) {
                ShareLink(item: url) {
                    Label("分享链接", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            Button("关闭") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .presentationDetents([.large])
    }
}
