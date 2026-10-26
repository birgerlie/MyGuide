import Testing
import Foundation
@testable import MyGuideCore

@Suite struct ImageProcessingTests {
    @Test func targetSizeScalesLongSide() {
        // 4032x3024 → scale 1536/4032 = 0.380952; short 3024·0.380952 = 1152
        let landscape = ImageProcessing.targetSize(width: 4032, height: 3024, maxLongSide: 1536)
        #expect(landscape.width == 1536 && landscape.height == 1152)
        let portrait = ImageProcessing.targetSize(width: 3024, height: 4032, maxLongSide: 1536)
        #expect(portrait.width == 1152 && portrait.height == 1536)
        // never upscale
        let small = ImageProcessing.targetSize(width: 1000, height: 800, maxLongSide: 1536)
        #expect(small.width == 1000 && small.height == 800)
    }
    @Test func downscaleProducesTargetPixels() throws {
        let out = try ImageProcessing.downscaledJPEG(TestImages.jpeg(width: 4032, height: 3024), maxLongSide: 1536, quality: 0.7)
        let size = try #require(ImageProcessing.pixelSize(of: out))
        #expect(size.width == 1536 && size.height == 1152)
    }
    @Test func downscaleAppliesEXIFOrientation() throws {
        // iPhone portrait photos are stored landscape with orientation 6 (rotate 90° CW)
        let out = try ImageProcessing.downscaledJPEG(TestImages.jpeg(width: 4032, height: 3024, orientation: 6), maxLongSide: 1536, quality: 0.7)
        let size = try #require(ImageProcessing.pixelSize(of: out))
        #expect(size.width == 1152 && size.height == 1536)
    }
    @Test func garbageThrows() {
        #expect(throws: ImageProcessingError.unreadableImage) { try ImageProcessing.downscaledJPEG(Data([1, 2, 3]), maxLongSide: 100, quality: 0.7) }
    }
}
