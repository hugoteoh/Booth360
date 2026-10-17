import Foundation
import SwiftData

/// 一个活动（模板）：品牌素材 + 拍摄参数 + 效果参数 + 嘉宾模式文案。
/// 素材文件放在 Documents/Events/<id>/ 下，这里只存文件名。
@Model
final class EventTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    // 嘉宾模式文案
    var welcomeTitle: String
    var welcomeSubtitle: String
    /// 成品页无操作 N 秒后自动回首页。
    var autoReturnSeconds: Int

    // 素材（活动目录内文件名）
    var logoFileName: String?
    var backgroundFileName: String?
    var overlayFileName: String?
    var musicFileName: String?
    var musicDisplayName: String?
    /// 动态视频 Overlay（带透明通道的 HEVC .mov）。
    var overlayVideoFileName: String?
    /// 片头/片尾视频。
    var introFileName: String?
    var outroFileName: String?

    // 拍摄参数
    var lensRawValue: String
    var frameRateRawValue: Int
    var countdownSeconds: Int
    var recordingSeconds: Int
    /// 转台起转自动开拍（Motion Trigger）。
    var motionTriggerEnabled: Bool = false
    /// 拍摄时经蓝牙自动控制转台旋转（开始录制转、录完停）。
    var turntableSpinEnabled: Bool = false

    /// EffectSettings 的 JSON（结构见 VideoProcessingEngine/EffectSettings.swift）。
    var effectSettingsData: Data
    /// 拍摄模式列表 [ShotMode] 的 JSON（空 = 用默认库）。
    var shotModesData: Data = Data()

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        welcomeTitle: String = "360 视频体验",
        welcomeSubtitle: String = "点击开始，站上转台！",
        autoReturnSeconds: Int = 20,
        lensRawValue: String = CameraLens.wide.rawValue,
        frameRateRawValue: Int = CaptureFrameRate.fps60.rawValue,
        countdownSeconds: Int = 3,
        recordingSeconds: Int = 15,
        effectSettingsData: Data = (try? JSONEncoder().encode(EffectSettings())) ?? Data()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.welcomeTitle = welcomeTitle
        self.welcomeSubtitle = welcomeSubtitle
        self.autoReturnSeconds = autoReturnSeconds
        self.lensRawValue = lensRawValue
        self.frameRateRawValue = frameRateRawValue
        self.countdownSeconds = countdownSeconds
        self.recordingSeconds = recordingSeconds
        self.effectSettingsData = effectSettingsData
    }
}

extension EventTemplate {
    /// 解码失败回落到默认值，保证旧数据/坏数据不崩。
    var effectSettings: EffectSettings {
        get { (try? JSONDecoder().decode(EffectSettings.self, from: effectSettingsData)) ?? EffectSettings() }
        set {
            effectSettingsData = (try? JSONEncoder().encode(newValue)) ?? effectSettingsData
            updatedAt = Date()
        }
    }

    var cameraConfiguration: CameraConfiguration {
        CameraConfiguration(
            lens: CameraLens(rawValue: lensRawValue) ?? .wide,
            resolution: .hd1080,
            frameRate: CaptureFrameRate(rawValue: frameRateRawValue) ?? .fps60,
            recordsAudio: true
        )
    }

    var recordingSettings: RecordingSettings {
        RecordingSettings(countdownSeconds: countdownSeconds, recordingSeconds: recordingSeconds)
    }

    /// 拍摄模式列表（解码失败/未配置回落默认库；老数据自动迁移到当前模式清单）。
    var shotModes: [ShotMode] {
        get {
            guard !shotModesData.isEmpty,
                  let modes = try? JSONDecoder().decode([ShotMode].self, from: shotModesData),
                  !modes.isEmpty else {
                return ShotMode.defaultLibrary
            }
            return ShotMode.migrated(from: modes)
        }
        set {
            shotModesData = (try? JSONEncoder().encode(newValue)) ?? shotModesData
            updatedAt = Date()
        }
    }

    var enabledShotModes: [ShotMode] {
        let library = shotModes
        let enabled = library.filter(\.enabled)
        // 旧活动可能把所有模式关掉；仍提供一个可拍摄的安全默认值。
        if !enabled.isEmpty { return enabled }
        var fallback = library.first ?? ShotMode.defaultLibrary[0]
        fallback.enabled = true
        return [fallback]
    }

    /// 从当前库解析选择，避免活动调节后仍使用 effectSettings 中过时的快照。
    var preferredShotMode: ShotMode {
        let modes = enabledShotModes
        let settings = effectSettings
        if let snapshot = settings.shotMode,
           let current = modes.first(where: { $0.id == snapshot.id }) { return current }
        let kindRaw = settings.shotMode?.kindRaw ?? settings.shotKindRaw
        return modes.first(where: { $0.kindRaw == kindRaw }) ?? modes[0]
    }

    func selectShotMode(_ mode: ShotMode) {
        var settings = effectSettings
        settings.shotMode = mode
        settings.shotKindRaw = mode.kindRaw
        effectSettings = settings
    }

    /// 拍摄时传入锁定的配置，自动处理与嘉宾流程使用同一套参数。
    func resolvedEffectSettings(mode: ShotMode? = nil) -> EffectSettings {
        var settings = effectSettings
        let selected = mode ?? preferredShotMode
        settings.shotMode = selected
        settings.shotKindRaw = selected.kindRaw
        return settings
    }
}
