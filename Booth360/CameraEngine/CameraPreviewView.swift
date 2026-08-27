import SwiftUI
import AVFoundation

/// AVCaptureVideoPreviewLayer 的 SwiftUI 包装。
/// 挂载后把 layer 交给引擎（引擎用它建 RotationCoordinator 并驱动旋转）。
struct CameraPreviewView: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = engine.session
        view.previewLayer.videoGravity = .resizeAspectFill
        engine.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // 多个界面共用 session 时，谁在前台谁接管旋转跟随
        engine.ensurePreviewLayerAttached(uiView.previewLayer)
    }

    /// layerClass 指定为 preview layer，尺寸随 view 自动走，无需手动布局。
    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
