import CoreLocation
import MyGuideCore
import Photos
import PhotosUI
import SwiftUI

/// Turns a photo picked from the library into the bytes and capture context a story needs. Shared by the Home
/// screen and the camera screen, which both offer the picker.
enum PhotoImport {
    struct Loaded {
        let data: Data
        let capture: CaptureContext
    }

    /// The failure text is what the alert shows.
    struct Failure: Error {
        let text: String
    }

    static func load(_ item: PhotosPickerItem) async -> Result<Loaded, Failure> {
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            return .failure(Failure(text: "Couldn't load the photo from your library."))
        }
        guard let data, let metadata = PhotoMetadata.read(from: data) else {
            return .failure(Failure(text: UserFacingMessage.message(for: ImageProcessingError.unreadableImage)))
        }
        var capture = metadata.captureContext(fallbackDate: .now)
        if capture.coordinate == nil, let identifier = item.itemIdentifier,
           let assetLocation = await assetLocation(identifier),
           let fix = assetFix(assetLocation) {
            // Position only; the EXIF heading (if any) still describes this photo, PHAsset adds none.
            capture.coordinate = fix.coordinate
            capture.horizontalAccuracy = fix.accuracy
        }
        return .success(Loaded(data: data, capture: capture))
    }

    /// The library asset's location, after asking for read access. Nil if access is refused or there is none.
    private static func assetLocation(_ identifier: String) async -> CLLocation? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.location
    }

    /// A library location has no age limit (the photo may be old), but sentinel values still mean "no position".
    private static func assetFix(_ location: CLLocation) -> (coordinate: Coordinate, accuracy: Double?)? {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              !(location.coordinate.latitude == 0 && location.coordinate.longitude == 0) else { return nil }
        let accuracy = location.horizontalAccuracy
        return (Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                accuracy >= 0 && accuracy.isFinite ? accuracy : nil)
    }
}
