import Foundation
import CryptoKit

/// 腾讯云 COS 配置。region/bucket/secretId 存 UserDefaults，secretKey 存 Keychain。
struct COSConfig {
    var region: String
    var bucket: String
    var secretId: String
    var secretKey: String
    /// 自定义域名（如 booth360.yanyanle.com，反代到 COS 桶）。
    /// 落地页/大屏/二维码等公开链接用它——COS 默认域名访问 HTML 会被强制下载，微信里打不开。
    var customDomain: String = ""

    /// 签名与上传用的桶默认域名（反代会带这个 Host 回源，签名保持有效）。
    var host: String { "\(bucket).cos.\(region).myqcloud.com" }

    /// 公开页面链接用的域名。
    var publicHost: String { customDomain.isEmpty ? host : customDomain }
    var hasCustomDomain: Bool { !customDomain.isEmpty }

    var isComplete: Bool {
        !region.isEmpty && !bucket.isEmpty && !secretId.isEmpty && !secretKey.isEmpty
    }

    private enum Key {
        static let region = "booth360.cos.region"
        static let bucket = "booth360.cos.bucket"
        static let secretId = "booth360.cos.secretId"
        static let secretKey = "booth360.cos.secretKey"
        static let customDomain = "booth360.cos.customDomain"
    }

    static func load() -> COSConfig {
        let defaults = UserDefaults.standard
        return COSConfig(
            region: defaults.string(forKey: Key.region) ?? "ap-shanghai",
            bucket: defaults.string(forKey: Key.bucket) ?? "",
            secretId: defaults.string(forKey: Key.secretId) ?? "",
            secretKey: KeychainStore.get(Key.secretKey) ?? "",
            customDomain: defaults.string(forKey: Key.customDomain) ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(region, forKey: Key.region)
        defaults.set(bucket, forKey: Key.bucket)
        defaults.set(secretId, forKey: Key.secretId)
        defaults.set(customDomain, forKey: Key.customDomain)
        KeychainStore.set(secretKey, forKey: Key.secretKey)
    }
}

/// COS XML API 预签名 URL 生成（q-sign-* 参数），与 AI PhotoBooth Pro 用的格式一致。
/// 算法：SignKey = HMAC-SHA1(SecretKey, KeyTime)；
///       StringToSign = "sha1\nKeyTime\nSHA1(HttpString)\n"；
///       Signature = HMAC-SHA1(SignKey, StringToSign)。
enum COSSigner {

    /// 生成预签名 URL。extraHeaders 会一并签入（如 x-cos-acl），
    /// 发请求时必须携带完全相同的这些头。
    static func signedURL(
        config: COSConfig,
        objectKey: String,
        method: String,
        expiresSeconds: TimeInterval,
        now: Date = Date(),
        extraHeaders: [String: String] = [:]
    ) -> URL? {
        let start = Int(now.timeIntervalSince1970)
        let end = start + Int(expiresSeconds)
        let keyTime = "\(start);\(end)"

        // 签名头：host + extra，按 key 字典序排序（COS 规范）
        var headers = extraHeaders.reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
        headers["host"] = config.host
        let sortedKeys = headers.keys.sorted()
        let headerList = sortedKeys.joined(separator: ";")
        let headerString = sortedKeys
            .map { "\($0)=\(rfc3986Encode(headers[$0] ?? ""))" }
            .joined(separator: "&")

        let signKey = hmacSHA1Hex(key: config.secretKey, message: keyTime)
        let httpString = "\(method.lowercased())\n/\(objectKey)\n\n\(headerString)\n"
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
            URLQueryItem(name: "q-header-list", value: headerList),
            URLQueryItem(name: "q-url-param-list", value: ""),
            URLQueryItem(name: "q-signature", value: signature),
        ]
        return components.url
    }

    /// COS 要求的 RFC 3986 编码（保留字母数字与 -_.~）。
    static func rfc3986Encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
        guard let videoGET = COSSigner.signedURL(
            config: config, objectKey: objectKey, method: "get",
            expiresSeconds: Self.downloadExpirySeconds) else {
            throw UploadError.network("无法构造下载 URL")
        }

        // 生成扫码落地页（公开可读、地址永久）：二维码指向落地页而非裸视频文件。
        // 注意：COS 默认域名访问 HTML 会被强制当附件下载（微信打不开），
        // 所以只有配置了自定义域名时二维码才指向落地页；否则回退视频直链（微信可直接播放）。
        let baseKey = objectKey.split(separator: "/").dropLast().joined(separator: "/")
        let landingHTML = DownloadPageHTML.html(
            videoURL: videoGET.absoluteString,
            title: "你的 360 视频"
        )
        do {
            try await CloudWallPublisher.putPublicObject(
                data: Data(landingHTML.utf8),
                objectKey: "\(baseKey)/index.html",
                contentType: "text/html; charset=utf-8",
                config: config
            )
            if config.hasCustomDomain,
               let pageURL = URL(string: "https://\(config.publicHost)/\(baseKey)/index.html") {
                return pageURL
            }
        } catch {
            AppLogger.storage.error("落地页发布失败，回退视频直链: \(error.localizedDescription, privacy: .public)")
        }
        return videoGET
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
