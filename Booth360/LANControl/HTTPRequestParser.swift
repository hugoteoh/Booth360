import Foundation

/// 解析结果：方法、路径、查询参数。
struct ParsedHTTPRequest: Equatable {
    let method: String
    let path: String
    let query: [String: String]
}

/// 极简 HTTP 请求行解析（纯逻辑，单测覆盖）。
/// 只看第一行 "GET /api/status?pin=1234 HTTP/1.1"，够控制台用。
enum HTTPRequestParser {

    static func parse(_ requestText: String) -> ParsedHTTPRequest? {
        guard let firstLine = requestText.components(separatedBy: "\r\n").first,
              !firstLine.isEmpty else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        let path = String(pathAndQuery[0])
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let keyValue = pair.split(separator: "=", maxSplits: 1)
                guard let key = String(keyValue[0]).removingPercentEncoding else { continue }
                let value = keyValue.count == 2
                    ? (String(keyValue[1]).removingPercentEncoding ?? "")
                    : ""
                query[key] = value
            }
        }
        return ParsedHTTPRequest(method: method, path: path, query: query)
    }
}
