import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PlaceImageFormatTests {
    @Test func recognisesPNGJPEGAndGIF() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let gif = Data("GIF89a".utf8)
        #expect(PlaceImageFormat(sniffing: png) == .png)
        #expect(PlaceImageFormat(sniffing: jpeg) == .jpeg)
        #expect(PlaceImageFormat(sniffing: gif) == .gif)
        #expect(PlaceImageFormat(sniffing: Data("GIF87a".utf8)) == .gif)
    }

    @Test func extensionsAndTypeIdentifiers() {
        #expect(PlaceImageFormat.png.fileExtension == "png")
        #expect(PlaceImageFormat.jpeg.fileExtension == "jpg")
        #expect(PlaceImageFormat.gif.fileExtension == "gif")
        #expect(PlaceImageFormat.png.typeIdentifier == "public.png")
        #expect(PlaceImageFormat.jpeg.typeIdentifier == "public.jpeg")
        #expect(PlaceImageFormat.gif.typeIdentifier == "com.compuserve.gif")
    }

    @Test func unknownOrShortBytesAreNil() {
        #expect(PlaceImageFormat(sniffing: Data()) == nil)
        // One byte short of each signature.
        #expect(PlaceImageFormat(sniffing: Data([0x89, 0x50, 0x4E])) == nil)
        #expect(PlaceImageFormat(sniffing: Data([0xFF, 0xD8])) == nil)
        #expect(PlaceImageFormat(sniffing: Data("GIF8".utf8)) == nil)
        // WebP ("RIFF....WEBP") and an HTML error page are not attachable.
        #expect(PlaceImageFormat(sniffing: Data("RIFF\0\0\0\0WEBP".utf8)) == nil)
        #expect(PlaceImageFormat(sniffing: Data("<!DOCTYPE html>".utf8)) == nil)
    }

    @Test func sniffsAFileByItsBytesNotItsName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlaceImageFormatTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The cache names every picture .jpg; this one holds PNG bytes.
        let file = dir.appendingPathComponent("x.jpg")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: file)
        #expect(PlaceImageFormat(contentsOf: file) == .png)
        #expect(PlaceImageFormat(contentsOf: dir.appendingPathComponent("missing.jpg")) == nil)
    }
}
