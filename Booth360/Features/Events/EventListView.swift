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
    @State private var activeEventID: UUID? = EventManager.activeEventID

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
                }
            }
        }
        .navigationTitle("活动")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createEvent()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func eventRow(_ event: EventTemplate) -> some View {
        NavigationLink {
            EventEditView(event: event, storage: storage)
        } label: {
            HStack(spacing: 12) {
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
                Spacer()
                Button {
                    EventManager.activeEventID = event.id
                    activeEventID = event.id
                    onLaunchGuestMode(event)
                } label: {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("启动嘉宾模式")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                manager.delete(event, in: modelContext)
                activeEventID = EventManager.activeEventID
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                manager.duplicate(event, in: modelContext)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                EventManager.activeEventID = event.id
                activeEventID = event.id
            } label: {
                Label("设为当前", systemImage: "checkmark.circle")
            }
            .tint(.blue)
        }
    }

    private func createEvent() {
        let event = manager.createEvent(named: "活动 \(events.count + 1)", in: modelContext)
        activeEventID = EventManager.activeEventID
        _ = event
    }
}
