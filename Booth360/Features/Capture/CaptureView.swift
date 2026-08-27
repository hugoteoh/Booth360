import SwiftUI

/// 拍摄主界面：全屏预览 + 顶部状态/镜头/帧率 + 底部拍摄控制。
struct CaptureView: View {
    @Bindable var viewModel: CaptureViewModel
    /// 从活动列表启动嘉宾模式（由 RootView 呈现 fullScreenCover）。
    let onLaunchGuestMode: (EventTemplate) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(SystemStatusMonitor.self) private var monitor
    @State private var showManualPanel = false

    private var engine: CameraEngine { viewModel.engine }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch engine.status {
            case .failed(let error):
                cameraUnavailableView(message: error.errorDescription ?? "相机不可用")
            case .idle, .configuring:
                ProgressView("正在启动相机…")
                    .tint(.white)
                    .foregroundStyle(.white)
            default:
                CameraPreviewView(engine: engine)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                warningsBanner
                Spacer()
                bottomControls
            }

            if case .countingDown(let remaining) = viewModel.phase {
                CountdownOverlayView(secondsRemaining: remaining) {
                    viewModel.cancelOrStopTapped()
                }
            }

            if case .interrupted(let reason) = engine.status {
                interruptedBanner(reason: reason)
            }
        }
        .statusBarHidden()
        .task {
            viewModel.modelContext = modelContext
            if engine.status == .idle {
                await viewModel.configureCamera()
            }
        }
        .sheet(isPresented: $showManualPanel) {
            ManualControlsPanel(viewModel: viewModel)
        }
        .alert("出错了", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 10) {
            NavigationLink {
                GalleryView(storage: viewModel.storage)
            } label: {
                Image(systemName: "photo.stack")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }

            NavigationLink {
                EventListView(
                    storage: viewModel.storage,
                    cameraEngine: engine,
                    onLaunchGuestMode: onLaunchGuestMode
                )
            } label: {
                Image(systemName: "party.popper")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }

            Spacer()

            VStack(spacing: 2) {
                Text(engine.activeFormatSummary.isEmpty ? "—" : engine.activeFormatSummary)
                    .font(.caption.weight(.semibold))
                if engine.didFallBackFrameRate {
                    Text("帧率已降级（镜头不支持所选帧率）")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if !engine.audioEnabled {
                    Text("无麦克风（静音录制）")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())

            Spacer()

            NavigationLink {
                AdminSettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }

            lensAndRateMenu
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 系统警告条（存储/电量/过热）。
    @ViewBuilder
    private var warningsBanner: some View {
        let warnings = monitor.warnings
        if !warnings.isEmpty {
            VStack(spacing: 4) {
                ForEach(warnings) { warning in
                    Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(warning.isCritical ? .white : .black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(warning.isCritical ? Color.red : Color.yellow, in: Capsule())
                }
            }
            .padding(.top, 6)
        }
    }

    private var lensAndRateMenu: some View {
        Menu {
            Section("镜头") {
                ForEach(CameraLens.allCases) { lens in
                    Button {
                        viewModel.changeLens(lens)
                    } label: {
                        if engine.currentConfiguration.lens == lens {
                            Label(lens.displayName, systemImage: "checkmark")
                        } else {
                            Text(lens.displayName)
                        }
                    }
                }
            }
            Section("分辨率") {
                ForEach(CaptureResolution.allCases) { resolution in
                    Button {
                        viewModel.changeResolution(resolution)
                    } label: {
                        if engine.currentConfiguration.resolution == resolution {
                            Label(resolution.displayName, systemImage: "checkmark")
                        } else {
                            Text(resolution.displayName)
                        }
                    }
                }
            }
            Section("帧率（设备不支持时自动降级）") {
                ForEach(CaptureFrameRate.allCases) { rate in
                    Button {
                        viewModel.changeFrameRate(rate)
                    } label: {
                        if engine.currentConfiguration.frameRate == rate {
                            Label(rate.displayName, systemImage: "checkmark")
                        } else {
                            Text(rate.displayName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "camera.aperture")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
        }
        .disabled(viewModel.isBusy)
    }

    // MARK: - 底部控制

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if let saved = viewModel.lastSavedClip {
                Text("已保存 · \(saved.summaryText)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.75), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.phase == .idle {
                settingsRow
            }

            recordButton
        }
        .padding(.bottom, 28)
        .animation(.easeInOut(duration: 0.25), value: viewModel.lastSavedClip != nil)
    }

    private var settingsRow: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(RecordingSettings.countdownChoices, id: \.self) { seconds in
                    Button(seconds == 0 ? "不倒数" : "\(seconds) 秒") {
                        viewModel.settings.countdownSeconds = seconds
                    }
                }
            } label: {
                pillLabel(
                    icon: "timer",
                    text: viewModel.settings.countdownSeconds == 0
                        ? "不倒数" : "倒数 \(viewModel.settings.countdownSeconds)s"
                )
            }

            Menu {
                ForEach(RecordingSettings.durationChoices, id: \.self) { seconds in
                    Button("\(seconds) 秒") {
                        viewModel.settings.recordingSeconds = seconds
                    }
                }
            } label: {
                pillLabel(icon: "video.badge.checkmark", text: "录 \(viewModel.settings.recordingSeconds)s")
            }

            Button {
                showManualPanel = true
            } label: {
                pillLabel(icon: "slider.horizontal.3", text: "手动")
            }
        }
        .foregroundStyle(.white)
    }

    private func pillLabel(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private var recordButton: some View {
        Button {
            if viewModel.phase == .recording {
                viewModel.cancelOrStopTapped()
            } else {
                viewModel.startTapped()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 5)
                    .frame(width: 84, height: 84)

                if viewModel.phase == .recording {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.red)
                        .frame(width: 38, height: 38)
                    Text("\(viewModel.recordingElapsedSeconds)s / \(viewModel.settings.recordingSeconds)s")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .offset(y: 64)
                } else {
                    Circle()
                        .fill(viewModel.phase == .idle && engine.status == .running ? .red : .gray)
                        .frame(width: 68, height: 68)
                }

                if viewModel.phase == .saving {
                    ProgressView().tint(.white)
                }
            }
        }
        .disabled(viewModel.phase == .saving
                  || !engine.status.isRunningOrRecording
                  || (viewModel.phase == .idle && monitor.blocksNewRecording))
        .animation(.easeInOut(duration: 0.2), value: viewModel.phase)
    }

    // MARK: - 异常态

    private func cameraUnavailableView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("相机不可用")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                Task { await viewModel.configureCamera() }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private func interruptedBanner(reason: String) -> some View {
        VStack {
            Label("相机已暂停：\(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.yellow, in: Capsule())
                .padding(.top, 60)
            Spacer()
        }
    }
}
