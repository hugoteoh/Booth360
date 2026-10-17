import AVFoundation
import UIKit

/// Produces one small, static poster without creating another video player.
/// The controller schedules requests serially while capture is idle.
@MainActor
final class ExternalWallPosterLoader {
    private enum LoaderError: Error {
        case invalidDuration
    }

    private var activeRequestID: UUID?
    private var activeAsset: AVURLAsset?
    private var activeGenerator: AVAssetImageGenerator?

    func image(for url: URL) async throws -> UIImage {
        try Task.checkCancellation()
        cancel()

        let requestID = UUID()
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 568)
        activeRequestID = requestID
        activeAsset = asset
        activeGenerator = generator

        defer {
            // A cancelled request may finish after its replacement has begun.
            // Its cleanup must never clear the replacement's cancellation handle.
            if activeRequestID == requestID {
                activeRequestID = nil
                activeAsset = nil
                activeGenerator = nil
            }
        }

        return try await withTaskCancellationHandler(operation: {
            do {
                let duration = try await asset.load(.duration)
                try checkCurrentRequest(requestID)
                guard duration.isNumeric, duration.seconds.isFinite,
                      duration.seconds > 0 else {
                    throw LoaderError.invalidDuration
                }

                let midpoint = CMTime(seconds: duration.seconds * 0.5,
                                      preferredTimescale: 600)
                // Extremely short clips may round the midpoint to the endpoint;
                // zero is still a legal request for any positive finite duration.
                let time = midpoint.isNumeric && midpoint >= .zero && midpoint < duration
                    ? midpoint : .zero
                let (cgImage, _) = try await generator.image(at: time)
                try checkCurrentRequest(requestID)
                return UIImage(cgImage: cgImage)
            } catch {
                // AVFoundation may report its own cancellation error. Expose a
                // single cancellation result, and never return an obsolete image.
                if Task.isCancelled || activeRequestID != requestID {
                    throw CancellationError()
                }
                throw error
            }
        }, onCancel: {
            // Capture this request's objects, not mutable controller state: a
            // late cancellation must not cancel a newer request's generator.
            generator.cancelAllCGImageGeneration()
            asset.cancelLoading()
        })
    }

    func cancel() {
        activeRequestID = nil
        let generator = activeGenerator
        let asset = activeAsset
        activeGenerator = nil
        activeAsset = nil
        generator?.cancelAllCGImageGeneration()
        asset?.cancelLoading()
    }

    private func checkCurrentRequest(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard activeRequestID == requestID else { throw CancellationError() }
    }
}
