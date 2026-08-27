import SwiftUI
import SwiftData

/// 根视图：管理员端（拍摄 + 活动 + Gallery + 设置）+ 嘉宾模式全屏覆盖 + 局域网控制接线。
struct RootView: View {
    let viewModel: CaptureViewModel
    let storage: FileStorageService
    let uploadQueue: UploadQueue
    let systemMonitor: SystemStatusMonitor
    let remoteHub: RemoteControlHub
    let lanServer: LANControlServer

    @Environment(\.modelContext) private var modelContext
    @State private var guestEvent: EventTemplate?

    var body: some View {
        NavigationStack {
            CaptureView(viewModel: viewModel) { event in
                guestEvent = event
            }
        }
        .fullScreenCover(item: $guestEvent) { event in
            GuestModeView(
                event: event,
                cameraEngine: viewModel.engine,
                storage: storage
            ) {
                guestEvent = nil
                // 退出嘉宾模式后恢复管理员端相机配置
                Task { await viewModel.configureCamera() }
            }
        }
        .environment(uploadQueue)
        .environment(systemMonitor)
        .environment(remoteHub)
        .environment(lanServer)
        .preferredColorScheme(.dark)
        // 拍摄现场减少 Home 指示条干扰
        .persistentSystemOverlays(.hidden)
        .task {
            systemMonitor.start()
            uploadQueue.resumePendingOnLaunch()
            wireLANServer()
            // 兜底：为“文件在、记录丢”的孤儿视频补建数据库记录
            await LibraryReconciler.reconcile(storage: storage, context: modelContext)
        }
    }

    // MARK: - 局域网控制接线

    private func wireLANServer() {
        lanServer.handlers = LANControlServer.Handlers(
            status: {
                let pending = (try? modelContext.fetchCount(FetchDescriptor<RenderedVideo>(
                    predicate: #Predicate {
                        $0.uploadStateRawValue == "queued" || $0.uploadStateRawValue == "uploading"
                    }))) ?? 0
                let failed = (try? modelContext.fetchCount(FetchDescriptor<RenderedVideo>(
                    predicate: #Predicate { $0.uploadStateRawValue == "failed" }))) ?? 0
                let activeName = EventManager.activeEvent(in: modelContext)?.name
                return [
                    "guestActive": remoteHub.guestActive,
                    "guestPhase": remoteHub.guestPhaseText,
                    "activeEvent": activeName ?? "",
                    "storageGB": String(format: "%.1f", Double(systemMonitor.availableBytes) / 1_000_000_000),
                    "battery": systemMonitor.batteryLevel < 0
                        ? "未知" : "\(Int(systemMonitor.batteryLevel * 100))%",
                    "uploadsPending": pending,
                    "uploadsFailed": failed,
                ]
            },
            events: {
                let events = (try? modelContext.fetch(FetchDescriptor<EventTemplate>(
                    sortBy: [SortDescriptor(\EventTemplate.updatedAt, order: .reverse)]))) ?? []
                let activeID = EventManager.activeEventID
                return events.map { event in
                    [
                        "id": event.id.uuidString,
                        "name": event.name,
                        "active": event.id == activeID,
                    ]
                }
            },
            activateEvent: { id in
                var descriptor = FetchDescriptor<EventTemplate>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                guard (try? modelContext.fetch(descriptor).first) != nil else { return false }
                EventManager.activeEventID = id
                return true
            },
            openGuest: {
                guard guestEvent == nil else { return true }
                guard let active = EventManager.activeEvent(in: modelContext)
                    ?? (try? modelContext.fetch(FetchDescriptor<EventTemplate>()))?.first else {
                    return false
                }
                EventManager.activeEventID = active.id
                guestEvent = active
                return true
            },
            startCapture: {
                guard remoteHub.guestActive else { return false }
                remoteHub.requestStart()
                return true
            }
        )
    }
}
