import XCTest
import AVFoundation
import CoreVideo
import CoreGraphics
@testable import Booth360

/// 不依赖相机、相册或云端；在 iOS Simulator 上生成彩色帧并执行真实 AVFoundation 导出。
@MainActor
final class ShotModeExportTests: XCTestCase {
    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testAllFourModesExportConfiguredTimelineAndVisibleFirstLastFrames() async throws {
        let directory = try workspace()
        let source = directory.appendingPathComponent("source.mp4")
        try await TestVideoFixture.writeVideo(to: source, frames: 30)
        let asset = AVURLAsset(url: source)
        let sourceTracks = try await asset.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceRange = try await sourceTrack.load(.timeRange)

        for kind in ShotModeKind.activeKinds {
            var mode = ShotMode(kind: kind, enabled: true, recordingSeconds: 10)
            // 模拟拖动阶段时长和速度；实际只录到 1 秒，不能照搬设定的 10 秒。
            mode.setPhaseDuration(1, at: 0)
            mode.setPhaseRate(0.75, at: mode.phaseRates.count - 1)
            let expected = TimelineBuilder.totalDuration(of: TimelineBuilder.build(
                mode: mode, clipDurationSeconds: sourceRange.duration.seconds, loopCount: 1))
            var settings = exportSettings(mode: mode)
            settings.shotKindRaw = ShotModeKind.rushback.rawValue
            settings.style = .reverse // 完整新模式快照必须优先，不能进入历史倒放路径。
            let output = directory.appendingPathComponent("\(kind.rawValue).mp4")
            let engine = VideoProcessingEngine()
            let result = try await engine.export(.init(sourceURL: source, settings: settings, outputURL: output))
            XCTAssertFalse(engine.isBusy)
            XCTAssertEqual(result.durationSeconds, expected, accuracy: 0.02, kind.rawValue)
            try await assertExport(output, expectedSeconds: expected)
        }
    }

    func testRateExtremesAndShortRecordingExportFromActualSourceDuration() async throws {
        let directory = try workspace()
        let source = directory.appendingPathComponent("short.mp4")
        try await TestVideoFixture.writeVideo(to: source, frames: 18)
        let mode = ShotMode(kind: .doubleSlow, enabled: true, recordingSeconds: 20,
                            durationWeights: [1, 2, 1, 3, 1], rates: [4, 0.25, 4, 0.25, 4])
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(tracks.first)
        let sourceRange = try await sourceTrack.load(.timeRange)
        let segments = TimelineBuilder.build(mode: mode, clipDurationSeconds: sourceRange.duration.seconds, loopCount: 1)
        let expected = TimelineBuilder.totalDuration(of: segments)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.sourceDurationSeconds }, sourceRange.duration.seconds, accuracy: 0.0001)
        let output = directory.appendingPathComponent("extremes.mp4")
        let engine = VideoProcessingEngine()
        let result = try await engine.export(.init(sourceURL: source, settings: exportSettings(mode: mode), outputURL: output))
        XCTAssertEqual(result.durationSeconds, expected, accuracy: 0.02)
        try await assertExport(output, expectedSeconds: expected)
    }

    func testSourceTailClampingPreservesRateInsteadOfStretchingMissingFrames() async throws {
        let directory = try workspace()
        let source = directory.appendingPathComponent("tail.mp4")
        try await TestVideoFixture.writeVideo(to: source, frames: 30)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let original = try XCTUnwrap(tracks.first)
        let available = try await original.load(.timeRange)
        let segment = TimelineSegment(source: .original, sourceStartSeconds: 0.75,
                                      sourceDurationSeconds: 0.5, targetDurationSeconds: 1)
        let built = try await CompositionBuilder.build(inputs(asset, segments: [segment]), overlayImage: nil)
        let expected = (available.duration.seconds - 0.75) * 2
        XCTAssertEqual(built.totalDuration.seconds, expected, accuracy: 0.002)
        let outputTracks = try await built.composition.loadTracks(withMediaType: .video)
        let compositionTrack = try XCTUnwrap(outputTracks.first as? AVCompositionTrack)
        let inserted = try XCTUnwrap(compositionTrack.segments.first { !$0.isEmpty })
        XCTAssertEqual(inserted.timeMapping.source.start.seconds, available.start.seconds + 0.75, accuracy: 0.002)
        XCTAssertLessThanOrEqual(CMTimeRangeGetEnd(inserted.timeMapping.source).seconds, CMTimeRangeGetEnd(available).seconds + 0.002)
        let output = directory.appendingPathComponent("tail-export.mp4")
        try await TestVideoFixture.export(built, to: output)
        try await assertExport(output, expectedSeconds: expected, checkForwardColor: false)
    }

    func testTrackStartOffsetIsAppliedWhenSelectingRelativeSegments() async throws {
        let directory = try workspace()
        let source = directory.appendingPathComponent("offset.mp4")
        // 首帧 PTS 有偏移；不同系统可能通过 edit list 规范化，始终以 SDK 返回的有效范围为准。
        try await TestVideoFixture.writeVideo(to: source, frames: 24, firstPTS: CMTime(value: 15, timescale: 30))
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        let segment = TimelineSegment(source: .original, sourceStartSeconds: 0.1,
                                      sourceDurationSeconds: 0.3, targetDurationSeconds: 0.3)
        let built = try await CompositionBuilder.build(inputs(asset, segments: [segment]), overlayImage: nil)
        let outputTracks = try await built.composition.loadTracks(withMediaType: .video)
        let compositionTrack = try XCTUnwrap(outputTracks.first as? AVCompositionTrack)
        let inserted = try XCTUnwrap(compositionTrack.segments.first { !$0.isEmpty })
        XCTAssertEqual(inserted.timeMapping.source.start.seconds, range.start.seconds + 0.1, accuracy: 0.002)
        XCTAssertEqual(built.totalDuration.seconds, 0.3, accuracy: 0.002)
    }

    func testShortOriginalAudioUsesIntersectionWithoutDroppingTheWholeTrack() async throws {
        let directory = try workspace()
        let video = directory.appendingPathComponent("video.mp4")
        let audio = directory.appendingPathComponent("audio.caf")
        let combined = directory.appendingPathComponent("video-with-short-audio.mov")
        var step = "生成视频样片"
        do {
            try await TestVideoFixture.writeVideo(to: video, frames: 30)
            step = "生成短 PCM 音轨"
            try TestVideoFixture.writeAudio(to: audio, seconds: 0.3)
            // 保持叶子 asset 存活到文件落盘，避免测试依赖临时对象/嵌套内存 composition。
            let videoAsset = AVURLAsset(url: video)
            let audioAsset = AVURLAsset(url: audio)
            step = "读取样片轨道"
            let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            let originalVideo = try XCTUnwrap(videoTracks.first)
            let originalAudio = try XCTUnwrap(audioTracks.first)
            let videoRange = try await originalVideo.load(.timeRange)
            let audioRange = try await originalAudio.load(.timeRange)
            let source = AVMutableComposition()
            let videoTrack = try XCTUnwrap(source.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            let audioTrack = try XCTUnwrap(source.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            step = "插入原视频"
            try videoTrack.insertTimeRange(videoRange, of: originalVideo, at: .zero)
            step = "插入短音轨"
            try audioTrack.insertTimeRange(audioRange, of: originalAudio, at: .zero)
            step = "Passthrough 写入真实 MOV 源片"
            try await TestVideoFixture.materialize(source, to: combined)
            withExtendedLifetime((videoAsset, audioAsset)) {}

            step = "读取真实 MOV 轨道范围"
            let realSource = AVURLAsset(url: combined)
            let realVideoTracks = try await realSource.loadTracks(withMediaType: .video)
            let realAudioTracks = try await realSource.loadTracks(withMediaType: .audio)
            let realVideo = try XCTUnwrap(realVideoTracks.first)
            let realAudio = try XCTUnwrap(realAudioTracks.first)
            let realVideoRange = try await realVideo.load(.timeRange)
            let realAudioRange = try await realAudio.load(.timeRange)
            XCTAssertGreaterThan(realAudioRange.duration.seconds, 0, "样片必须包含真实音频")
            XCTAssertEqual(realAudioRange.duration.seconds, audioRange.duration.seconds, accuracy: 0.01)
            XCTAssertLessThan(realAudioRange.duration.seconds, realVideoRange.duration.seconds - 0.2,
                              "不能把短音轨补齐到整段视频来绕过交集验证")
            let segment = TimelineSegment(source: .original, sourceStartSeconds: 0,
                                          sourceDurationSeconds: realVideoRange.duration.seconds,
                                          targetDurationSeconds: realVideoRange.duration.seconds)
            step = "CompositionBuilder 处理真实 MOV 和短原声"
            let built = try await CompositionBuilder.build(inputs(realSource, segments: [segment], originalAudio: true), overlayImage: nil)
            step = "读取并核对合成后的原声音轨"
            let resultAudio = try await built.composition.loadTracks(withMediaType: .audio)
            let resultTrack = try XCTUnwrap(resultAudio.first)
            let resultRange = try await resultTrack.load(.timeRange)
            XCTAssertEqual(resultRange.duration.seconds, realAudioRange.duration.seconds, accuracy: 0.01)
            XCTAssertEqual(built.totalDuration.seconds, realVideoRange.duration.seconds, accuracy: 0.002)
        } catch {
            let nsError = error as NSError
            let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
                .map { "；底层 \($0.domain) (\($0.code)): \($0.localizedDescription)" } ?? ""
            throw TestVideoFixture.fixtureError("短原声测试阶段「\(step)」：\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)\(underlying)")
        }
    }

    func testPreparationIsExclusiveAndCancellationReleasesEngine() async throws {
        let directory = try workspace()
        let source = directory.appendingPathComponent("exclusive.mp4")
        try await TestVideoFixture.writeVideo(to: source, frames: 30)
        let engine = VideoProcessingEngine()
        let request = VideoProcessingEngine.RenderRequest(
            sourceURL: source, settings: exportSettings(mode: .init(kind: .slowFastSlow, enabled: true)),
            outputURL: directory.appendingPathComponent("cancelled.mp4"))
        let first = Task { try await engine.export(request) }
        for _ in 0..<200 {
            if engine.isBusy { break }
            await Task.yield()
        }
        XCTAssertTrue(engine.isBusy)
        do {
            _ = try await engine.makePreviewItem(request)
            XCTFail("并发预览应在准备阶段就被拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已有任务"))
        }
        first.cancel()
        engine.cancel()
        do {
            _ = try await first.value
            XCTFail("取消后的导出不能返回成功")
        } catch {
            XCTAssertFalse(engine.isBusy)
            XCTAssertEqual(engine.stage, .idle)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputURL.path))
        _ = try await engine.makePreviewItem(request)
        XCTAssertFalse(engine.isBusy)
    }

    private func exportSettings(mode: ShotMode) -> EffectSettings {
        var settings = EffectSettings()
        settings.shotMode = mode
        settings.resolution = .r720
        settings.codec = .h264
        settings.overlayEnabled = false
        settings.overlayVideoEnabled = false
        settings.musicEnabled = false
        settings.beautyEnabled = false
        settings.filterPreset = .none
        settings.introEnabled = false
        settings.outroEnabled = false
        return settings
    }

    private func inputs(_ asset: AVAsset, segments: [TimelineSegment], originalAudio: Bool = false) -> CompositionInputs {
        CompositionInputs(originalAsset: asset, reversedAsset: nil, introAsset: nil, outroAsset: nil,
                          overlayVideoAsset: nil, segments: segments, includeOriginalAudio: originalAudio,
                          musicAsset: nil, musicVolume: 0.8, renderSize: CGSize(width: 720, height: 1280), outputFrameRate: 30)
    }

    private func assertExport(_ url: URL, expectedSeconds: Double, checkForwardColor: Bool = true) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        XCTAssertGreaterThan(range.duration.seconds, 0)
        XCTAssertEqual(range.duration.seconds, expectedSeconds, accuracy: 2.0 / 30 + 0.01)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let first = try generator.copyCGImage(at: range.start, actualTime: nil)
        let last = try generator.copyCGImage(at: CMTimeRangeGetEnd(range) - CMTime(value: 1, timescale: 30), actualTime: nil)
        let firstColor = try TestVideoFixture.color(of: first)
        let lastColor = try TestVideoFixture.color(of: last)
        XCTAssertGreaterThan(firstColor.reduce(0, +), 40, "首帧不能是空白黑屏")
        XCTAssertGreaterThan(lastColor.reduce(0, +), 40, "末帧不能是空白黑屏")
        if checkForwardColor { XCTAssertGreaterThan(lastColor[0], firstColor[0] + 30, "新模式应正向覆盖源片首尾") }
    }
}

private enum TestVideoFixture {
    static func writeVideo(to url: URL, frames: Int, firstPTS: CMTime = .zero) async throws {
        let width = 160
        let height = 96
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 300_000, AVVideoMaxKeyFrameIntervalKey: 6]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw fixtureError("无法创建测试视频输入") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? fixtureError("测试视频写入启动失败") }
        writer.startSession(atSourceTime: .zero)
        do {
            for index in 0..<frames {
                let deadline = Date().addingTimeInterval(10)
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error ?? fixtureError("测试视频编码失败") }
                    guard Date() < deadline else { throw fixtureError("测试视频编码超时") }
                    try await Task.sleep(for: .milliseconds(1))
                }
                var buffer: CVPixelBuffer?
                let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                guard status == kCVReturnSuccess, let buffer else { throw fixtureError("无法分配测试画面") }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    let red = UInt8(40 + 160 * index / max(1, frames - 1))
                    for y in 0..<height {
                        for x in 0..<width {
                            let offset = y * stride + x * 4
                            bytes[offset] = 180
                            bytes[offset + 1] = 80
                            bytes[offset + 2] = red
                            bytes[offset + 3] = 255
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let time = firstPTS + CMTime(value: Int64(index), timescale: 30)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? fixtureError("无法追加测试帧")
                }
            }
            writer.endSession(atSourceTime: firstPTS + CMTime(value: Int64(frames), timescale: 30))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? fixtureError("测试视频未完成") }
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    static func writeAudio(to url: URL, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let count = AVAudioFrameCount((seconds * 44_100).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(count) { channels[0][frame] = sin(Float(frame) * 0.04) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func export(_ built: BuiltComposition, to url: URL) async throws {
        let session = try XCTUnwrap(AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality))
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else { throw session.error ?? fixtureError("测试导出未完成") }
    }

    /// 用物理容器保存 H.264 + 短 PCM 轨，后续输入与相机的 AVURLAsset 一致。
    static func materialize(_ asset: AVAsset, to url: URL) async throws {
        let compatible = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .mov)
        guard compatible else { throw fixtureError("H.264 + 短 PCM 样片不支持 Passthrough MOV") }
        let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough))
        guard session.supportedFileTypes.contains(.mov) else { throw fixtureError("测试导出器不支持 MOV 容器") }
        session.outputURL = url
        session.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else { throw session.error ?? fixtureError("真实短音轨 MOV 源片未写入完成") }
    }

    static func color(of image: CGImage) throws -> [Int] {
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { pointer in
            let context = try XCTUnwrap(CGContext(data: pointer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba.prefix(3).map(Int.init)
    }

    static func fixtureError(_ message: String) -> Error {
        NSError(domain: "ShotModeExportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
