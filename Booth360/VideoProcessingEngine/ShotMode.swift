import Foundation

/// 拍摄模式（多段变速曲线库，对标市面 360 软件的"拍摄选项"）。
/// 曲线用「片段操作」描述：正放/倒放 × 源片区间 × 速率，TimelineBuilder 据此展开。
enum ShotModeKind: String, CaseIterable, Identifiable, Codable {
    case slowFastSlow    // 慢-快-慢（经典 360 节奏）
    case fastSlowFast    // 快-慢-快
    case gradualSpeedUp  // 逐段加速
    case doubleSlow      // 双重慢镜
    // 旧 raw value 与曲线保留，供历史成品设置解码及旧时间轴 API 使用。
    case slowGlide       // 缓慢滑行 常-慢-常
    case rapidFade       // 极速淡化 常-快-慢
    case fastFlow        // 快速流动 快-慢-常
    case rushback        // 急速回冲 常-快-回旋-慢-快
    case reverseSprint   // 逆向冲刺 快-回旋-慢-快
    case elasticLoop     // 弹性循环 变速回旋

    static let activeKinds: [ShotModeKind] = [.slowFastSlow, .fastSlowFast, .gradualSpeedUp, .doubleSlow]
    static var allCases: [ShotModeKind] { activeKinds }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slowFastSlow: return "慢-快-慢"
        case .fastSlowFast: return "快-慢-快"
        case .gradualSpeedUp: return "逐段加速"
        case .doubleSlow: return "双重慢镜"
        case .slowGlide: return "缓慢滑行"
        case .rapidFade: return "极速淡化"
        case .fastFlow: return "快速流动"
        case .rushback: return "急速回冲"
        case .reverseSprint: return "逆向冲刺"
        case .elasticLoop: return "弹性循环"
        }
    }

    var curveDescription: String {
        switch self {
        case .slowFastSlow: return "慢 - 快 - 慢"
        case .fastSlowFast: return "快 - 慢 - 快"
        case .gradualSpeedUp: return "慢 - 常速 - 快"
        case .doubleSlow: return "快 - 慢 - 快 - 慢 - 快"
        case .slowGlide: return "常 - 慢 - 常"
        case .rapidFade: return "常 - 快 - 慢"
        case .fastFlow: return "快 - 慢 - 常"
        case .rushback: return "常 - 快 - 回旋 - 慢 - 快"
        case .reverseSprint: return "快 - 回旋 - 慢 - 快"
        case .elasticLoop: return "变速回旋"
        }
    }

    var sfSymbol: String {
        switch self {
        case .slowFastSlow: return "waveform.path.ecg"
        case .fastSlowFast: return "hare"
        case .gradualSpeedUp: return "speedometer"
        case .doubleSlow: return "waveform.path"
        case .slowGlide: return "water.waves"
        case .rapidFade: return "wind"
        case .fastFlow: return "hare"
        case .rushback: return "arrow.uturn.backward.circle"
        case .reverseSprint: return "backward.circle"
        case .elasticLoop: return "infinity"
        }
    }

    /// 曲线中含倒放片段（需要先生成倒放素材）。
    var usesReverse: Bool {
        switch self {
        case .rushback, .reverseSprint, .elasticLoop: return true
        default: return false
        }
    }

    /// 片段操作：源片区间 [fromFraction, toFraction]（正放坐标）× 速率；reversed = 该段倒着放。
    struct Op {
        let fromFraction: Double
        let toFraction: Double
        let rate: Double
        let reversed: Bool

        init(_ fromFraction: Double, _ toFraction: Double, rate: Double, reversed: Bool = false) {
            self.fromFraction = fromFraction
            self.toFraction = toFraction
            self.rate = rate
            self.reversed = reversed
        }
    }

    /// 曲线定义（区间按源片比例）。
    var ops: [Op] {
        switch self {
        case .slowFastSlow:   // 慢-快-慢
            return [Op(0, 0.25, rate: 0.5), Op(0.25, 0.75, rate: 2), Op(0.75, 1, rate: 0.5)]
        case .fastSlowFast:
            return [Op(0, 0.25, rate: 2), Op(0.25, 0.75, rate: 0.5), Op(0.75, 1, rate: 2)]
        case .gradualSpeedUp:
            return [Op(0, 0.3, rate: 0.5), Op(0.3, 0.7, rate: 1), Op(0.7, 1, rate: 2)]
        case .doubleSlow:
            return [
                Op(0, 0.15, rate: 2), Op(0.15, 0.4, rate: 0.5),
                Op(0.4, 0.6, rate: 2), Op(0.6, 0.85, rate: 0.5), Op(0.85, 1, rate: 2),
            ]
        case .slowGlide:      // 常-慢-常
            return [Op(0, 1.0/3, rate: 1), Op(1.0/3, 2.0/3, rate: 0.5), Op(2.0/3, 1, rate: 1)]
        case .rapidFade:      // 常-快-慢
            return [Op(0, 1.0/3, rate: 1), Op(1.0/3, 2.0/3, rate: 2), Op(2.0/3, 1, rate: 0.5)]
        case .fastFlow:       // 快-慢-常
            return [Op(0, 1.0/3, rate: 2), Op(1.0/3, 2.0/3, rate: 0.5), Op(2.0/3, 1, rate: 1)]
        case .rushback:       // 常-快-回旋-慢-快
            return [
                Op(0, 0.25, rate: 1),
                Op(0.25, 0.5, rate: 2),
                Op(0.25, 0.5, rate: 2, reversed: true),
                Op(0.5, 0.75, rate: 0.5),
                Op(0.75, 1, rate: 2),
            ]
        case .reverseSprint:  // 快-回旋-慢-快
            return [
                Op(0, 1.0/3, rate: 2),
                Op(0, 1.0/3, rate: 2, reversed: true),
                Op(1.0/3, 2.0/3, rate: 0.5),
                Op(2.0/3, 1, rate: 2),
            ]
        case .elasticLoop:    // 变速回旋：慢-快-慢 正放 + 镜像倒放
            return [
                Op(0, 0.25, rate: 0.5), Op(0.25, 0.75, rate: 2), Op(0.75, 1, rate: 0.5),
                Op(0.75, 1, rate: 0.5, reversed: true), Op(0.25, 0.75, rate: 2, reversed: true),
                Op(0, 0.25, rate: 0.5, reversed: true),
            ]
        }
    }

    var defaultSeconds: Int { 10 }

    /// 模式录制时长的可选范围（秒）。
    static let secondsRange = 5...20
}

/// 活动模式的完整配置。durationWeights 描述源片份额，rates 描述各阶段播放倍率。
/// 两字段可缺省，因此旧活动 JSON 可继续解码；新模式的所有阶段都正放。
struct ShotMode: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kindRaw: String
    var enabled: Bool
    var recordingSeconds: Int {
        didSet { recordingSeconds = Self.clampedSeconds(recordingSeconds) }
    }
    var durationWeights: [Double]?
    var rates: [Double]?

    static let minimumPhaseDuration: Double = 0.25
    static let phaseRateRange: ClosedRange<Double> = 0.25...4

    var kind: ShotModeKind { ShotModeKind(rawValue: kindRaw) ?? .slowFastSlow }

    init(
        kind: ShotModeKind,
        enabled: Bool,
        recordingSeconds: Int? = nil,
        durationWeights: [Double]? = nil,
        rates: [Double]? = nil
    ) {
        self.kindRaw = kind.rawValue
        self.enabled = enabled
        self.recordingSeconds = Self.clampedSeconds(recordingSeconds ?? kind.defaultSeconds)
        self.durationWeights = Self.sanitizedWeights(durationWeights, defaults: kind.ops.map { $0.toFraction - $0.fromFraction })
        self.rates = Self.sanitizedRates(rates, defaults: kind.ops.map(\.rate))
    }

    private enum CodingKeys: String, CodingKey {
        case id, kindRaw, enabled, recordingSeconds, durationWeights, rates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kindRaw = (try? container.decodeIfPresent(String.self, forKey: .kindRaw)) ?? ShotModeKind.slowFastSlow.rawValue
        let decodedKind = ShotModeKind(rawValue: kindRaw) ?? .slowFastSlow
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? Self.defaultID(for: decodedKind)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        recordingSeconds = Self.clampedSeconds((try? container.decodeIfPresent(Int.self, forKey: .recordingSeconds)) ?? 10)
        durationWeights = Self.sanitizedWeights(
            try? container.decodeIfPresent([Double].self, forKey: .durationWeights),
            defaults: decodedKind.ops.map { $0.toFraction - $0.fromFraction })
        rates = Self.sanitizedRates(
            try? container.decodeIfPresent([Double].self, forKey: .rates),
            defaults: decodedKind.ops.map(\.rate))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kindRaw, forKey: .kindRaw)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(Self.clampedSeconds(recordingSeconds), forKey: .recordingSeconds)
        try container.encodeIfPresent(
            Self.sanitizedWeights(durationWeights, defaults: defaultWeights), forKey: .durationWeights)
        try container.encodeIfPresent(Self.sanitizedRates(rates, defaults: defaultRates), forKey: .rates)
    }

    /// 按源片秒数显示；修改录制总长时仍保留所设阶段份额。
    var phaseDurations: [Double] {
        let weights = Self.sanitizedWeights(durationWeights, defaults: defaultWeights) ?? defaultWeights
        return Self.distributedDurations(weights: weights, total: Double(recordingSeconds))
    }

    var phaseRates: [Double] {
        Self.sanitizedRates(rates, defaults: defaultRates) ?? defaultRates
    }

    var phaseTitles: [String] {
        switch kind {
        case .slowFastSlow: return ["开场慢镜", "中段加速", "收尾慢镜"]
        case .fastSlowFast: return ["开场加速", "中段慢镜", "收尾加速"]
        case .gradualSpeedUp: return ["慢镜起步", "常速过渡", "加速收尾"]
        case .doubleSlow: return ["开场加速", "第一次慢镜", "中段加速", "第二次慢镜", "收尾加速"]
        default: return kind.ops.indices.map { "第\($0 + 1)段" }
        }
    }

    var estimatedOutputSeconds: Double {
        zip(phaseDurations, phaseRates).reduce(0) { $0 + $1.0 / $1.1 }
    }

    /// 固定总录制时长，其余阶段按原份额重分；所有阶段至少 0.25 秒。
    mutating func setPhaseDuration(_ seconds: Double, at index: Int) {
        var durations = phaseDurations
        guard durations.indices.contains(index), seconds.isFinite else { return }
        let total = Double(recordingSeconds)
        let maximum = total - Double(durations.count - 1) * Self.minimumPhaseDuration
        let selected = min(max(seconds, Self.minimumPhaseDuration), maximum)
        let otherIndices = durations.indices.filter { $0 != index }
        let others = Self.distributedDurations(weights: otherIndices.map { durations[$0] }, total: total - selected)
        durations[index] = selected
        for (offset, otherIndex) in otherIndices.enumerated() { durations[otherIndex] = others[offset] }
        durationWeights = durations.map { $0 / total }
    }

    mutating func setPhaseRate(_ rate: Double, at index: Int) {
        var updated = phaseRates
        guard updated.indices.contains(index), rate.isFinite else { return }
        updated[index] = min(max(rate, Self.phaseRateRange.lowerBound), Self.phaseRateRange.upperBound)
        rates = updated
    }

    /// 恢复默认阶段份额/倍率，保留条目身份、启用状态和录制总长。
    mutating func resetTiming() {
        durationWeights = nil
        rates = nil
    }

    private var defaultWeights: [Double] { kind.ops.map { $0.toFraction - $0.fromFraction } }
    private var defaultRates: [Double] { kind.ops.map(\.rate) }

    private static func clampedSeconds(_ value: Int) -> Int {
        min(max(value, ShotModeKind.secondsRange.lowerBound), ShotModeKind.secondsRange.upperBound)
    }

    private static func sanitizedWeights(_ weights: [Double]?, defaults: [Double]) -> [Double]? {
        guard let weights, weights.count == defaults.count else { return nil }
        return zip(weights, defaults).map { value, fallback in value.isFinite && value > 0 ? value : fallback }
    }

    private static func sanitizedRates(_ rates: [Double]?, defaults: [Double]) -> [Double]? {
        guard let rates, rates.count == defaults.count else { return nil }
        return zip(rates, defaults).map { value, fallback in
            guard value.isFinite, value > 0 else { return fallback }
            return min(max(value, phaseRateRange.lowerBound), phaseRateRange.upperBound)
        }
    }

    /// 有下限的份额分配。先缩放权重避免大数求和溢出，再锁定触及下限的阶段。
    private static func distributedDurations(weights: [Double], total: Double) -> [Double] {
        guard !weights.isEmpty else { return [] }
        let largest = weights.max() ?? 1
        let scaled = weights.map { $0 / largest }
        var remaining = total
        var indices = Array(weights.indices)
        var durations = Array(repeating: 0.0, count: weights.count)
        while !indices.isEmpty {
            let sum = indices.reduce(0) { $0 + scaled[$1] }
            let belowMinimum = indices.filter {
                let share = sum > 0 ? remaining * scaled[$0] / sum : remaining / Double(indices.count)
                return share < minimumPhaseDuration
            }
            if belowMinimum.isEmpty {
                for index in indices {
                    durations[index] = sum > 0 ? remaining * scaled[index] / sum : remaining / Double(indices.count)
                }
                // 抵消浮点加法舍入；最后一个阶段吸收至多机器精度的差值。
                if let last = indices.last { durations[last] += total - durations.reduce(0, +) }
                break
            }
            for index in belowMinimum {
                durations[index] = minimumPhaseDuration
                remaining -= minimumPhaseDuration
            }
            indices.removeAll { belowMinimum.contains($0) }
        }
        return durations
    }

    /// 默认模式库（新活动的初始配置）。
    static var defaultLibrary: [ShotMode] {
        ShotModeKind.activeKinds.map { kind in
            var mode = ShotMode(kind: kind, enabled: true)
            mode.id = defaultID(for: kind)
            return mode
        }
    }

    /// 未保存活动的 getter 也必须有稳定身份，避免视图刷新重置当前选中项。
    private static func defaultID(for kind: ShotModeKind) -> UUID {
        let suffix: String
        switch kind {
        case .slowFastSlow: suffix = "000000000001"
        case .fastSlowFast, .slowGlide: suffix = "000000000002"
        case .gradualSpeedUp, .rapidFade, .fastFlow: suffix = "000000000003"
        case .doubleSlow, .rushback, .reverseSprint, .elasticLoop: suffix = "000000000004"
        }
        return UUID(uuidString: "73D917C1-4C29-4B36-A0C5-\(suffix)")!
    }

    /// 老数据迁移：丢弃已下架的模式、补齐新增的模式，顺序对齐当前库。
    static func migrated(from saved: [ShotMode]) -> [ShotMode] {
        let aliases: [ShotModeKind: Set<String>] = [
            .fastSlowFast: [ShotModeKind.slowGlide.rawValue],
            .gradualSpeedUp: [ShotModeKind.rapidFade.rawValue, ShotModeKind.fastFlow.rawValue],
            .doubleSlow: [ShotModeKind.rushback.rawValue, ShotModeKind.reverseSprint.rawValue, ShotModeKind.elasticLoop.rawValue],
        ]
        return defaultLibrary.map { entry in
            // 真正的新类型记录优先，尤其不能用旧启用项覆盖用户关闭的新类型。
            if let exact = saved.first(where: { $0.kindRaw == entry.kindRaw }) { return exact }
            let matching = saved.filter { aliases[entry.kind]?.contains($0.kindRaw) == true }
            guard var legacy = matching.first(where: \.enabled) ?? matching.first else { return entry }
            legacy.kindRaw = entry.kindRaw
            // 旧模式的阶段含义可能不同，不把旧份额/倍率套到新曲线上。
            legacy.resetTiming()
            return legacy
        }
    }
}
