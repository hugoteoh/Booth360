import Foundation

/// 拍摄模式（多段变速曲线库，对标市面 360 软件的"拍摄选项"）。
/// 曲线用「片段操作」描述：正放/倒放 × 源片区间 × 速率，TimelineBuilder 据此展开。
enum ShotModeKind: String, CaseIterable, Identifiable, Codable {
    case normal          // 原速
    case boomerang       // 回旋视频
    case slowMotion      // 慢动作
    case slowGlide       // 缓慢滑行 常-慢-常
    case rapidFade       // 极速淡化 常-快-慢
    case fastFlow        // 快速流动 快-慢-常
    case rushback        // 急速回冲 常-快-回旋-慢-快
    case reverseSprint   // 逆向冲刺 快-回旋-慢-快
    case elasticLoop     // 弹性循环 变速回旋

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "标准"
        case .boomerang: return "回旋视频"
        case .slowMotion: return "慢动作"
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
        case .normal: return "常速"
        case .boomerang: return "正放 + 倒放"
        case .slowMotion: return "全程慢动作"
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
        case .normal: return "video"
        case .boomerang: return "arrow.triangle.2.circlepath"
        case .slowMotion: return "tortoise"
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
        case .boomerang, .rushback, .reverseSprint, .elasticLoop: return true
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
        case .normal:
            return [Op(0, 1, rate: 1)]
        case .slowMotion:
            return [Op(0, 1, rate: 0.5)]
        case .boomerang:
            return [Op(0, 1, rate: 1), Op(0, 1, rate: 1, reversed: true)]
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
}

/// 活动里可配置的一个拍摄模式条目（启用与否 + 该模式的录制时长）。
struct ShotMode: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kindRaw: String
    var enabled: Bool
    var recordingSeconds: Int

    var kind: ShotModeKind { ShotModeKind(rawValue: kindRaw) ?? .normal }

    init(kind: ShotModeKind, enabled: Bool, recordingSeconds: Int? = nil) {
        self.kindRaw = kind.rawValue
        self.enabled = enabled
        self.recordingSeconds = recordingSeconds ?? kind.defaultSeconds
    }

    /// 默认模式库（新活动的初始配置，勾选四个常用的）。
    static var defaultLibrary: [ShotMode] {
        ShotModeKind.allCases.map { kind in
            let enabledByDefault: Set<ShotModeKind> = [.boomerang, .slowGlide, .fastFlow, .rushback]
            return ShotMode(kind: kind, enabled: enabledByDefault.contains(kind))
        }
    }
}
