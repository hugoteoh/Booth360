import Foundation
import CoreImage.CIFilterBuiltins
import UIKit

/// 字符串 → 二维码图片（放大到指定边长，保持硬边不模糊）。
enum QRCodeGenerator {
    static func image(for string: String, sidePixels: CGFloat = 600) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = sidePixels / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
