import Foundation

/// COS records read by the AI service. The normal QR manifest remains independent.
enum AICloudMetadata {
    struct EventGate: Encodable {
        let schema = 1
        let enabled: Bool
    }

    struct Source: Encodable {
        let schema = 1
        let eventId: String
        let objectKey: String

        init(eventID: UUID, videoID: UUID, fileName: String) {
            eventId = eventID.uuidString.lowercased()
            objectKey = AICloudMetadata.originalObjectKey(videoID, fileName: fileName)
        }
    }

    static func eventKey(_ eventID: UUID) -> String {
        "booth360/ai/events/\(eventID.uuidString.lowercased()).json"
    }

    static func sourceKey(_ videoID: UUID) -> String {
        "booth360/ai/sources/\(videoID.uuidString.lowercased()).json"
    }

    static func originalObjectKey(_ videoID: UUID, fileName: String) -> String {
        "booth360/\(videoID.uuidString.lowercased())/\(fileName)"
    }

    /// Backfill only originals that were uploaded to this COS configuration.
    static func isUploadedToCOS(_ urlString: String?, videoID: UUID, fileName: String, config: COSConfig) -> Bool {
        guard let urlString, let url = URL(string: urlString), url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        let path = "/\(originalObjectKey(videoID, fileName: fileName))"
        let landing = "/\(originalObjectKey(videoID, fileName: "index.html"))"
        return (host == config.host.lowercased() && url.path == path)
            || (host == config.publicHost.lowercased() && url.path == landing)
    }

    static func putEvent(_ eventID: UUID, enabled: Bool, config: COSConfig) async throws {
        try await put(EventGate(enabled: enabled), key: eventKey(eventID), config: config)
    }

    static func putSource(_ source: Source, videoID: UUID, config: COSConfig) async throws {
        try await put(source, key: sourceKey(videoID), config: config)
    }

    private static func put(_ value: some Encodable, key: String, config: COSConfig) async throws {
        let data = try JSONEncoder().encode(value)
        try await TencentCOSBackend.putObject(data: data, objectKey: key,
                                             contentType: "application/json", config: config, acl: "private")
    }
}
