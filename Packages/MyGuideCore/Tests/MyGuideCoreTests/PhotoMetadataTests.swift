import Testing
import Foundation
import ImageIO
@testable import MyGuideCore

@Suite struct PhotoMetadataTests {
    @Test func readsSouthernGPSHeadingAndDate() throws {
        let data = TestImages.jpeg(width: 40, height: 30,
            gps: [kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
                  kCGImagePropertyGPSLongitude: 151.2093, kCGImagePropertyGPSLongitudeRef: "E",
                  kCGImagePropertyGPSImgDirection: 270.5, kCGImagePropertyGPSImgDirectionRef: "T"],
            exif: [kCGImagePropertyExifDateTimeOriginal: "2025:05:14 10:30:00",
                   kCGImagePropertyExifOffsetTimeOriginal: "+10:00"])
        let m = try #require(PhotoMetadata.read(from: data))
        #expect(m.coordinate == Coordinate(latitude: -33.8688, longitude: 151.2093))
        #expect(m.heading == 270.5)
        // 10:30 at +10:00 = 00:30 UTC
        #expect(m.takenAt == ISO8601DateFormatter().date(from: "2025-05-14T00:30:00Z"))
        #expect(m.pixelWidth == 40 && m.pixelHeight == 30)
    }
    @Test func westLongitudeIsNegative() throws {
        let data = TestImages.jpeg(width: 4, height: 4,
            gps: [kCGImagePropertyGPSLatitude: 48.2082, kCGImagePropertyGPSLatitudeRef: "N",
                  kCGImagePropertyGPSLongitude: 16.3738, kCGImagePropertyGPSLongitudeRef: "W"])
        #expect(try #require(PhotoMetadata.read(from: data)).coordinate == Coordinate(latitude: 48.2082, longitude: -16.3738))
    }
    @Test func noGPSGivesNilCoordinateAndHeading() throws {
        let m = try #require(PhotoMetadata.read(from: TestImages.jpeg(width: 4, height: 4)))
        #expect(m.coordinate == nil && m.heading == nil && m.takenAt == nil)
    }
    @Test func notAnImageReturnsNil() {
        #expect(PhotoMetadata.read(from: Data("hello".utf8)) == nil)
    }
    @Test func orientationSixSwapsPixelDimensions() throws {
        // Stored 40x30 with orientation 6 (rotate 90° CW) displays as 30 wide, 40 high.
        let m = try #require(PhotoMetadata.read(from: TestImages.jpeg(width: 40, height: 30, orientation: 6)))
        #expect(m.pixelWidth == 30 && m.pixelHeight == 40)
    }
    @Test func captureContextAssumesHeadingAccuracyOnlyWithHeading() {
        let fallback = Date(timeIntervalSince1970: 1_000)
        let withHeading = PhotoMetadata(coordinate: .init(latitude: 1, longitude: 2), heading: 90, takenAt: nil, pixelWidth: 3024, pixelHeight: 4032)
        let ctx = withHeading.captureContext(fallbackDate: fallback)
        #expect(ctx.headingAccuracy == 20 && ctx.usableHeading == 90 && ctx.source == .library && ctx.takenAt == fallback)
        #expect(abs(ctx.horizontalFOV - 54.88) < 0.05)
        let noHeading = PhotoMetadata(coordinate: nil, heading: nil, takenAt: nil, pixelWidth: 10, pixelHeight: 10)
        #expect(noHeading.captureContext(fallbackDate: fallback).headingAccuracy == nil)
    }
    @Test func withCoordinateClearsHeading() {
        let ctx = CaptureContext(coordinate: nil, horizontalAccuracy: nil, heading: 90, headingAccuracy: 20,
                                 horizontalFOV: 60, takenAt: .now, source: .library)
        let moved = ctx.withCoordinate(.init(latitude: 1, longitude: 1), accuracy: 8)
        #expect(moved.coordinate != nil && moved.horizontalAccuracy == 8 && moved.heading == nil && moved.headingAccuracy == nil)
    }
}
