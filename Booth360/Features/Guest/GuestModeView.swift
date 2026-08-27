import SwiftUI
import SwiftData
import AVKit

/// 嘉宾模式全屏界面。退出只能通过 隐藏角落长按 2 秒 → 管理员 PIN。
struct GuestModeView: View {
    let event: EventTemplate
    let cameraEngine: CameraEngine
    let storage: FileStorageService
    let onExit: () -> Void

    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(SystemStatusMonitor.self) private var monitor
    @Environment(RemoteControlHub.self) private var hub
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: GuestFlowViewModel?
    @State private var showPINPad = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                Color.black.ignoresSafeArea()
                    .task {
                        viewModel = GuestFlowViewModel(
                            event: event,
                            cameraEngine: cameraEngine,
                            storage: storage,
                            uploadQueue: uploadQueue
                        )
                    }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func content(_ viewModel: GuestFlowViewModel) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreviewView(engine: cameraEngine)
                .ignoresSafeArea()

            switch viewModel.phase {
            case .welcome:
                WelcomeOverlay(
                    event: event,
                    storage: storage,
                    blocked: monitor.blocksNewRecording,
                    warnings: monitor.warnings.filter(\.isCritical),
                    onStart: { viewModel.startTapped() }
                )
            case .countingDown(let remaining):
                CountdownOverlayView(secondsRemaining: remaining) {
                    viewModel.cancelCountdown()
                }
            case .recording(let remaining):
                recordingOverlay(remaining: remaining)
            case .processing:
                processingOverlay(viewModel)
            case .result:
                ResultOverlay(viewModel: viewModel)
            case .failed(let message):
                failedOverlay(message: message)
            }

            // 隐藏退出角（左上）：长按 2 秒唤出 PIN
            VStack {
                HStack {
                    Color.clear
                        .frame(width: 88, height: 88)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 2) {
                            showPINPad = true
                        }
                    Spacer()
                }
                Spacer()
            }
        }
        .task {
            viewModel.hub = hub
            viewModel.blockedProvider = { monitor.blocksNewRecording }
            viewModel.onAppear(modelContext: modelContext)
        }
        .onDisappear { viewModel.teardown() }
        // 局域网控制台的“开始拍摄”
        .onChange(of: hub.startRequestID) { _, _ in
            viewModel.startTapped()
        }
        .sheet(isPresented: $showPINPad) {
            PINPadView {
                showPINPad = false
                viewModel.teardown()
                onExit()
            }
        }
    }

    // MARK: - 录制中

    private func recordingOverlay(remaining: Int) -> some View {
        VStack {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 12, height: 12)
                Text("录制中 · 剩余 \(remaining)s")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.top, 24)
            Spacer()
        }
    }

    // MARK: - 处理中

    private func processingOverlay(_ viewModel: GuestFlowViewModel) -> some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 22) {
                ProgressView(value: viewModel.processingEngine.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                    .tint(.white)
                Text("正在制作你的 360 视频…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(Int(viewModel.processingEngine.progress * 100))%")
                    .font(.largeTitle.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - 失败

    private func failedOverlay(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 52))
                    .foregroundStyle(.yellow)
                Text("出了点问题，请找工作人员")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Text("即将自动返回…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - 欢迎页

private struct WelcomeOverlay: View {
    let event: EventTemplate
    let storage: FileStorageService
    let blocked: Bool
    let warnings: [SystemStatusMonitor.Warning]
    let onStart: () -> Void

    var body: some View {
        ZStack {
            if let background = EventManager(storage: storage)
                .loadImage(event: event, fileName: event.backgroundFileName) {
                Image(uiImage: background)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear, .black.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 20) {
                Spacer()
                if let logo = EventManager(storage: storage)
                    .loadImage(event: event, fileName: event.logoFileName) {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 120)
                }
                Text(event.welcomeTitle)
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 8)
                Text(event.welcomeSubtitle)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Spacer()

                if blocked {
                    Text("存储空间不足，暂停拍摄，请联系工作人员")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    Button(action: onStart) {
                        Text("开 始")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 240, height: 76)
                            .background(
                                Capsule().fill(Color.accentColor)
                                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                            )
                    }
                }

                if event.motionTriggerEnabled {
                    Label("转台启动后将自动开拍", systemImage: "rotate.3d")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }

                ForEach(warnings) { warning in
                    Text(warning.text)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                let studioName = AccountStore.load().studioName
                if !studioName.isEmpty {
                    Text(studioName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer().frame(height: 46)
            }
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - 结果页

private struct ResultOverlay: View {
    @Bindable var viewModel: GuestFlowViewModel
    @Environment(UploadQueue.self) private var uploadQueue

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("你的 360 视频")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.top, 20)

                VideoPlayer(player: viewModel.resultPlayer)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                uploadStatusRow

                HStack(spacing: 16) {
                    Button {
                        viewModel.retakeTapped()
                    } label: {
                        Label("重拍", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .frame(width: 130, height: 50)
                            .background(.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Button {
                        viewModel.doneTapped()
                    } label: {
                        Label("完成", systemImage: "checkmark")
                            .font(.headline)
                            .frame(width: 130, height: 50)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }

                Text("\(viewModel.autoReturnRemaining)s 后自动返回")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
        }
    }

    /// 上传状态 + 二维码（上传完成即出现，扫码带走视频）。
    @ViewBuilder
    private var uploadStatusRow: some View {
        if let render = viewModel.currentRender {
            switch render.uploadState {
            case .done:
                if let urlString = render.remoteURLString,
                   let qr = QRCodeGenerator.image(for: urlString, sidePixels: 300) {
                    HStack(spacing: 12) {
                        Image(uiImage: qr)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 108, height: 108)
                            .padding(6)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        Text("扫码下载视频")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
            case .queued, .uploading:
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    if let progress = uploadQueue.progressByID[render.id] {
                        Text("视频上传中 \(Int(progress * 100))%，稍后可扫码下载…")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        Text("视频上传中，稍后可扫码下载…")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            case .failed:
                Text("上传暂时失败，会自动重试；也可稍后在 Gallery 获取二维码")
                    .font(.footnote)
                    .foregroundStyle(.yellow)
            case .none:
                EmptyView()
            }
        }
    }
}

// MARK: - 管理员 PIN

struct PINPadView: View {
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isWrong = false

    static var storedPIN: String {
        UserDefaults.standard.string(forKey: "booth360.adminPIN") ?? "1234"
    }

    var body: some View {
        VStack(spacing: 28) {
            Text("输入管理员 PIN")
                .font(.headline)
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .strokeBorder(isWrong ? Color.red : Color.secondary, lineWidth: 1.5)
                        .background(
                            Circle().fill(index < input.count ? Color.primary : Color.clear)
                        )
                        .frame(width: 18, height: 18)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 18), count: 3),
                      spacing: 16) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9"], id: \.self) { digit in
                    digitButton(digit)
                }
                Color.clear.frame(width: 76, height: 76)
                digitButton("0")
                Button {
                    if !input.isEmpty { input.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .frame(width: 76, height: 76)
                }
            }
            Button("取消") { dismiss() }
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 32)
        .presentationDetents([.medium, .large])
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            guard input.count < 4 else { return }
            isWrong = false
            input.append(digit)
            if input.count == 4 {
                if input == Self.storedPIN {
                    onSuccess()
                } else {
                    isWrong = true
                    input = ""
                }
            }
        } label: {
            Text(digit)
                .font(.title.weight(.medium))
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color(.systemGray5)))
        }
        .buttonStyle(.plain)
    }
}
