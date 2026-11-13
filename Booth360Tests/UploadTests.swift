import XCTest
@testable import Booth360

final class UploadTests: XCTestCase {

    // MARK: - 指数退避

    func testBackoffGrowsExponentially() {
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 1), 5)
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 2), 10)
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 3), 20)
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 4), 40)
    }

    func testBackoffCappedAtFiveMinutes() {
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 8), 300)
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 20), 300)
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 100), 300)
    }

    func testBackoffHandlesZeroAndNegative() {
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: 0), 5)
        XCTAssertEqual(UploadBackoff.delaySeconds(attempt: -3), 5)
    }

    // MARK: - COS 预签名 URL

    private let config = COSConfig(
        region: "ap-shanghai",
        bucket: "test-1250000000",
        secretId: "AKIDEXAMPLE",
        secretKey: "examplesecretkey"
    )

    func testSignedURLStructure() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try XCTUnwrap(COSSigner.signedURL(
            config: config,
            objectKey: "booth360/abc/render.mp4",
            method: "put",
            expiresSeconds: 3600,
            now: now
        ))

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "test-1250000000.cos.ap-shanghai.myqcloud.com")
        XCTAssertEqual(url.path, "/booth360/abc/render.mp4")

        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        XCTAssertEqual(value("q-sign-algorithm"), "sha1")
        XCTAssertEqual(value("q-ak"), "AKIDEXAMPLE")
        XCTAssertEqual(value("q-sign-time"), "1700000000;1700003600")
        XCTAssertEqual(value("q-key-time"), "1700000000;1700003600")
        XCTAssertEqual(value("q-header-list"), "host")
        // 签名为 40 位十六进制（HMAC-SHA1）
        let signature = try XCTUnwrap(value("q-signature"))
        XCTAssertEqual(signature.count, 40)
        XCTAssertTrue(signature.allSatisfy(\.isHexDigit))
    }

    func testSignedURLWithExtraHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try XCTUnwrap(COSSigner.signedURL(
            config: config,
            objectKey: "booth360/wall/wall.json",
            method: "put",
            expiresSeconds: 600,
            now: now,
            extraHeaders: ["x-cos-acl": "public-read"]
        ))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        // 头列表按字典序：host < x-cos-acl
        XCTAssertEqual(value("q-header-list"), "host;x-cos-acl")
        let signature = try XCTUnwrap(value("q-signature"))
        XCTAssertEqual(signature.count, 40)
        // 带头与不带头的签名必须不同
        let plain = COSSigner.signedURL(
            config: config, objectKey: "booth360/wall/wall.json",
            method: "put", expiresSeconds: 600, now: now)
        XCTAssertNotEqual(url, plain)
    }

    func testRFC3986Encode() {
        XCTAssertEqual(COSSigner.rfc3986Encode("public-read"), "public-read")
        XCTAssertEqual(COSSigner.rfc3986Encode("a b/c"), "a%20b%2Fc")
        XCTAssertEqual(COSSigner.rfc3986Encode("值"), "%E5%80%BC")
    }

    func testSignatureIsDeterministicAndMethodSensitive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let putA = COSSigner.signedURL(config: config, objectKey: "k/v.mp4", method: "put", expiresSeconds: 60, now: now)
        let putB = COSSigner.signedURL(config: config, objectKey: "k/v.mp4", method: "put", expiresSeconds: 60, now: now)
        let get = COSSigner.signedURL(config: config, objectKey: "k/v.mp4", method: "get", expiresSeconds: 60, now: now)
        XCTAssertEqual(putA, putB, "同输入必须同签名")
        XCTAssertNotEqual(putA, get, "方法不同签名必须不同")
    }

    func testHashHelpers() {
        // SHA1("abc") 已知值
        XCTAssertEqual(COSSigner.sha1Hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        // HMAC-SHA1(key:"key", msg:"The quick brown fox jumps over the lazy dog") 已知值
        XCTAssertEqual(
            COSSigner.hmacSHA1Hex(key: "key", message: "The quick brown fox jumps over the lazy dog"),
            "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9"
        )
    }

    func testCOSConfigCompleteness() {
        XCTAssertTrue(config.isComplete)
        var incomplete = config
        incomplete.bucket = ""
        XCTAssertFalse(incomplete.isComplete)
    }

    func testPrivateAIRecordKeysAndSchema() throws {
        let eventID = try XCTUnwrap(UUID(uuidString: "F4D5F368-1142-4181-97D1-4A984A8C22A3"))
        let videoID = try XCTUnwrap(UUID(uuidString: "72EF184B-C013-4761-A587-B1A318DD027C"))
        let source = AICloudMetadata.Source(eventID: eventID, videoID: videoID, fileName: "original.mp4")
        let sourceData = try JSONEncoder().encode(source)
        let sourceJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceData) as? [String: Any])
        XCTAssertEqual(AICloudMetadata.eventKey(eventID), "booth360/ai/events/f4d5f368-1142-4181-97d1-4a984a8c22a3.json")
        XCTAssertEqual(AICloudMetadata.sourceKey(videoID), "booth360/ai/sources/72ef184b-c013-4761-a587-b1a318dd027c.json")
        XCTAssertEqual(sourceJSON["schema"] as? Int, 1)
        XCTAssertEqual(sourceJSON["eventId"] as? String, "f4d5f368-1142-4181-97d1-4a984a8c22a3")
        XCTAssertEqual(sourceJSON["objectKey"] as? String, "booth360/72ef184b-c013-4761-a587-b1a318dd027c/original.mp4")

        for enabled in [true, false] {
            let eventData = try JSONEncoder().encode(AICloudMetadata.EventGate(enabled: enabled))
            let eventJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: eventData) as? [String: Any])
            XCTAssertEqual(eventJSON["schema"] as? Int, 1)
            XCTAssertEqual(eventJSON["enabled"] as? Bool, enabled)
        }
    }

    func testAIBackfillOnlyRecognizesOriginalsInConfiguredCOS() {
        let videoID = UUID()
        let fileName = "original.mp4"
        var active = config
        active.customDomain = "booth.example.org"
        let base = "/booth360/\(videoID.uuidString.lowercased())"
        func matches(_ url: String) -> Bool {
            AICloudMetadata.isUploadedToCOS(url, videoID: videoID, fileName: fileName, config: active)
        }

        XCTAssertTrue(matches("https://\(active.host)\(base)/original.mp4?q-signature=test"))
        XCTAssertTrue(matches("https://booth.example.org\(base)/index.html"))
        XCTAssertFalse(matches("https://mock.booth360.local/download\(base)/original.mp4"))
        XCTAssertFalse(matches("https://other.cos.ap-shanghai.myqcloud.com\(base)/original.mp4"))
        XCTAssertFalse(matches("https://booth.example.org\(base)/another.mp4"))
    }
}
