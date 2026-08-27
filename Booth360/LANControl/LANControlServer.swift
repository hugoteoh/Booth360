import Foundation
import Network
import Observation

/// 手机内建控制服务器：同一 Wi-Fi 下用浏览器（Windows/Mac 均可）打开
/// http://<手机IP>:8360 控制拍摄。Bonjour 广播 _booth360._tcp 便于发现。
///
/// 安全：所有 POST 操作要求 ?pin=<管理员PIN>；GET 状态为只读信息。
@Observable
@MainActor
final class LANControlServer {

    /// 由 RootView 注入的能力（服务器自身不碰数据库/相机）。
    struct Handlers {
        var status: () -> [String: Any]
        var events: () -> [[String: Any]]
        var activateEvent: (UUID) -> Bool
        var openGuest: () -> Bool
        var startCapture: () -> Bool
    }

    static let port: UInt16 = 8360

    private(set) var isRunning = false
    private(set) var displayURL: String?
    private(set) var lastError: String?

    @ObservationIgnored var handlers: Handlers?
    @ObservationIgnored private var listener: NWListener?

    // MARK: - 开关

    func start() {
        guard !isRunning else { return }
        lastError = nil
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "Booth360", type: "_booth360._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                self?.receive(on: connection, buffer: Data())
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        let ip = Self.localIPAddress() ?? "<手机IP>"
                        self.displayURL = "http://\(ip):\(Self.port)"
                        AppLogger.ui.info("局域网控制已启动: \(self.displayURL ?? "", privacy: .public)")
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                        self.listener = nil
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        displayURL = nil
    }

    // MARK: - 收发

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }

                // 头部收全（\r\n\r\n）即可路由；控制台请求无 body
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                    let response = self.route(headText)
                    self.send(response, on: connection)
                } else if isComplete || buffer.count > 128 * 1024 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: (status: String, contentType: String, body: Data), on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 路由

    private func route(_ requestHead: String) -> (status: String, contentType: String, body: Data) {
        guard let request = HTTPRequestParser.parse(requestHead) else {
            return ("400 Bad Request", "text/plain", Data("bad request".utf8))
        }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return ("200 OK", "text/html; charset=utf-8", Data(ControlPageHTML.html.utf8))

        case ("GET", "/api/status"):
            let payload = handlers?.status() ?? [:]
            return json(payload)

        case ("GET", "/api/events"):
            let payload = handlers?.events() ?? []
            return jsonArray(payload)

        case ("POST", "/api/events/activate"):
            guard pinOK(request) else { return unauthorized() }
            guard let idText = request.query["id"], let id = UUID(uuidString: idText),
                  handlers?.activateEvent(id) == true else {
                return json(["ok": false, "message": "活动不存在"], status: "409 Conflict")
            }
            return json(["ok": true])

        case ("POST", "/api/guest/open"):
            guard pinOK(request) else { return unauthorized() }
            guard handlers?.openGuest() == true else {
                return json(["ok": false, "message": "没有可用活动（先在手机上创建并设为当前）"], status: "409 Conflict")
            }
            return json(["ok": true])

        case ("POST", "/api/guest/start"):
            guard pinOK(request) else { return unauthorized() }
            guard handlers?.startCapture() == true else {
                return json(["ok": false, "message": "嘉宾模式未开启或正在拍摄中"], status: "409 Conflict")
            }
            return json(["ok": true])

        default:
            return ("404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    private func pinOK(_ request: ParsedHTTPRequest) -> Bool {
        request.query["pin"] == PINPadView.storedPIN
    }

    private func unauthorized() -> (status: String, contentType: String, body: Data) {
        json(["ok": false, "message": "PIN 不正确"], status: "401 Unauthorized")
    }

    private func json(
        _ object: [String: Any],
        status: String = "200 OK"
    ) -> (status: String, contentType: String, body: Data) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return (status, "application/json; charset=utf-8", data)
    }

    private func jsonArray(
        _ array: [[String: Any]]
    ) -> (status: String, contentType: String, body: Data) {
        let data = (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8)
        return ("200 OK", "application/json; charset=utf-8", data)
    }

    // MARK: - 本机 IP

    /// Wi-Fi (en0) 的 IPv4 地址，用于展示控制台网址。
    static func localIPAddress() -> String? {
        var address: String?
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0 else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var pointer = ifaddrPointer
        while let current = pointer {
            let interface = current.pointee
            if let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: hostname)
                }
            }
            pointer = interface.ifa_next
        }
        return address
    }
}
