import Foundation

/// The format of a cached place picture, read from its first bytes. The cache names every picture `.jpg`, but
/// Wikipedia serves PNG thumbnails for SVG and PNG files and GIF for GIF files, and a notification attachment needs
/// the real type.
public enum PlaceImageFormat: Sendable, Equatable {
    case png, jpeg, gif

    /// nil for any other bytes (WebP, an error page, a truncated file).
    public init?(sniffing data: Data) {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            self = .png
        } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else {
            return nil
        }
    }

    /// The format of the file at `url` by its first bytes; nil when it cannot be read or is not one of these.
    public init?(contentsOf url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8) else { return nil }
        self.init(sniffing: head)
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        }
    }

    /// The uniform type identifier (`UTType.png.identifier` and so on), for
    /// `UNNotificationAttachmentOptionsTypeHintKey`.
    public var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .gif: "com.compuserve.gif"
        }
    }
}
