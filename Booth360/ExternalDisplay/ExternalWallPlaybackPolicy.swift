import Foundation

/// 外屏播放的资源策略；仅决定暂停与换源，不操作相机、播放器或导出器。
struct ExternalWallPlaybackPolicy {
    enum ThermalLevel: CaseIterable, Equatable {
        case nominal
        case fair
        case serious
        case critical
    }

    /// 录制/处理优先：高温直接暂停，温度略高且拍摄忙时暂停。
    /// 正常温度下，忙碌期间可继续已加载的单路成品。
    static func shouldHoldPlayback(isCaptureBusy: Bool, thermal: ThermalLevel) -> Bool {
        switch thermal {
        case .nominal:
            return false
        case .fair:
            return isCaptureBusy
        case .serious, .critical:
            return true
        }
    }

    /// 忙碌或高温期间不加载新视频；二维码/活动文字可由展示层独立刷新。
    static func mayReplaceItem(isCaptureBusy: Bool, thermal: ThermalLevel) -> Bool {
        guard !isCaptureBusy else { return false }
        switch thermal {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        }
    }

    /// orderedIDs 按最新在前排列。播放到尾部后回到最新一条；
    /// 当前条目已删除或尚未开始播放时，从列表首项开始。
    static func selectNextID(currentID: UUID?, orderedIDs: [UUID]) -> UUID? {
        guard let first = orderedIDs.first else { return nil }
        guard let currentID, let index = orderedIDs.firstIndex(of: currentID) else { return first }
        let nextIndex = orderedIDs.index(after: index)
        return nextIndex < orderedIDs.endIndex ? orderedIDs[nextIndex] : first
    }
}

/// 外屏的成品快照。二维码晚于视频上传完成后更新，身份与视频 URL 保持独立。
struct ExternalWallItem: Equatable, Identifiable {
    let id: UUID
    var eventName: String
    var createdAt: Date
    var videoURL: URL
    var qrPayload: String?
}
