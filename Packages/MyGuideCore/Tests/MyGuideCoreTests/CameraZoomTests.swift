import Testing
import Foundation
@testable import MyGuideCore

@Suite struct CameraZoomTests {
    @Test func zoomNarrowsTheFOV() {
        // zoomed hFOV = 2·atan(tan(F/2)/z)
        // F=54.88, z=2: tan(27.44°)=0.5193; /2=0.2596; atan=14.55°; ·2 = 29.11°
        // F=90,    z=3: tan(45°)=1;         /3=0.3333; atan=18.43°; ·2 = 36.87°
        // F=54.88, z=5: 0.5193/5=0.1039;    atan=5.93°;              ·2 = 11.86°
        #expect(abs(FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: 2) - 29.11) < 0.01)
        #expect(abs(FieldOfView.zoomedHorizontalFOV(90, zoomFactor: 3) - 36.87) < 0.01)
        #expect(abs(FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: 5) - 11.86) < 0.01)
    }

    @Test func zoomOfOneOrInvalidLeavesTheFOVUnchanged() {
        #expect(abs(FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: 1) - 54.88) < 1e-9)
        // Below 1× would widen the cone past what the lens sees; the camera never goes there.
        #expect(abs(FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: 0.5) - 54.88) < 1e-9)
        #expect(abs(FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: 0) - 54.88) < 1e-9)
        #expect(abs(FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: .nan) - 54.88) < 1e-9)
        #expect(abs(FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: -2) - 54.88) < 1e-9)
    }

    @Test func zoomedFOVFeedsTheCone() {
        // F=54.88 at 2× → 29.11°; cone = 29.11/2 + 2·10 = 34.55°
        let fov = FieldOfView.zoomedHorizontalFOV(54.88, zoomFactor: 2)
        #expect(abs(FieldOfView.coneHalfWidth(horizontalFOV: fov, headingAccuracy: 10) - 34.55) < 0.01)
    }

    @Test func clampedStaysWithinOneAndTheLowerOfAppAndDeviceLimits() {
        #expect(CameraZoom.clamped(2.5, deviceMax: 16) == 2.5)
        #expect(CameraZoom.clamped(8, deviceMax: 16) == CameraZoom.maxFactor)
        #expect(CameraZoom.clamped(8, deviceMax: 3) == 3)
        #expect(CameraZoom.clamped(0.5, deviceMax: 16) == 1)
    }

    @Test func clampedBoundaries() {
        #expect(CameraZoom.maxFactor == 5)
        #expect(CameraZoom.clamped(1, deviceMax: 16) == 1)
        #expect(CameraZoom.clamped(5, deviceMax: 16) == 5)
        #expect(CameraZoom.clamped(3, deviceMax: 3) == 3)
    }

    @Test func clampedRejectsInvalidInput() {
        #expect(CameraZoom.clamped(.nan, deviceMax: 16) == 1)
        #expect(CameraZoom.clamped(.infinity, deviceMax: 16) == 1)
        #expect(CameraZoom.clamped(-3, deviceMax: 16) == 1)
        // A device that cannot zoom (or reports nonsense) stays at 1×.
        #expect(CameraZoom.clamped(3, deviceMax: 1) == 1)
        #expect(CameraZoom.clamped(3, deviceMax: 0.5) == 1)
        #expect(CameraZoom.clamped(3, deviceMax: .nan) == 1)
    }

    @Test func pinchScalesFromTheZoomAtGestureStart() {
        // base · magnification, clamped: 2·1.5 = 3;  4·2 = 8 → 5;  2·0.25 = 0.5 → 1
        #expect(CameraZoom.pinched(base: 2, magnification: 1.5, deviceMax: 16) == 3)
        #expect(CameraZoom.pinched(base: 4, magnification: 2, deviceMax: 16) == 5)
        #expect(CameraZoom.pinched(base: 2, magnification: 0.25, deviceMax: 16) == 1)
        #expect(CameraZoom.pinched(base: 2, magnification: 0, deviceMax: 16) == 1)
        #expect(CameraZoom.pinched(base: 2, magnification: .nan, deviceMax: 16) == 1)
    }

    @Test func labelShowsOneDecimalAndDropsATrailingZero() {
        #expect(CameraZoom.label(1) == "1×")
        #expect(CameraZoom.label(3) == "3×")
        #expect(CameraZoom.label(2.46) == "2.5×")
        #expect(CameraZoom.label(1.44) == "1.4×")
        #expect(CameraZoom.label(2.04) == "2×")
        #expect(CameraZoom.label(4.96) == "5×")
    }
}
