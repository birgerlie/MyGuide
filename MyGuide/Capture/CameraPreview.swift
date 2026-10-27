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
        view.expectedSession = session
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // The layer must always show the session it is given, not the one it was made with.
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.expectedSession = session
        view.applyPortraitRotation()
        view.logDiagnostics("updateUIView isRunning=\(isRunning)")
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        /// CAMDIAG: the session the representable hands in, to check the layer shows it.
        var expectedSession: AVCaptureSession?
        /// CAMDIAG: the last state printed, so layout passes print only when something changed.
        private var lastDiagnostics: String?

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyPortraitRotation()
            logDiagnostics("layoutSubviews")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            logDiagnostics("didMoveToWindow")
        }

        func applyPortraitRotation() {
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(90),
                  connection.videoRotationAngle != 90 else { return }
            connection.videoRotationAngle = 90
        }

        // CAMDIAG: temporary; remove with CameraDiagnostics.
        func logDiagnostics(_ event: String) {
            let layer = previewLayer
            let connection = layer.connection
            let state = "bounds=\(bounds.size) layer.frame=\(layer.frame) sessionMatches=\(layer.session === expectedSession && layer.session != nil) connection=\(connection != nil) isEnabled=\(connection.map { String($0.isEnabled) } ?? "-") isActive=\(connection.map { String($0.isActive) } ?? "-") rotation=\(connection.map { String(describing: $0.videoRotationAngle) } ?? "-") window=\(window != nil) hidden=\(isHidden) alpha=\(alpha) layer.isHidden=\(layer.isHidden) opacity=\(layer.opacity) previewing=\(layer.isPreviewing)"
            guard state != lastDiagnostics else { return }
            lastDiagnostics = state
            CameraDiagnostics.log("preview \(event): \(state)")
        }
    }
}
