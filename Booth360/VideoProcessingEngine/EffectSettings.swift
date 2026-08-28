import Foundation
import CoreGraphics

/// 变速效果。
enum SpeedEffect: String, CaseIterable, Identifiable, Codable {
    case normal
    case slowMotion
    case fastMotion
    case slowFastSlow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "原速"
        case .slowMotion: return "慢动作"
        case .fastMotion: return "快动作"
        case .slowFastSlow: return "慢-快-慢"
        }
    }
}

/// 播放方式。
enum PlaybackStyle: String, CaseIterable, Identifiable, Codable {
    case forward
    case reverse
    case boomerang

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forward: return "正放"
        case .reverse: return "倒放"
        case .boomerang: return "Boomerang"
        }
    }
}

/// 输出画幅。
enum OutputAspect: String, CaseIterable, Identifiable, Codable {
    case portrait916
    case landscape169
    case square11
    case portrait45

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .portrait916: return "9:16"
        case .landscape169: return "16:9"
        case .square11: return "1:1"
        case .portrait45: return "4:5"
        }
    }

    /// 宽/高比。
    var ratio: (width: Double, height: Double) {
        switch self {
        case .portrait916: return (9, 16)
        case .landscape169: return (16, 9)
        case .square11: return (1, 1)
        case .portrait45: return (4, 5)
        }
    }
}

/// 输出分辨率（短边像素）。
enum OutputResolution: String, CaseIterable, Identifiable, Codable {
    case r720
    case r1080
    case r4K

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .r720: return "720p"
        case .r1080: return "1080p"
        case .r4K: return "4K"
        }
    }

    var shortSidePixels: Double {
        switch self {
        case .r720: return 720
        case .r1080: return 1080
        case .r4K: return 2160
        }
    }
}

/// 输出编码。
enum OutputCodec: String, CaseIterable, Identifiable, Codable {
    case hevc
    case h264

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hevc: return "HEVC（体积小）"
        case .h264: return "H.264（兼容好）"
        }
    }
}

/// 一次处理/导出的全部参数。Codable 用于活动模板持久化。
struct EffectSettings: Equatable, Codable {
    var speed: SpeedEffect = .slowFastSlow
    var style: PlaybackStyle = .forward
    /// 成品循环次数 1…3。
    var loopCount: Int = 1

    /// 静态 PNG Overlay（导出时经 CoreAnimationTool 合成）。
    var overlayEnabled: Bool = false
    /// 动态视频 Overlay（带透明通道的 HEVC .mov，预览与导出都生效）。
    var overlayVideoEnabled: Bool = false
    var musicEnabled: Bool = false
    /// 音乐音量 0…1。
    var musicVolume: Double = 0.8
    var originalAudioEnabled: Bool = false

    /// 活动配了 Intro/Outro 素材时是否拼接。
    var introEnabled: Bool = true
    var outroEnabled: Bool = true

    /// 美颜（磨皮柔光提亮，导出后处理；预览不含）。
    var beautyEnabled: Bool = false
    /// 美颜强度 0…1。
    var beautyStrength: Double = 0.6
    /// 色彩滤镜预设。
    var filterPreset: FilterPreset = .none

    var aspect: OutputAspect = .portrait916
    var resolution: OutputResolution = .r1080
    var codec: OutputCodec = .hevc

    /// 拍摄模式曲线（非空时优先于 speed/style 生效）。
    var shotKindRaw: String?

    var shotKind: ShotModeKind? {
        shotKindRaw.flatMap { ShotModeKind(rawValue: $0) }
    }

    init() {}

    /// 自定义解码：全部 decodeIfPresent + 默认值。
    /// 保证旧版本存的 JSON（缺新字段）以及未来再加字段都能正常读出，不会整体回落默认。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speed = try container.decodeIfPresent(SpeedEffect.self, forKey: .speed) ?? .slowFastSlow
        style = try container.decodeIfPresent(PlaybackStyle.self, forKey: .style) ?? .forward
        loopCount = try container.decodeIfPresent(Int.self, forKey: .loopCount) ?? 1
        overlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? false
        overlayVideoEnabled = try container.decodeIfPresent(Bool.self, forKey: .overlayVideoEnabled) ?? false
        musicEnabled = try container.decodeIfPresent(Bool.self, forKey: .musicEnabled) ?? false
        musicVolume = try container.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.8
        originalAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .originalAudioEnabled) ?? false
        introEnabled = try container.decodeIfPresent(Bool.self, forKey: .introEnabled) ?? true
        outroEnabled = try container.decodeIfPresent(Bool.self, forKey: .outroEnabled) ?? true
        beautyEnabled = try container.decodeIfPresent(Bool.self, forKey: .beautyEnabled) ?? false
        beautyStrength = try container.decodeIfPresent(Double.self, forKey: .beautyStrength) ?? 0.6
        filterPreset = try container.decodeIfPresent(FilterPreset.self, forKey: .filterPreset) ?? .none
        aspect = try container.decodeIfPresent(OutputAspect.self, forKey: .aspect) ?? .portrait916
        resolution = try container.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? .r1080
        codec = try container.decodeIfPresent(OutputCodec.self, forKey: .codec) ?? .hevc
        shotKindRaw = try container.decodeIfPresent(String.self, forKey: .shotKindRaw)
    }

    /// 原声只在“原速 + 正放”时可用（变速/倒放会导致声音变调或倒转，一律丢弃）。
    var canUseOriginalAudio: Bool { speed == .normal && style == .forward }

    /// 倒放和 Boomerang（或含倒放段的拍摄模式曲线）需要先生成倒序中间文件。
    var needsReversedAsset: Bool {
        if let shotKind { return shotKind.usesReverse }
        return style != .forward
    }

    /// 输出渲染尺寸（宽高都取偶数，编码器要求）。
    static func renderSize(aspect: OutputAspect, resolution: OutputResolution) -> CGSize {
        let ratio = aspect.ratio
        let shortSide = resolution.shortSidePixels
        let width: Double
        let height: Double
        if ratio.width <= ratio.height {
            width = shortSide
            height = shortSide * ratio.height / ratio.width
        } else {
            height = shortSide
            width = shortSide * ratio.width / ratio.height
        }
        func even(_ value: Double) -> CGFloat {
            CGFloat(Int(value.rounded() / 2) * 2)
        }
        return CGSize(width: even(width), height: even(height))
    }

    var renderSize: CGSize {
        Self.renderSize(aspect: aspect, resolution: resolution)
    }

    /// 存入 RenderedVideo 的可读描述，如 "慢-快-慢 · Boomerang · ×2 · 美颜 · 9:16 1080p HEVC"。
    var summaryText: String {
        var parts: [String]
        if let shotKind {
            parts = [shotKind.displayName]
        } else {
            parts = [speed.displayName, style.displayName]
        }
        if loopCount > 1 { parts.append("×\(loopCount)") }
        if beautyEnabled { parts.append("美颜") }
        if filterPreset != .none { parts.append(filterPreset.displayName) }
        parts.append("\(aspect.displayName) \(resolution.displayName) \(codec == .hevc ? "HEVC" : "H.264")")
        return parts.joined(separator: " · ")
    }
}
