import Foundation
import CoreGraphics

/// 纯几何计算：源视频（含旋转元数据）→ 目标画幅的居中裁切变换。
/// 不接触 AVFoundation 类型，单元测试覆盖。
enum CropGeometry {

    /// 应用 preferredTransform 之后的显示尺寸（如横拍 1920×1080 + 90° 旋转 → 1080×1920）。
    static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// 把 preferredTransform 归一化：旋转后内容平移回原点（0,0），
    /// 消除录制元数据里可能缺失/多余的平移分量。
    static func normalizedTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return preferredTransform.concatenating(
            CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// 导出用最终变换：先摆正（归一化旋转），再等比缩放到铺满 renderSize，再居中。
    /// 超出部分即被裁掉（aspect-fill 居中裁切）。
    static func exportTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let upright = normalizedTransform(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let size = displaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        guard size.width > 0, size.height > 0 else { return upright }

        let scale = max(renderSize.width / size.width, renderSize.height / size.height)
        let scaledWidth = size.width * scale
        let scaledHeight = size.height * scale
        let offsetX = (renderSize.width - scaledWidth) / 2
        let offsetY = (renderSize.height - scaledHeight) / 2

        return upright
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }
}
