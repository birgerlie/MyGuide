import MyGuideCore
import PhotosUI
import SwiftUI

/// Adds photos picked from the library to the diary (spec 4.3). Nothing is sent to any service.
@MainActor
enum LibraryImport {
    /// Most photos one pick may select.
    static let maxSelection = 30

    /// What one pick did, for the summary alert.
    struct Summary: Equatable {
        var added = 0
        /// Neither the EXIF nor the library asset gives a capture time.
        var noDate = 0
        /// The library asset is stored already.
        var alreadyAdded = 0
        /// The photo could not be loaded, read or saved.
        var failed = 0

        var title: String { added == 1 ? "Added 1 photo" : "Added \(added) photos" }

        /// One line per kind of skip; empty when nothing was skipped.
        var message: String {
            var lines: [String] = []
            if noDate > 0 { lines.append("\(noDate) skipped (no date)") }
            if alreadyAdded > 0 { lines.append("\(alreadyAdded) already added") }
            if failed > 0 { lines.append("\(failed) couldn't be read") }
            return lines.joined(separator: "\n")
        }
    }

    private enum Outcome { case added, noDate, alreadyAdded, failed }

    /// Imports the items one at a time, in the order picked.
    static func run(_ items: [PhotosPickerItem], memory: MemoryStore) async -> Summary {
        var summary = Summary()
        for item in items {
            switch await importPhoto(item, memory: memory) {
            case .added: summary.added += 1
            case .noDate: summary.noDate += 1
            case .alreadyAdded: summary.alreadyAdded += 1
            case .failed: summary.failed += 1
            }
        }
        return summary
    }

    /// Time from the EXIF, else the asset's creation date; position from the EXIF, else the asset's location. The
    /// asset (and the read-access prompt) is only consulted when the EXIF lacks one of them.
    private static func importPhoto(_ item: PhotosPickerItem, memory: MemoryStore) async -> Outcome {
        // The identifier is what makes a second import of the same photo a no-op; without it the photo is not kept.
        guard let identifier = item.itemIdentifier else { return .failed }
        let loaded: Data?
        do {
            loaded = try await item.loadTransferable(type: Data.self)
        } catch {
            return .failed
        }
        guard let data = loaded, let metadata = PhotoMetadata.read(from: data) else { return .failed }

        var takenAt = metadata.takenAt
        var coordinate = metadata.coordinate
        if takenAt == nil || coordinate == nil, let asset = await PhotoImport.asset(identifier) {
            takenAt = takenAt ?? asset.creationDate
            if coordinate == nil {
                coordinate = asset.location.flatMap(PhotoImport.assetFix)?.coordinate
            }
        }
        guard let takenAt else { return .noDate }

        do {
            let id = try memory.importLibraryPhoto(jpeg: data, assetIdentifier: identifier, takenAt: takenAt,
                                                   coordinate: coordinate)
            return id == nil ? .alreadyAdded : .added
        } catch {
            AppServices.logMemoryFailure("library photo import failed", error)
            return .failed
        }
    }
}
