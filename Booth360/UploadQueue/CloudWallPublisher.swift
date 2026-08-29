import Foundation
import UIKit

/// 云端大屏：把「节目单 + 页面 + 二维码图」发布到 COS 的 booth360/wall/ 下，
/// 大屏电脑在任何网络打开固定地址即可：
///   https://<bucket>.cos.<region>.myqcloud.com/booth360/wall/index.html
///
/// 发布物（全部带 x-cos-acl: public-read，签名头保证生效）：
///   booth360/wall/index.html   大屏页面（每次发布覆盖，保证最新版）
///   booth360/wall/wall.json    节目单：最近 30 条 {id, time, url, qrURL}
///   booth360/<renderID>/qr.png 每条视频的下载二维码（只传一次）
/// 视频/二维码链接用 7 天预签名 GET；每次发布全部重新生成，活动期间永远新鲜。
enum CloudWallPublisher {

    struct WallItem {
        let id: UUID
        let createdAt: Date
        /// Renders 目录里的文件名（用于重构 COS objectKey 重新签名）。
        let fileName: String
    }

    static var pageURLString: String? {
        let config = COSConfig.load()
        guard config.isComplete else { return nil }
        return "https://\(config.publicHost)/booth360/wall/index.html"
    }

    /// 发布/刷新云端大屏。items 传最近的已上传成品（新→旧）；
    /// 空列表也照常发布（大屏显示等待画面），用于切换活动后清空上一场的节目单。
    static func publish(items: [WallItem]) async {
        let config = COSConfig.load()
        guard config.isComplete else { return }

        do {
            // 每次发布对全部条目重新签名 + 重生成二维码：链接永远新鲜（各 7 天有效期从现在起算）
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            var jsonItems: [[String: Any]] = []
            for item in items {
                let baseKey = "booth360/\(item.id.uuidString.lowercased())"
                // 落地页与二维码用永久公开地址（自定义域名）；页内视频链接每次发布续期 7 天。
                // 未配置自定义域名时二维码退回视频直链（默认域名 HTML 会被微信当附件下载）。
                let pageURL = "https://\(config.publicHost)/\(baseKey)/index.html"
                let qrURL = "https://\(config.publicHost)/\(baseKey)/qr.png"
                guard let videoURL = COSSigner.signedURL(
                        config: config, objectKey: "\(baseKey)/\(item.fileName)",
                        method: "get", expiresSeconds: TencentCOSBackend.downloadExpirySeconds),
                      let qrImage = QRCodeGenerator.image(
                        for: config.hasCustomDomain ? pageURL : videoURL.absoluteString,
                        sidePixels: 480),
                      let qrPNG = qrImage.pngData() else { continue }
                try await putPublicObject(
                    data: qrPNG,
                    objectKey: "\(baseKey)/qr.png",
                    contentType: "image/png",
                    config: config
                )
                let landingHTML = DownloadPageHTML.html(
                    videoURL: videoURL.absoluteString,
                    title: "你的 360 视频"
                )
                try await putPublicObject(
                    data: Data(landingHTML.utf8),
                    objectKey: "\(baseKey)/index.html",
                    contentType: "text/html; charset=utf-8",
                    config: config
                )
                jsonItems.append([
                    "id": item.id.uuidString,
                    "time": formatter.string(from: item.createdAt),
                    "url": videoURL.absoluteString,
                    "qr": qrURL,
                    "page": pageURL,
                ])
            }
            let manifest: [String: Any] = [
                "updatedAt": Int(Date().timeIntervalSince1970),
                "items": jsonItems,
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest)
            try await putPublicObject(
                data: manifestData,
                objectKey: "booth360/wall/wall.json",
                contentType: "application/json",
                config: config
            )

            // 3. 页面本体（覆盖上传，永远最新版）
            try await putPublicObject(
                data: Data(CloudWallPageHTML.html.utf8),
                objectKey: "booth360/wall/index.html",
                contentType: "text/html; charset=utf-8",
                config: config
            )
            AppLogger.storage.info("云端大屏已发布 \(jsonItems.count) 条")
        } catch {
            // 发布失败不影响主流程，下次上传成功后会再试
            AppLogger.storage.error("云端大屏发布失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 带 x-cos-acl: public-read 的 PUT（ACL 头已签名）。TencentCOSBackend 发布落地页也用。
    static func putPublicObject(
        data: Data,
        objectKey: String,
        contentType: String,
        config: COSConfig
    ) async throws {
        guard let url = COSSigner.signedURL(
            config: config,
            objectKey: objectKey,
            method: "put",
            expiresSeconds: 600,
            extraHeaders: ["x-cos-acl": "public-read"]
        ) else {
            throw UploadError.network("无法构造发布 URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("public-read", forHTTPHeaderField: "x-cos-acl")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UploadError.serverRejected(
                statusCode: code, body: String(data: body, encoding: .utf8) ?? "")
        }
    }
}
