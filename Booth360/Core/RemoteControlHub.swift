import Foundation
import Observation

/// 局域网控制与嘉宾模式之间的桥：
/// 服务器把“开始拍摄”请求写进来（计数器 +1），嘉宾界面 onChange 响应；
/// 嘉宾 VM 把当前阶段回写进来，服务器 /api/status 读取。
@Observable
@MainActor
final class RemoteControlHub {
    /// 远程“开始拍摄”请求（每次 +1，GuestModeView 监听变化）。
    private(set) var startRequestID = 0
    /// 嘉宾模式是否开启中。
    var guestActive = false
    /// 嘉宾当前阶段的可读描述（供控制台显示）。
    var guestPhaseText = "未开启"

    func requestStart() {
        startRequestID += 1
    }
}

/// 运营者信息（本地档案）。真正的多设备账号系统需要后端，当前先落地本地档案：
/// 名称显示在嘉宾欢迎页底部，联系方式仅存本机备查。
struct OperatorProfile: Codable, Equatable {
    var studioName: String = ""
    var contact: String = ""
}

enum AccountStore {
    private static let key = "booth360.operatorProfile"

    static func load() -> OperatorProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(OperatorProfile.self, from: data) else {
            return OperatorProfile()
        }
        return profile
    }

    static func save(_ profile: OperatorProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
