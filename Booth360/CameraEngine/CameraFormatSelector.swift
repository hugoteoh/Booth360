import Foundation

/// 设备格式的纯数据描述（从 AVCaptureDevice.Format 提取），使选择逻辑可以脱离真机单测。
struct FormatCandidate: Equatable {
    /// 在 device.formats 数组中的下标。
    let index: Int
    let width: Int32
    let height: Int32
    /// 该格式支持的最大帧率（取所有 range 的最大值）。
    let maxFrameRate: Double
    /// 像素合并格式（低光优化，清晰度略差），同分辨率下不优先。
    let isBinned: Bool
    /// 是否为多机位专用格式等需要回避的格式（Phase 1 不用 multi-cam，不回避也可）。
    let isMultiCamOnly: Bool
}

/// 格式选择结果。
struct FormatSelection: Equatable {
    let index: Int
    /// 实际生效帧率（可能因降级低于请求值）。
    let frameRate: Double
    /// 是否发生了帧率降级。
    let didFallBack: Bool
}

/// 纯逻辑：从候选格式中选出最符合 分辨率+帧率 要求的一个。
///
/// 规则：
/// 1. 只考虑分辨率完全匹配的格式。
/// 2. 在支持目标帧率的格式里，优先非 binned；再优先 maxFrameRate 最接近目标者
///    （避免选到 240fps 专用格式带来的视场裁切）。
/// 3. 目标帧率无格式支持时，按 240→120→60→30 逐级降到有支持的档位。
/// 4. 连 30fps 都不支持该分辨率时返回 nil（调用方抛 formatUnsupported）。
enum CameraFormatSelector {

    static let fallbackChain: [Double] = [240, 120, 60, 30]

    static func select(
        from candidates: [FormatCandidate],
        resolution: CaptureResolution,
        requestedFrameRate: Double
    ) -> FormatSelection? {
        let matchingSize = candidates.filter {
            $0.width == resolution.width && $0.height == resolution.height && !$0.isMultiCamOnly
        }
        guard !matchingSize.isEmpty else { return nil }

        // 从请求帧率开始沿降级链尝试
        let ratesToTry = [requestedFrameRate] + fallbackChain.filter { $0 < requestedFrameRate }
        for rate in ratesToTry {
            if let best = bestFormat(in: matchingSize, supporting: rate) {
                return FormatSelection(
                    index: best.index,
                    frameRate: rate,
                    didFallBack: rate < requestedFrameRate
                )
            }
        }
        return nil
    }

    private static func bestFormat(in candidates: [FormatCandidate], supporting rate: Double) -> FormatCandidate? {
        let capable = candidates.filter { $0.maxFrameRate >= rate }
        guard !capable.isEmpty else { return nil }
        return capable.min { a, b in
            if a.isBinned != b.isBinned { return !a.isBinned }        // 非 binned 优先
            if a.maxFrameRate != b.maxFrameRate { return a.maxFrameRate < b.maxFrameRate } // 刚好够用者优先
            return a.index < b.index                                   // 稳定排序
        }
    }
}
