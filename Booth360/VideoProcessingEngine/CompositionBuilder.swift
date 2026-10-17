import Foundation
import AVFoundation
import CoreGraphics
import QuartzCore

/// 合成输入。
struct CompositionInputs {
    let originalAsset: AVAsset
    /// 倒放中间素材（style 含倒放时必须提供）。
    let reversedAsset: AVAsset?
    /// 片头/片尾（原样拼接，保留其自带声音）。
    let introAsset: AVAsset?
    let outroAsset: AVAsset?
    /// 动态 Overlay：带透明通道的视频（HEVC with alpha .mov），铺满上层、循环到全长。
    let overlayVideoAsset: AVAsset?
    let segments: [TimelineSegment]
    let includeOriginalAudio: Bool
    let musicAsset: AVAsset?
    let musicVolume: Float
    let renderSize: CGSize
    let outputFrameRate: Int32
}

/// 合成结果：可直接用于 AVPlayerItem 预览（overlayImage 为 nil 时）或导出。
struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let totalDuration: CMTime
}

/// 把 时间轴片段 + 片头片尾 + 动态 Overlay + 音轨 落成 AVFoundation 合成对象。
///
/// 注意：静态图 Overlay（animationTool）只能用于导出；
/// 动态视频 Overlay 走第二视频轨，预览与导出都生效。
enum CompositionBuilder {

    private struct VideoSource {
        let track: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let timeRange: CMTimeRange
        var duration: CMTime { timeRange.duration }
        let audioTrack: AVAssetTrack?
    }

    private static func loadSource(_ asset: AVAsset) async throws -> VideoSource? {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let timeRange = try await videoTrack.load(.timeRange)
        guard timeRange.isValid, timeRange.start.isNumeric,
              timeRange.duration.seconds.isFinite, timeRange.duration > .zero else { return nil }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        return VideoSource(
            track: videoTrack, naturalSize: naturalSize,
            preferredTransform: transform, timeRange: timeRange, audioTrack: audio)
    }

    /// sourceRange 是视频实际取用的范围；音频只取交集，并保留缺音部分的时间位置。
    private static func insertAudio(
        from source: AVAssetTrack,
        range sourceRange: CMTimeRange,
        into destination: AVMutableCompositionTrack,
        at targetStart: CMTime,
        targetDuration: CMTime
    ) async throws {
        let audioRange = try await source.load(.timeRange)
        let overlap = CMTimeRangeGetIntersection(sourceRange, audioRange)
        guard overlap.isValid, overlap.duration > .zero else { return }
        let ratio = targetDuration.seconds / sourceRange.duration.seconds
        func mapped(_ time: CMTime) -> CMTime {
            abs(ratio - 1) < 0.000000001 ? time : CMTime(seconds: time.seconds * ratio, preferredTimescale: 600)
        }
        let offset = mapped(overlap.start - sourceRange.start)
        let mappedEnd = min(targetDuration, mapped(CMTimeRangeGetEnd(overlap) - sourceRange.start))
        let duration = mappedEnd - offset
        guard duration > .zero else { return }
        let at = targetStart + offset
        try destination.insertTimeRange(overlap, of: source, at: at)
        if CMTimeCompare(duration, overlap.duration) != 0 {
            destination.scaleTimeRange(CMTimeRange(start: at, duration: overlap.duration), toDuration: duration)
        }
    }

    static func build(_ inputs: CompositionInputs, overlayImage: CGImage?) async throws -> BuiltComposition {
        guard let main = try await loadSource(inputs.originalAsset) else {
            throw ProcessingError.noVideoTrack
        }
        var reversed: VideoSource?
        if let reversedAsset = inputs.reversedAsset {
            reversed = try await loadSource(reversedAsset)
        }
        var intro: VideoSource?
        if let introAsset = inputs.introAsset { intro = try await loadSource(introAsset) }
        var outro: VideoSource?
        if let outroAsset = inputs.outroAsset { outro = try await loadSource(outroAsset) }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessingError.compositionFailed("无法创建视频轨")
        }

        /// 主视频轨的分段变换关键帧（intro/主体/outro 几何可能不同）。
        var transformKeyframes: [(time: CMTime, transform: CGAffineTransform)] = []
        /// intro/outro 自带声音的插入计划。
        var extrasAudioPlan: [(source: AVAssetTrack, range: CMTimeRange, at: CMTime)] = []
        var cursor = CMTime.zero

        // MARK: 片头

        if let intro {
            let range = intro.timeRange
            do {
                try videoTrack.insertTimeRange(range, of: intro.track, at: cursor)
                transformKeyframes.append((cursor, CropGeometry.exportTransform(
                    naturalSize: intro.naturalSize,
                    preferredTransform: intro.preferredTransform,
                    renderSize: inputs.renderSize)))
                if let audio = intro.audioTrack {
                    extrasAudioPlan.append((audio, range, cursor))
                }
                cursor = cursor + intro.duration
            } catch {
                AppLogger.processing.error("片头插入失败（跳过）: \(error.localizedDescription, privacy: .public)")
            }
        }

        // MARK: 主体时间轴（逐段插入，插完立刻变速，游标前移）

        transformKeyframes.append((cursor, CropGeometry.exportTransform(
            naturalSize: main.naturalSize,
            preferredTransform: main.preferredTransform,
            renderSize: inputs.renderSize)))

        var insertedSegments: [(source: TimelineSegment.SourceKind, range: CMTimeRange, at: CMTime, target: CMTime)] = []
        for segment in inputs.segments {
            let source: VideoSource
            switch segment.source {
            case .original:
                source = main
            case .reversed:
                guard let reversed else {
                    throw ProcessingError.compositionFailed("缺少倒放素材")
                }
                source = reversed
            }
            guard segment.sourceStartSeconds.isFinite, segment.sourceDurationSeconds.isFinite,
                  segment.targetDurationSeconds.isFinite, segment.sourceDurationSeconds > 0,
                  segment.targetDurationSeconds > 0 else {
                throw ProcessingError.compositionFailed("视频阶段的时长或速度无效")
            }
            // TimelineSegment 使用相对视频有效区间的坐标，不以整个 asset（可能有更长音轨）为界。
            let start = max(0, segment.sourceStartSeconds)
            let end = min(source.duration.seconds, segment.sourceStartSeconds + segment.sourceDurationSeconds)
            guard end > start else { continue }
            let timescale = max(600, max(source.timeRange.start.timescale, source.duration.timescale))
            let sourceStart = start == 0 ? source.timeRange.start
                : source.timeRange.start + CMTime(seconds: start, preferredTimescale: timescale)
            let sourceEnd = end >= source.duration.seconds ? CMTimeRangeGetEnd(source.timeRange)
                : source.timeRange.start + CMTime(seconds: end, preferredTimescale: timescale)
            let sourceRange = CMTimeRangeGetIntersection(
                CMTimeRange(start: sourceStart, end: sourceEnd), source.timeRange)
            guard sourceRange.isValid, sourceRange.duration > .zero else { continue }
            let multiplier = segment.targetDurationSeconds / segment.sourceDurationSeconds
            let target = abs(multiplier - 1) < 0.000000001 ? sourceRange.duration
                : CMTime(seconds: sourceRange.duration.seconds * multiplier, preferredTimescale: 600)
            guard target.isNumeric, target > .zero else {
                throw ProcessingError.compositionFailed("视频阶段太短，无法导出")
            }
            do {
                try videoTrack.insertTimeRange(sourceRange, of: source.track, at: cursor)
            } catch {
                throw ProcessingError.compositionFailed(error.localizedDescription)
            }
            if CMTimeCompare(target, sourceRange.duration) != 0 {
                videoTrack.scaleTimeRange(
                    CMTimeRange(start: cursor, duration: sourceRange.duration),
                    toDuration: target
                )
            }
            insertedSegments.append((segment.source, sourceRange, cursor, target))
            cursor = cursor + target
        }
        guard !insertedSegments.isEmpty else {
            throw ProcessingError.compositionFailed("时间轴为空")
        }

        // MARK: 片尾

        if let outro {
            let range = outro.timeRange
            do {
                try videoTrack.insertTimeRange(range, of: outro.track, at: cursor)
                transformKeyframes.append((cursor, CropGeometry.exportTransform(
                    naturalSize: outro.naturalSize,
                    preferredTransform: outro.preferredTransform,
                    renderSize: inputs.renderSize)))
                if let audio = outro.audioTrack {
                    extrasAudioPlan.append((audio, range, cursor))
                }
                cursor = cursor + outro.duration
            } catch {
                AppLogger.processing.error("片尾插入失败（跳过）: \(error.localizedDescription, privacy: .public)")
            }
        }

        let totalDuration = cursor

        // MARK: 原声（仅主体的原片片段；倒放片段留静音）

        if inputs.includeOriginalAudio,
           let originalAudioTrack = main.audioTrack,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            for entry in insertedSegments where entry.source == .original {
                do {
                    try await insertAudio(from: originalAudioTrack, range: entry.range,
                                          into: audioTrack, at: entry.at, targetDuration: entry.target)
                } catch {
                    AppLogger.processing.error("原声插入失败（继续，无原声）: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // MARK: 片头/片尾自带声音

        if !extrasAudioPlan.isEmpty,
           let extrasTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            for plan in extrasAudioPlan {
                do {
                    try await insertAudio(from: plan.source, range: plan.range,
                                          into: extrasTrack, at: plan.at, targetDuration: plan.range.duration)
                } catch {
                    AppLogger.processing.error("片头/片尾声音插入失败（跳过）: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // MARK: 背景音乐（全长循环铺满，结尾淡出）

        var audioMix: AVAudioMix?
        if let musicAsset = inputs.musicAsset,
           let musicSourceTrack = try await musicAsset.loadTracks(withMediaType: .audio).first,
           let musicTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicRange = try await musicSourceTrack.load(.timeRange)
            let musicDuration = musicRange.duration
            guard musicRange.isValid, musicRange.start.isNumeric, musicDuration.seconds.isFinite,
                  musicDuration > .zero else { throw ProcessingError.compositionFailed("音乐素材没有有效音频") }
            var fillCursor = CMTime.zero
            while fillCursor < totalDuration {
                let remaining = totalDuration - fillCursor
                let chunk = min(musicDuration, remaining)
                guard chunk.seconds > 0.05 else { break }
                do {
                    try musicTrack.insertTimeRange(
                        CMTimeRange(start: musicRange.start, duration: chunk),
                        of: musicSourceTrack,
                        at: fillCursor
                    )
                } catch {
                    throw ProcessingError.compositionFailed("音乐轨插入失败：\(error.localizedDescription)")
                }
                fillCursor = fillCursor + chunk
            }

            let parameters = AVMutableAudioMixInputParameters(track: musicTrack)
            parameters.setVolume(inputs.musicVolume, at: .zero)
            let fadeSeconds = min(1.5, totalDuration.seconds / 4)
            if fadeSeconds > 0.2 {
                let fade = CMTime(seconds: fadeSeconds, preferredTimescale: 600)
                parameters.setVolumeRamp(
                    fromStartVolume: inputs.musicVolume,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: totalDuration - fade, duration: fade)
                )
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            audioMix = mix
        }

        // MARK: 动态视频 Overlay（第二视频轨，循环铺满全长）

        var overlayLayerInstruction: AVMutableVideoCompositionLayerInstruction?
        if let overlayVideoAsset = inputs.overlayVideoAsset,
           let overlaySource = try await loadSource(overlayVideoAsset),
           let overlayTrack = composition.addMutableTrack(
               withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            var fillCursor = CMTime.zero
            while fillCursor < totalDuration {
                let remaining = totalDuration - fillCursor
                let chunk = min(overlaySource.duration, remaining)
                guard chunk.seconds > 0.05 else { break }
                do {
                    try overlayTrack.insertTimeRange(
                        CMTimeRange(start: overlaySource.timeRange.start, duration: chunk),
                        of: overlaySource.track,
                        at: fillCursor
                    )
                } catch {
                    AppLogger.processing.error("动态 Overlay 插入失败（忽略该层）: \(error.localizedDescription, privacy: .public)")
                    break
                }
                fillCursor = fillCursor + chunk
            }
            let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: overlayTrack)
            instruction.setTransform(CropGeometry.exportTransform(
                naturalSize: overlaySource.naturalSize,
                preferredTransform: overlaySource.preferredTransform,
                renderSize: inputs.renderSize), at: .zero)
            overlayLayerInstruction = instruction
        }

        // MARK: 画幅裁切 + 帧率

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = inputs.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: inputs.outputFrameRate)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)
        let mainLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        for keyframe in transformKeyframes {
            mainLayerInstruction.setTransform(keyframe.transform, at: keyframe.time)
        }
        // Overlay 轨在前 = 显示在上层
        instruction.layerInstructions = [overlayLayerInstruction, mainLayerInstruction].compactMap { $0 }
        videoComposition.instructions = [instruction]

        // MARK: 静态图 Overlay（仅导出路径）

        if let overlayImage {
            let videoLayer = CALayer()
            videoLayer.frame = CGRect(origin: .zero, size: inputs.renderSize)
            let overlayLayer = CALayer()
            overlayLayer.contents = overlayImage
            overlayLayer.frame = videoLayer.frame
            overlayLayer.contentsGravity = .resizeAspectFill
            overlayLayer.masksToBounds = true
            let parentLayer = CALayer()
            parentLayer.frame = videoLayer.frame
            // 导出坐标系与 CA 默认坐标系上下颠倒，不翻转的话 overlay 是倒的
            parentLayer.isGeometryFlipped = true
            parentLayer.addSublayer(videoLayer)
            parentLayer.addSublayer(overlayLayer)
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            totalDuration: totalDuration
        )
    }
}
