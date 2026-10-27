import Foundation

/// Pinch-to-zoom rules for the in-app camera (main lens, digital zoom).
public enum CameraZoom {
    /// Beyond this the main lens's digital crop is too soft to help identify a subject.
    public static let maxFactor = 5.0

    /// The factor within 1...min(maxFactor, deviceMax). Invalid input, or a device that cannot zoom, gives 1.
    public static func clamped(_ factor: Double, deviceMax: Double) -> Double {
        guard factor.isFinite, deviceMax.isFinite else { return 1 }
        let upper = max(1, min(maxFactor, deviceMax))
        return min(max(factor, 1), upper)
    }

    /// The zoom during a pinch: the zoom when the gesture began, scaled by the gesture's magnification.
    public static func pinched(base: Double, magnification: Double, deviceMax: Double) -> Double {
        clamped(base * magnification, deviceMax: deviceMax)
    }

    /// "1×", "2.5×": one decimal, without a trailing ".0".
    public static func label(_ factor: Double) -> String {
        var text = String(format: "%.1f", factor)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + "×"
    }
}
