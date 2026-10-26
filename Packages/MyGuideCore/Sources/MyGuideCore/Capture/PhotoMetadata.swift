import Foundation
import ImageIO

/// What a library photo's EXIF tells us. Spec 8.1.1: such photos often carry GPS but no direction.
public struct PhotoMetadata: Sendable, Equatable {
    public var coordinate: Coordinate?
    public var heading: Double?
    public var takenAt: Date?
    /// Dimensions as displayed, after EXIF orientation (swapped for orientations 5...8).
    public var pixelWidth: Int
    public var pixelHeight: Int

    /// Spec 8.1.3 exception: EXIF headings get an assumed accuracy of 20 degrees.
    public static let assumedHeadingAccuracy = 20.0

    public init(coordinate: Coordinate?, heading: Double?, takenAt: Date?, pixelWidth: Int, pixelHeight: Int) {
        self.coordinate = coordinate
        self.heading = heading
        self.takenAt = takenAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// nil when `jpeg` is not a readable image.
    public static func read(from jpeg: Data) -> PhotoMetadata? {
        guard let size = ImageProcessing.pixelSize(of: jpeg),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return PhotoMetadata(coordinate: gps.flatMap(coordinate(from:)),
                             heading: gps.flatMap(heading(from:)),
                             takenAt: exif.flatMap(date(from:)),
                             pixelWidth: size.width, pixelHeight: size.height)
    }

    public func captureContext(fallbackDate: Date) -> CaptureContext {
        CaptureContext(coordinate: coordinate, horizontalAccuracy: nil,
                       heading: heading,
                       headingAccuracy: heading == nil ? nil : Self.assumedHeadingAccuracy,
                       horizontalFOV: FieldOfView.assumedHorizontalFOV(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
                       takenAt: takenAt ?? fallbackDate, source: .library)
    }

    private static func coordinate(from gps: [CFString: Any]) -> Coordinate? {
        guard let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
              lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return Coordinate(latitude: south ? -abs(lat) : abs(lat), longitude: west ? -abs(lon) : abs(lon))
    }

    private static func heading(from gps: [CFString: Any]) -> Double? {
        guard let value = (gps[kCGImagePropertyGPSImgDirection] as? NSNumber)?.doubleValue,
              value.isFinite, (0...360).contains(value) else { return nil }
        return value == 360 ? 0 : value
    }

    private static func date(from exif: [CFString: Any]) -> Date? {
        guard let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String).flatMap(timeZone(fromOffset:)) ?? .current
        return formatter.date(from: text)
    }

    /// Parses "+10:00" / "-03:30" (also "+1000"); nil for anything else.
    private static func timeZone(fromOffset text: String) -> TimeZone? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let digits = t.dropFirst().filter { $0 != ":" }
        guard digits.count == 4, digits.allSatisfy(\.isASCII), let value = Int(digits) else { return nil }
        let hours = value / 100, minutes = value % 100
        guard hours <= 18, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}
