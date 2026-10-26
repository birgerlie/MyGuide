import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum TestImages {
    /// A solid-colour JPEG of the stored size `width`x`height`, with optional EXIF orientation, GPS and Exif dictionaries.
    static func jpeg(width: Int, height: Int, orientation: Int = 1,
                     gps: [CFString: Any]? = nil, exif: [CFString: Any]? = nil) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }

        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "test JPEG encode failed")
        return out as Data
    }
}
