import AVFoundation
import SwiftUI

/// Full-screen live preview of the capture session, fixed to portrait.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Changes when the session starts, so the preview connection (which only exists once the session
    /// has inputs) gets its portrait rotation.
    let isRunning: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // The layer must always show the session it is given, not the one it was made with.
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.applyPortraitRotation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyPortraitRotation()
        }

        func applyPortraitRotation() {
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(90),
                  connection.videoRotationAngle != 90 else { return }
            connection.videoRotationAngle = 90
        }
    }
}
