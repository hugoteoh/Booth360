import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// 生成倒放中间文件（仅视频轨，方向元数据与源一致）。
///
/// 做法：先收集全部帧的显示时间戳（passthrough 不解码，很快）；
/// 然后按窗口（约 0.5 秒一批）从片尾往片头解码，每批帧倒序写入编码器，
/// 输出时间戳复用原始递增序列。这样峰值内存只有一个窗口的解码帧
/// （1080p 约 90 MB），15 秒 60fps 的片子在近年 iPhone 上约 10–20 秒完成。
final class ClipReverser {

    func reverse(
        sourceURL: URL,
        outputURL: URL,
        progress: @escaping (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)

        // 第一遍：收集所有帧的 PTS（按显示顺序排序，兼容 B 帧）
        let allTimes = try Self.collectPresentationTimes(asset: asset, track: videoTrack)
        guard !allTimes.isEmpty else { throw ProcessingError.noVideoTrack }

        try? FileManager.default.removeItem(at: outputURL)

        // 编码器
        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 24_000_000,
            ],
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw ProcessingError.reverseFailed("无法添加编码输入")
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw ProcessingError.reverseFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        writer.startSession(atSourceTime: allTimes[0])

        // 窗口大小按分辨率自适应，控制峰值内存
        let windowFrameCount = width * height > 2_100_000 ? 12 : 30
        let total = allTimes.count
        let windows = stride(from: 0, to: total, by: windowFrameCount).map { start in
            start..<min(start + windowFrameCount, total)
        }

        var outputIndex = 0
        for window in windows.reversed() {
            if isCancelled() {
                writerInput.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw ProcessingError.cancelled
            }

            let startTime = allTimes[window.lowerBound]
            let endTime = window.upperBound < total
                ? allTimes[window.upperBound]
                : CMTimeAdd(duration, CMTime(value: 1, timescale: 30))
            let frames = try Self.decodeFrames(
                asset: asset,
                track: videoTrack,
                timeRange: CMTimeRange(start: startTime, end: endTime),
                expectedCount: window.count
            )

            for frame in frames.reversed() {
                while !writerInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(10))
                    if writer.status == .failed {
                        throw ProcessingError.reverseFailed(writer.error?.localizedDescription ?? "编码器出错")
                    }
                }
                guard outputIndex < total else { break }
                guard adaptor.append(frame, withPresentationTime: allTimes[outputIndex]) else {
                    let detail = writer.error?.localizedDescription ?? "append 失败"
                    writerInput.markAsFinished()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    throw ProcessingError.reverseFailed(detail)
                }
                outputIndex += 1
            }
            progress(Double(outputIndex) / Double(total))
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ProcessingError.reverseFailed(writer.error?.localizedDescription ?? "写入未完成")
        }
        AppLogger.processing.info("倒放素材完成：\(outputURL.lastPathComponent, privacy: .public)，共 \(total) 帧")
    }

    // MARK: - 读取

    /// passthrough 读取（不解码），收集全部样本的显示时间戳并按显示顺序排序。
    private static func collectPresentationTimes(asset: AVAsset, track: AVAssetTrack) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ProcessingError.reverseFailed("无法读取视频轨")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ProcessingError.reverseFailed(reader.error?.localizedDescription ?? "读取启动失败")
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts.isValid, CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(pts)
            }
        }
        if reader.status == .failed {
            throw ProcessingError.reverseFailed(reader.error?.localizedDescription ?? "读取失败")
        }
        return times.sorted { CMTimeCompare($0, $1) < 0 }
    }

    /// 解码指定时间窗内的帧（按显示顺序返回）。
    private static func decodeFrames(
        asset: AVAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange,
        expectedCount: Int
    ) throws -> [CVPixelBuffer] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ProcessingError.reverseFailed("无法解码视频轨")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ProcessingError.reverseFailed(reader.error?.localizedDescription ?? "解码启动失败")
        }
        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(expectedCount)
        while let sample = output.copyNextSampleBuffer() {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                frames.append(pixelBuffer)
            }
        }
        if reader.status == .failed {
            throw ProcessingError.reverseFailed(reader.error?.localizedDescription ?? "解码失败")
        }
        return frames
    }
}
