import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// 色彩滤镜预设（ChackTok 式「滤镜」）。
enum FilterPreset: String, CaseIterable, Identifiable, Codable {
    case none
    case vivid
    case warm
    case cool
    case blackWhite
    case vintage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "原图"
        case .vivid: return "鲜艳"
        case .warm: return "暖调"
        case .cool: return "冷调"
        case .blackWhite: return "黑白"
        case .vintage: return "复古"
        }
    }
}

/// 视频后处理（美颜 + 滤镜）：对已导出的成品整段再跑一遍 Core Image。
/// 美颜 = 降噪磨皮 + 轻柔光 + 提亮红润（无需人脸识别的均匀软美颜，booth 常用做法）。
enum VideoPostFX {

    static let context = CIContext()

    /// 是否需要跑后处理。
    static func isNeeded(beautyEnabled: Bool, filter: FilterPreset) -> Bool {
        beautyEnabled || filter != .none
    }

    /// 对整个视频文件应用美颜/滤镜，写到 outputURL（音轨原样保留）。
    static func apply(
        inputURL: URL,
        outputURL: URL,
        beautyStrength: Double,
        filter: FilterPreset,
        codec: OutputCodec,
        progressHandler: @escaping (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        let strength = beautyStrength
        let videoComposition = try await AVMutableVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                let output = process(request.sourceImage, beautyStrength: strength, filter: filter)
                request.finish(with: output, context: context)
            }
        )

        try? FileManager.default.removeItem(at: outputURL)
        let preset = codec == .hevc
            ? AVAssetExportPresetHEVCHighestQuality
            : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ProcessingError.exportFailed("无法创建美颜导出会话")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        let pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                progressHandler(Double(session.progress))
                if isCancelled() { session.cancelExport() }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        pollTask.cancel()

        switch session.status {
        case .completed:
            return
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            throw ProcessingError.cancelled
        default:
            try? FileManager.default.removeItem(at: outputURL)
            throw ProcessingError.exportFailed(session.error?.localizedDescription ?? "美颜处理失败")
        }
    }

    // MARK: - 单帧处理链（纯函数，单测覆盖 extent 不变）

    static func process(_ source: CIImage, beautyStrength: Double, filter: FilterPreset) -> CIImage {
        var image = source
        let strength = CGFloat(max(0, min(1, beautyStrength)))

        if strength > 0.01 {
            // 1. 降噪磨皮（抹平皮肤细纹理）
            let noise = CIFilter.noiseReduction()
            noise.inputImage = image
            noise.noiseLevel = Float(0.012 * strength)
            noise.sharpness = 0.40
            image = noise.outputImage ?? image

            // 2. 轻高斯柔光叠加（软焦「奶油肌」）
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(6 * strength)
            if let blurred = blur.outputImage?.cropped(to: source.extent) {
                let alpha = CIFilter.colorMatrix()
                alpha.inputImage = blurred
                alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.35 * strength)
                if let softened = alpha.outputImage {
                    let composite = CIFilter.sourceOverCompositing()
                    composite.inputImage = softened
                    composite.backgroundImage = image
                    image = composite.outputImage ?? image
                }
            }

            // 3. 提亮 + 红润
            let tone = CIFilter.colorControls()
            tone.inputImage = image
            tone.brightness = Float(0.025 * strength)
            tone.saturation = Float(1 + 0.05 * strength)
            tone.contrast = 1.0
            image = tone.outputImage ?? image

            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = image
            vibrance.amount = Float(0.15 * strength)
            image = vibrance.outputImage ?? image
        }

        image = applyPreset(filter, to: image)
        return image.cropped(to: source.extent)
    }

    private static func applyPreset(_ preset: FilterPreset, to input: CIImage) -> CIImage {
        switch preset {
        case .none:
            return input
        case .vivid:
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = input
            vibrance.amount = 0.45
            let saturate = CIFilter.colorControls()
            saturate.inputImage = vibrance.outputImage ?? input
            saturate.saturation = 1.12
            saturate.brightness = 0
            saturate.contrast = 1.02
            return saturate.outputImage ?? input
        case .warm:
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = input
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5300, y: 6)
            return temperature.outputImage ?? input
        case .cool:
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = input
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 7800, y: -4)
            return temperature.outputImage ?? input
        case .blackWhite:
            let noir = CIFilter.photoEffectNoir()
            noir.inputImage = input
            return noir.outputImage ?? input
        case .vintage:
            let transfer = CIFilter.photoEffectTransfer()
            transfer.inputImage = input
            return transfer.outputImage ?? input
        }
    }
}
