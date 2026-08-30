import SwiftUI
import SwiftData

/// 活动列表：新建/复制/删除/设为当前/进入编辑/启动嘉宾模式。
struct EventListView: View {
    let storage: FileStorageService
    let cameraEngine: CameraEngine
    /// 启动嘉宾模式（由 RootView 呈现 fullScreenCover）。
    let onLaunchGuestMode: (EventTemplate) -> Void

    @Query(sort: \EventTemplate.updatedAt, order: .reverse) private var events: [EventTemplate]
    @Environment(\.modelContext) private var modelContext
    @Environment(UploadQueue.self) private var uploadQueue
    @State private var activeEventID: UUID? = EventManager.activeEventID
    /// 编辑页改为程序化跳转，避免 NavigationLink 内嵌 ▶ 按钮导致
    /// push 与 fullScreenCover 同时触发把界面卡死（黑屏）。
    @State private var editingEvent: EventTemplate?
    /// 列表编辑模式（显式删除入口；左滑删除仍然可用）。
    @State private var editMode: EditMode = .inactive
    /// 待确认删除的活动（删除会连同成品与云端文件，必须确认）。
    @State private var pendingDeleteEvent: EventTemplate?

    private var manager: EventManager { EventManager(storage: storage) }

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView {
                    Label("还没有活动", systemImage: "party.popper")
                } description: {
                    Text("活动保存品牌素材、拍摄与效果参数，\n嘉宾模式按活动配置运行。")
                } actions: {
                    Button("新建活动") { createEvent() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(events) { event in
                        eventRow(event)
                    }
                    .onDelete { indexSet in
                        if let index = indexSet.first { pendingDeleteEvent = events[index] }
                    }
                }
                .environment(\.editMode, $editMode)
            }
        }
        .navigationTitle("活动")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !events.isEmpty {
                    Button(editMode == .active ? "完成" : "编辑") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                }
                Button {
                    createEvent()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(item: $editingEvent) { event in
            EventEditView(event: event, storage: storage)
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { pendingDeleteEvent != nil },
                set: { if !$0 { pendingDeleteEvent = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除活动及全部成品", role: .destructive) {
                if let event = pendingDeleteEvent { performFullDelete(event) }
                pendingDeleteEvent = nil
            }
            Button("取消", role: .cancel) { pendingDeleteEvent = nil }
        }
    }

    private var deleteDialogTitle: String {
        guard let event = pendingDeleteEvent else { return "" }
        let count = renderCount(of: event)
        return count > 0
            ? "删除「\(event.name)」？将同时删除它的 \(count) 条成品（手机 + 云端），二维码与总览链接全部失效，不占腾讯云空间。"
            : "删除「\(event.name)」？（该活动没有成品）"
    }

    private func renderCount(of event: EventTemplate) -> Int {
        let id = event.id
        let descriptor = FetchDescriptor<RenderedVideo>(predicate: #Predicate { $0.eventID == id })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// 整场删除：云端视频/落地页/二维码 + 云端大屏/总览页 + 本地文件与记录 + 活动本体。
    private func performFullDelete(_ event: EventTemplate) {
        let eventID = event.id
        let descriptor = FetchDescriptor<RenderedVideo>(predicate: #Predicate { $0.eventID == eventID })
        let renders = (try? modelContext.fetch(descriptor)) ?? []
        for render in renders {
            uploadQueue.cleanupRemoteObjects(
                id: render.id, fileName: render.fileName,
                wasUploaded: render.uploadState == .done)
            storage.deleteFileIfExists(at: storage.renderURL(fileName: render.fileName))
            modelContext.delete(render)
        }
        uploadQueue.cleanupEventWall(eventID: eventID)
        manager.delete(event, in: modelContext)
        activeEventID = EventManager.activeEventID
        uploadQueue.republishWall()
    }

    private func eventRow(_ event: EventTemplate) -> some View {
        HStack(spacing: 12) {
            // 左侧：点文字区进编辑
            Button {
                editingEvent = event
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.name)
                            .font(.headline)
                        if activeEventID == event.id {
                            Text("当前")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text("\(event.recordingSeconds)s · \(event.effectSettings.summaryText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 嘉宾模式入口已按用户要求收起（主页即完整流程）；
            // 如需恢复客人自助 Kiosk 模式，把 ▶ 按钮加回这里即可。
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeleteEvent = event
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                manager.duplicate(event, in: modelContext)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                activate(event)
            } label: {
                Label("设为当前", systemImage: "checkmark.circle")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                activate(event)
            } label: {
                Label("设为当前", systemImage: "checkmark.circle")
            }
            Button {
                manager.duplicate(event, in: modelContext)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                pendingDeleteEvent = event
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 设为当前活动，并让云端大屏立即切到该活动的节目单。
    private func activate(_ event: EventTemplate) {
        EventManager.activeEventID = event.id
        activeEventID = event.id
        uploadQueue.republishWall()
    }

    private func createEvent() {
        let event = manager.createEvent(named: "活动 \(events.count + 1)", in: modelContext)
        activeEventID = EventManager.activeEventID
        _ = event
    }
}
