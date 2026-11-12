import CoreMedia

/// Shared static-frame position for the gallery and independent external wall.
enum VideoThumbnailTiming {
    static let fraction = 0.37
    static let cacheVersion = "thumbnail-37-v1"

    static func time(for duration: CMTime) -> CMTime {
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else { return .zero }
        let candidate = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
        // Sub-tick clips can round to the endpoint; the first frame stays valid.
        return candidate.isNumeric && candidate >= .zero && candidate < duration ? candidate : .zero
    }
}
