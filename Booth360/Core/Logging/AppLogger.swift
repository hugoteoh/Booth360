import Foundation
import os

/// 全 App 统一日志。用 Mac「控制台」App 过滤 subsystem "com.hugoteoh.booth360" 可查现场日志。
enum AppLogger {
    private static let subsystem = "com.hugoteoh.booth360"

    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let processing = Logger(subsystem: subsystem, category: "processing")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
