import Foundation
import CoreGraphics

enum ExternalWallLayoutMode: String, CaseIterable, Identifiable {
    case grid
    case featured
    case cinema

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grid: return "网格"
        case .featured: return "最新主打"
        case .cinema: return "全屏轮播"
        }
    }
}

struct ExternalWallPlacement: Identifiable {
    let index: Int
    let videoFrame: CGRect
    let qrFrame: CGRect
    var id: Int { index }
}

/// 以真实屏幕尺寸排版，保持网页的竖卡/右下二维码结构。
/// 网页像素常量随屏宽等比放大，使 4K 的二维码不会仍停留在 1080p 尺寸。
struct ExternalWallLayout {
    private static let videoAspect: CGFloat = 9.0 / 16.0

    static func placements(
        size: CGSize,
        count: Int,
        activeIndex: Int,
        mode: ExternalWallLayoutMode
    ) -> [ExternalWallPlacement] {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, count > 0 else { return [] }
        let count = min(count, 8)
        let active = (0..<count).contains(activeIndex) ? activeIndex : 0
        let scale = size.width / 1920
        switch mode {
        case .grid:
            return grid(size: size, count: count, scale: scale)
        case .featured:
            return featured(size: size, count: count, active: active, scale: scale)
        case .cinema:
            return cinema(size: size, active: active, scale: scale)
        }
    }

    private struct CardMetrics {
        let videoSize: CGSize
        let qrSide: CGFloat
        let gap: CGFloat
        let bottomInset: CGFloat
        var width: CGFloat { videoSize.width + gap + qrSide }
    }

    private static func grid(size: CGSize, count: Int, scale: CGFloat) -> [ExternalWallPlacement] {
        let safe = safeRect(size: size,
                            horizontal: clamp(size.width * 0.04, 36 * scale, 70 * scale),
                            vertical: clamp(size.height * 0.04, 28 * scale, 56 * scale))
        let gap = min(clamp(size.width * 0.013, 12 * scale, 22 * scale),
                      min(safe.width / 20, safe.height / 12))
        // 不随条目数量放大：一条视频与八条视频共用四列、两行的基准尺寸。
        let slot = CGSize(width: (safe.width - 3 * gap) / 4, height: (safe.height - gap) / 2)
        let card = cardMetrics(slot: slot, qrSide: clamp(size.width * 0.064, 64 * scale, 96 * scale), scale: scale)
        let rows = count > 4 ? 2 : 1
        let blockHeight = CGFloat(rows) * card.videoSize.height + CGFloat(rows - 1) * gap
        let top = safe.midY - blockHeight / 2
        return (0..<count).map { index in
            let row = index / 4
            let column = index % 4
            let rowCount = min(4, count - row * 4)
            let rowWidth = CGFloat(rowCount) * card.width + CGFloat(rowCount - 1) * gap
            let x = safe.midX - rowWidth / 2 + CGFloat(column) * (card.width + gap)
            let y = top + CGFloat(row) * (card.videoSize.height + gap)
            return placement(index: index, x: x, y: y, metrics: card)
        }
    }

    private static func featured(size: CGSize, count: Int, active: Int, scale: CGFloat) -> [ExternalWallPlacement] {
        let safe = safeRect(size: size,
                            horizontal: clamp(size.width * 0.034, 30 * scale, 60 * scale),
                            vertical: clamp(size.height * 0.032, 22 * scale, 44 * scale))
        let sectionGap = min(clamp(size.height * 0.016, 10 * scale, 20 * scale), safe.height / 12)
        let availableHeight = safe.height - sectionGap
        // 与网页 .feat-hero flex:1.6、.feat-strip flex:.45 对齐。
        let heroHeight = availableHeight * (1.6 / 2.05)
        let stripHeight = availableHeight - heroHeight
        let heroRegion = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: heroHeight)
        let heroGap = min(14 * scale, min(safe.width * 0.03, heroHeight * 0.05))
        let heroQR = min(clamp(size.width * 0.08, 84 * scale, 128 * scale),
                         min(heroHeight * 0.5, safe.width * 0.18))
        // 二维码不能把主视频挤离屏幕中轴；只在窄屏时收小视频。
        let maximumHeroWidth = safe.width - 2 * (heroGap + heroQR)
        let heroVideoHeight = min(heroHeight, maximumHeroWidth / videoAspect)
        let heroVideoWidth = heroVideoHeight * videoAspect
        let heroVideo = CGRect(x: size.width / 2 - heroVideoWidth / 2,
                               y: heroRegion.maxY - heroVideoHeight,
                               width: heroVideoWidth, height: heroVideoHeight)
        let heroBottomInset = min(8 * scale, heroVideoHeight * 0.1)
        let heroQRFrame = CGRect(x: heroVideo.maxX + heroGap,
                                 y: heroVideo.maxY - heroBottomInset - heroQR,
                                 width: heroQR, height: heroQR)
        var result = [ExternalWallPlacement(index: active, videoFrame: heroVideo, qrFrame: heroQRFrame)]

        let remaining = (0..<count).filter { $0 != active }.prefix(6)
        guard !remaining.isEmpty else { return result }
        let stripGap = min(clamp(size.width * 0.012, 10 * scale, 20 * scale),
                           min(safe.width / 20, stripHeight / 12))
        let slot = CGSize(width: (safe.width - 5 * stripGap) / 6, height: stripHeight)
        let card = cardMetrics(slot: slot, qrSide: clamp(size.width * 0.064, 64 * scale, 96 * scale), scale: scale)
        let stripCount = remaining.count
        let occupiedWidth = CGFloat(stripCount) * card.width + CGFloat(stripCount - 1) * stripGap
        let extraSpace = max(0, safe.width - occupiedWidth) / CGFloat(stripCount + 1)
        let top = safe.maxY - card.videoSize.height
        for (column, index) in remaining.enumerated() {
            let x = safe.minX + extraSpace + CGFloat(column) * (card.width + stripGap + extraSpace)
            result.append(placement(index: index, x: x, y: top, metrics: card))
        }
        return result
    }

    private static func cinema(size: CGSize, active: Int, scale: CGFloat) -> [ExternalWallPlacement] {
        let safe = safeRect(size: size, horizontal: size.width * 0.03, vertical: size.height * 0.03)
        let qrSide = min(clamp(size.width * 0.11, 110 * scale, 176 * scale),
                         min(safe.width * 0.2, safe.height * 0.25))
        let rightMargin = min(size.width * 0.2,
                              max(safe.minX, clamp(size.width * 0.034, 20 * scale, 64 * scale)))
        let bottomMargin = min(size.height * 0.2,
                               max(safe.minY, clamp(size.height * 0.06, 26 * scale, 72 * scale)))
        let qr = CGRect(x: size.width - rightMargin - qrSide,
                        y: size.height - bottomMargin - qrSide,
                        width: qrSide, height: qrSide)
        var height = min(size.height * 0.9, min(safe.height, safe.width / videoAspect))
        func videoFrame(height: CGFloat) -> CGRect {
            let width = height * videoAspect
            return CGRect(x: size.width / 2 - width / 2, y: size.height / 2 - height / 2,
                          width: width, height: height)
        }
        if videoFrame(height: height).intersects(qr) {
            let gap = min(14 * scale, min(safe.width * 0.03, safe.height * 0.03))
            // 保持视频居中，选择横向分离或纵向分离中更大的可用尺寸。
            let besideQR = max(0, 2 * (qr.minX - gap - size.width / 2) / videoAspect)
            let aboveQR = max(0, 2 * (qr.minY - gap - size.height / 2))
            height = min(height, max(besideQR, aboveQR))
        }
        return [ExternalWallPlacement(index: active, videoFrame: videoFrame(height: height), qrFrame: qr)]
    }

    /// 极窄或极矮屏幕中一起收小二维码与留白，始终保留有效的视频区域。
    private static func cardMetrics(slot: CGSize, qrSide: CGFloat, scale: CGFloat) -> CardMetrics {
        let qr = min(qrSide, min(slot.height * 0.8, slot.width * 0.4))
        let gap = min(10 * scale, min(slot.width * 0.05, slot.height * 0.1))
        let height = min(slot.height, (slot.width - qr - gap) / videoAspect)
        return CardMetrics(videoSize: CGSize(width: height * videoAspect, height: height), qrSide: qr,
                           gap: gap, bottomInset: min(4 * scale, height * 0.1))
    }

    private static func placement(index: Int, x: CGFloat, y: CGFloat, metrics: CardMetrics) -> ExternalWallPlacement {
        let video = CGRect(origin: CGPoint(x: x, y: y), size: metrics.videoSize)
        let qr = CGRect(x: video.maxX + metrics.gap,
                        y: video.maxY - metrics.bottomInset - metrics.qrSide,
                        width: metrics.qrSide, height: metrics.qrSide)
        return ExternalWallPlacement(index: index, videoFrame: video, qrFrame: qr)
    }

    private static func safeRect(size: CGSize, horizontal: CGFloat, vertical: CGFloat) -> CGRect {
        let x = min(size.width * 0.2, max(size.width * 0.03, horizontal))
        let y = min(size.height * 0.2, max(size.height * 0.03, vertical))
        return CGRect(x: x, y: y, width: size.width - 2 * x, height: size.height - 2 * y)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
