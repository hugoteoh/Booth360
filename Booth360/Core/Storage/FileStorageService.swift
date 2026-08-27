import Foundation

/// 沙盒文件布局与源视频落盘路径管理。
///
/// 目录约定（全部在 Documents 下，UIFileSharingEnabled 已开启，
/// 用户可在「文件」App → Booth360 中直接看到）：
///   Documents/SourceClips/  源视频（只增不改）
///   Documents/Renders/      处理后的成品（Phase 2 使用）
///   Documents/Events/       活动素材 Logo/音乐/Overlay（Phase 3 使用）
struct FileStorageService {

    enum Directory: String, CaseIterable {
        case sourceClips = "SourceClips"
        case renders = "Renders"
        case events = "Events"
        /// 用户导入的 Overlay 图片、背景音乐（Phase 3 起并入活动配置）。
        case assets = "Assets"
    }

    let documentsURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 测试用：指定根目录。
    init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.documentsURL = rootURL
    }

    // MARK: - 目录

    func url(for directory: Directory) -> URL {
        documentsURL.appendingPathComponent(directory.rawValue, isDirectory: true)
    }

    /// App 启动时调用一次，确保目录齐全。
    func ensureDirectoriesExist() throws {
        for dir in Directory.allCases {
            let url = url(for: dir)
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - 源视频路径

    /// 生成一个新的源视频落盘 URL。文件名含时间戳 + UUID 前 8 位，保证不冲突。
    /// 例：clip_20260731_143005_a1b2c3d4.mov
    func newSourceClipURL(date: Date = Date(), uuid: UUID = UUID()) -> URL {
        url(for: .sourceClips).appendingPathComponent(
            Self.sourceClipFileName(date: date, uuid: uuid),
            isDirectory: false
        )
    }

    /// 纯函数，单测覆盖。
    static func sourceClipFileName(date: Date, uuid: UUID) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let shortID = uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "clip_\(formatter.string(from: date))_\(shortID).mov"
    }

    /// SwiftData 里只存相对文件名（沙盒绝对路径每次重装/更新会变）。
    func sourceClipURL(fileName: String) -> URL {
        url(for: .sourceClips).appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - 成品路径

    /// 例：render_20260731_143005_a1b2c3d4.mp4
    func newRenderURL(date: Date = Date(), uuid: UUID = UUID()) -> URL {
        url(for: .renders).appendingPathComponent(
            Self.renderFileName(date: date, uuid: uuid),
            isDirectory: false
        )
    }

    static func renderFileName(date: Date, uuid: UUID) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let shortID = uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "render_\(formatter.string(from: date))_\(shortID).mp4"
    }

    func renderURL(fileName: String) -> URL {
        url(for: .renders).appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - 导入素材路径（Overlay / 音乐）

    func assetURL(fileName: String) -> URL {
        url(for: .assets).appendingPathComponent(fileName, isDirectory: false)
    }

    /// 把用户挑选的素材拷入 Assets 目录（同名覆盖），返回落地文件名。
    func importAsset(from sourceURL: URL, preferredName: String) throws -> String {
        let destination = assetURL(fileName: preferredName)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return preferredName
    }

    /// 把内存数据落成素材文件（PhotosPicker 拿到的是 Data）。
    func importAsset(data: Data, preferredName: String) throws -> String {
        let destination = assetURL(fileName: preferredName)
        try? fileManager.removeItem(at: destination)
        try data.write(to: destination)
        return preferredName
    }

    // MARK: - 删除 / 查询

    func deleteFileIfExists(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            AppLogger.storage.error("删除文件失败 \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func fileSizeInBytes(at url: URL) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return 0 }
        return size
    }

    /// 可用磁盘空间（字节）。Phase 3 存储告警会用；现在用于录制前的日志。
    func availableDiskSpaceInBytes() -> Int64 {
        do {
            let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        } catch {
            return 0
        }
    }
}
