import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ImageProcessingError: Error, Equatable {
    case unreadableImage, encodeFailed
}

public enum ImageProcessing {
    /// Scales so the long side is at most `maxLongSide`, preserving aspect ratio. Never upscales.
    public static func targetSize(width: Int, height: Int, maxLongSide: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard width > 0, height > 0, maxLongSide > 0, longSide > maxLongSide else { return (width, height) }
        let scale = Double(maxLongSide) / Double(longSide)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Pixel size as displayed, i.e. after applying the EXIF orientation (width and height swap for 5...8).
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// Decodes, applies the EXIF orientation, shrinks to `maxLongSide` and re-encodes as JPEG.
    /// The output carries no EXIF metadata (so no GPS leaves the device) and is already upright.
    public static func downscaledJPEG(_ data: Data, maxLongSide: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = pixelSize(of: data) else { throw ImageProcessingError.unreadableImage }
        let target = targetSize(width: size.width, height: size.height, maxLongSide: maxLongSide)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageProcessingError.unreadableImage
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.encodeFailed
        }
        let lossy: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))]
        CGImageDestinationAddImage(destination, image, lossy as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.encodeFailed }
        return out as Data
    }
}
