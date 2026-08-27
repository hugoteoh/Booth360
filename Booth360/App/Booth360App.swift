import SwiftUI
import SwiftData

@main
struct Booth360App: App {
    private let storage: FileStorageService
    private let container: ModelContainer
    @State private var captureViewModel: CaptureViewModel
    @State private var uploadQueue: UploadQueue
    @State private var systemMonitor: SystemStatusMonitor
    @State private var remoteHub = RemoteControlHub()
    @State private var lanServer = LANControlServer()
    @State private var turntable = TurntableService()

    init() {
        let storage = FileStorageService()
        do {
            try storage.ensureDirectoriesExist()
        } catch {
            AppLogger.storage.error("创建目录失败: \(error.localizedDescription, privacy: .public)")
        }
        self.storage = storage

        let schema = Schema([SourceClip.self, RenderedVideo.self, EventTemplate.self])
        do {
            container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)])
        } catch {
            // 数据库打不开属于不可恢复错误（磁盘损坏/降级安装），带信息崩溃便于定位
            fatalError("SwiftData 初始化失败: \(error)")
        }

        _captureViewModel = State(initialValue: CaptureViewModel(
            engine: CameraEngine(),
            storage: storage
        ))
        _uploadQueue = State(initialValue: UploadQueue(
            modelContext: container.mainContext,
            storage: storage
        ))
        _systemMonitor = State(initialValue: SystemStatusMonitor(storage: storage))
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                viewModel: captureViewModel,
                storage: storage,
                uploadQueue: uploadQueue,
                systemMonitor: systemMonitor,
                remoteHub: remoteHub,
                lanServer: lanServer,
                turntable: turntable
            )
        }
        .modelContainer(container)
    }
}
