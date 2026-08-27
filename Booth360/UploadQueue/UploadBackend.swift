import Foundation

/// 上传后端抽象：把本地文件传上去，返回可分享的下载 URL（进二维码）。
/// progress 回调 0…1（可能从任意线程调用，调用方自行跳主线程）。
protocol UploadBackend {
    var displayName: String { get }
    func upload(
        fileURL: URL,
        objectKey: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL
}

enum UploadError: LocalizedError {
    case notConfigured
    case fileMissing
    case serverRejected(statusCode: Int, body: String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "上传未配置。请到 设置 → 上传 填写腾讯云 COS 信息。"
        case .fileMissing: return "本地文件不存在。"
        case .serverRejected(let code, let body):
            return "服务器拒绝（HTTP \(code)）：\(body.prefix(200))"
        case .network(let detail): return "网络错误：\(detail)"
        }
    }
}

/// 上传模式（设置页选择）。
enum UploadMode: String, CaseIterable, Identifiable {
    case off
    case mock
    case cos

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .mock: return "Mock（本地模拟）"
        case .cos: return "腾讯云 COS"
        }
    }

    static var current: UploadMode {
        get { UploadMode(rawValue: UserDefaults.standard.string(forKey: "booth360.uploadMode") ?? "off") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "booth360.uploadMode") }
    }
}

/// 本地模拟后端：延时 2 秒，直接返回一个假下载链接。
/// 用于没配 COS 时联调整个 队列→二维码 流程。
struct MockUploadBackend: UploadBackend {
    let displayName = "Mock"

    func upload(
        fileURL: URL,
        objectKey: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileMissing
        }
        for step in 1...5 {
            try await Task.sleep(for: .milliseconds(400))
            progress(Double(step) / 5.0)
        }
        guard let url = URL(string: "https://mock.booth360.local/download/\(objectKey)") else {
            throw UploadError.network("无法构造 Mock URL")
        }
        return url
    }
}

/// 指数退避：5s、10s、20s、40s…封顶 5 分钟。纯函数，单测覆盖。
enum UploadBackoff {
    static let baseDelay: Double = 5
    static let maxDelay: Double = 300

    static func delaySeconds(attempt: Int) -> Double {
        guard attempt > 0 else { return baseDelay }
        let raw = baseDelay * pow(2, Double(min(attempt - 1, 10)))
        return min(raw, maxDelay)
    }
}
