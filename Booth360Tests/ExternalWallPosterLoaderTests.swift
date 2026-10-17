import AVFoundation
import CoreGraphics
import CoreVideo
import UIKit
import XCTest
@testable import Booth360

/// Real local H.264 input; no camera, photo-library permission or TV is needed.
@MainActor
final class ExternalWallPosterLoaderTests: XCTestCase {
    func testPosterRespectsPortraitTransformSizeLimitAndContainsVisiblePixels() async throws {
        let directory = try workspace()
        let source = directory.appendingPathComponent("rotated-portrait.mp4")
        try await writePortraitVideo(to: source)
        let loader = ExternalWallPosterLoader()
        defer { loader.cancel() }

        let image = try await loader.image(for: source)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(image.imageOrientation, .up, "Rotation must be applied to pixels, not left as UIImage metadata")
        XCTAssertGreaterThan(pixels.width, 0)
        XCTAssertGreaterThan(pixels.height, pixels.width, "The landscape encoded track must become portrait")
        XCTAssertLessThanOrEqual(pixels.width, 320)
        XCTAssertLessThanOrEqual(pixels.height, 568)
        XCTAssertEqual(Double(pixels.width) / Double(pixels.height), 640.0 / 1136.0, accuracy: 0.01)
        let rgba = try sampleColor(of: pixels)
        XCTAssertGreaterThan(rgba[0] + rgba[1] + rgba[2], 40, "A decoded poster must contain visible color")
        XCTAssertGreaterThan(rgba[3], 0, "A transparent image is not a usable poster")
    }

    func testPreCancelledRequestThrowsCancellationErrorInsteadOfReturningPoster() async throws {
        let directory = try workspace()
        let source = directory.appendingPathComponent("cancelled-request.mp4")
        try await writePortraitVideo(to: source)
        let loader = ExternalWallPosterLoader()
        defer { loader.cancel() }

        // Both this test and the child task use MainActor. There is no suspension
        // between creation and cancel, so cancellation precedes image(for:).
        let request = Task { @MainActor in try await loader.image(for: source) }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("A pre-cancelled request must never produce a UIImage")
        } catch is CancellationError {
            // Expected; AVFoundation/file errors must not disguise cancellation.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Booth360PosterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only this test's UUID directory is removed, never a shared temp root.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writePortraitVideo(to url: URL) async throws {
        // Store landscape pixels plus the camera-style 90-degree transform. The
        // displayed source is 640 x 1136, so ignoring preferredTransform fails.
        let width = 1136
        let height = 640
        let frameCount = 15
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 600_000,
                AVVideoMaxKeyFrameIntervalKey: 6
            ]
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0,
                                            tx: CGFloat(height), ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
        guard writer.canAdd(input) else { throw fixtureError("Cannot add H.264 fixture input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? fixtureError("Cannot start fixture writer") }
        writer.startSession(atSourceTime: .zero)
        do {
            // A fresh simulator may take time to initialize its encoder. Wait
            // for readiness with a bounded cold-start budget, including frame 0.
            let deadline = Date().addingTimeInterval(60)
            for index in 0..<frameCount {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed || writer.status == .cancelled {
                        throw writer.error ?? fixtureError("Fixture encoder stopped")
                    }
                    guard Date() < deadline else {
                        throw fixtureError("Fixture encoder timed out at frame \(index), status \(writer.status.rawValue)")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let buffer = try colorBuffer(width: width, height: height)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                    throw writer.error ?? fixtureError("Cannot append fixture frame \(index)")
                }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? fixtureError("Fixture writer did not complete")
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    private func colorBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw fixtureError("Cannot allocate fixture pixel buffer: \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: CGFloat(width) / 2, y: 0,
                            width: CGFloat(width) / 2, height: CGFloat(height)))
        return buffer
    }

    private func sampleColor(of image: CGImage) throws -> [Int] {
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba.map(Int.init)
    }

    private func fixtureError(_ message: String) -> Error {
        NSError(domain: "ExternalWallPosterLoaderTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
