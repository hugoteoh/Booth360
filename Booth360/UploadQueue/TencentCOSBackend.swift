import Foundation
import CryptoKit

/// 腾讯云 COS 配置。region/bucket/secretId 存 UserDefaults，secretKey 存 Keychain。
struct COSConfig {
    var region: String
    var bucket: String
    var secretId: String
    var secretKey: String

    var host: String { "\(bucket).cos.\(region).myqcloud.com" }

    var isComplete: Bool {
        !region.isEmpty && !bucket.isEmpty && !secretId.isEmpty && !secretKey.isEmpty
    }

    private enum Key {
        static let region = "booth360.cos.region"
        static let bucket = "booth360.cos.bucket"
        static let secretId = "booth360.cos.secretId"
        static let secretKey = "booth360.cos.secretKey"
    }

    static func load() -> COSConfig {
        let defaults = UserDefaults.standard
        return COSConfig(
            region: defaults.string(forKey: Key.region) ?? "ap-shanghai",
            bucket: defaults.string(forKey: Key.bucket) ?? "",
            secretId: defaults.string(forKey: Key.secretId) ?? "",
            secretKey: KeychainStore.get(Key.secretKey) ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(region, forKey: Key.region)
        defaults.set(bucket, forKey: Key.bucket)
        defaults.set(secretId, forKey: Key.secretId)
        KeychainStore.set(secretKey, forKey: Key.secretKey)
    }
}

/// COS XML API 预签名 URL 生成（q-sign-* 参数），与 AI PhotoBooth Pro 用的格式一致。
/// 算法：SignKey = HMAC-SHA1(SecretKey, KeyTime)；
///       StringToSign = "sha1\nKeyTime\nSHA1(HttpString)\n"；
///       Signature = HMAC-SHA1(SignKey, StringToSign)。
enum COSSigner {

    static func signedURL(
        config: COSConfig,
        objectKey: String,
        method: String,
        expiresSeconds: TimeInterval,
        now: Date = Date()
    ) -> URL? {
        let start = Int(now.timeIntervalSince1970)
        let end = start + Int(expiresSeconds)
        let keyTime = "\(start);\(end)"

        let signKey = hmacSHA1Hex(key: config.secretKey, message: keyTime)
        let httpString = "\(method.lowercased())\n/\(objectKey)\n\nhost=\(config.host)\n"
        let stringToSign = "sha1\n\(keyTime)\n\(sha1Hex(httpString))\n"
        let signature = hmacSHA1Hex(key: signKey, message: stringToSign)

        var components = URLComponents()
        components.scheme = "https"
        components.host = config.host
        components.path = "/" + objectKey
        components.queryItems = [
            URLQueryItem(name: "q-sign-algorithm", value: "sha1"),
            URLQueryItem(name: "q-ak", value: config.secretId),
            URLQueryItem(name: "q-sign-time", value: keyTime),
            URLQueryItem(name: "q-key-time", value: keyTime),
            URLQueryItem(name: "q-header-list", value: "host"),
            URLQueryItem(name: "q-url-param-list", value: ""),
            URLQueryItem(name: "q-signature", value: signature),
        ]
        return components.url
    }

    static func hmacSHA1Hex(key: String, message: String) -> String {
        let code = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(_ message: String) -> String {
        Insecure.SHA1.hash(data: Data(message.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// 真实上传：PUT 到预签名 URL，成功后返回 7 天有效的预签名下载链接。
struct TencentCOSBackend: UploadBackend {
    let config: COSConfig
    let displayName = "腾讯云 COS"

    /// 下载链接有效期：7 天（与 AI PhotoBooth Pro 一致）。
    static let downloadExpirySeconds: TimeInterval = 7 * 24 * 3600

    func upload(
        fileURL: URL,
        objectKey: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard config.isComplete else { throw UploadError.notConfigured }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileMissing
        }
        guard let putURL = COSSigner.signedURL(
            config: config, objectKey: objectKey, method: "put", expiresSeconds: 3600) else {
            throw UploadError.network("无法构造上传 URL")
        }

        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(
                for: request,
                fromFile: fileURL,
                delegate: UploadProgressDelegate(handler: progress)
            )
        } catch {
            throw UploadError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.network("无有效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UploadError.serverRejected(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let downloadURL = COSSigner.signedURL(
            config: config, objectKey: objectKey, method: "get",
            expiresSeconds: Self.downloadExpirySeconds) else {
            throw UploadError.network("无法构造下载 URL")
        }
        return downloadURL
    }
}

/// 上传进度回调（URLSession 按任务 delegate，iOS 15+）。
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let handler: (Double) -> Void

    init(handler: @escaping (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
