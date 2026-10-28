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
        /// No EXIF time, and photo access is refused or limited so the asset's date cannot be read.
        var noAccess = 0
        /// The library asset is stored already.
        var alreadyAdded = 0
        /// The photo could not be loaded, read or saved.
        var failed = 0

        var title: String { added == 1 ? "Added 1 photo" : "Added \(added) photos" }

        /// One line per kind of skip; empty when nothing was skipped.
        var message: String {
            var lines: [String] = []
            if noDate > 0 { lines.append("\(noDate) skipped (no date)") }
            if noAccess > 0 { lines.append("\(noAccess) skipped: allow photo access in Settings") }
            if alreadyAdded > 0 { lines.append("\(alreadyAdded) already added") }
            if failed > 0 { lines.append("\(failed) couldn't be read") }
            return lines.joined(separator: "\n")
        }
    }

    private enum Outcome { case added, noDate, noAccess, alreadyAdded, failed }

    /// What is read from a picked photo off the main actor: its EXIF (from the original, which still has it) and
    /// a copy at the diary's stored size, so the store's own downscale only handles a small image.
    private struct Prepared: Sendable {
        let metadata: PhotoMetadata
        let jpeg: Data
    }

    /// Imports the items one at a time, in the order picked. Stops between items when the task is cancelled;
    /// photos already saved stay saved.
    static func run(_ items: [PhotosPickerItem], memory: MemoryStore) async -> Summary {
        var summary = Summary()
        for item in items {
            if Task.isCancelled { break }
            switch await importPhoto(item, memory: memory) {
            case .added: summary.added += 1
            case .noDate: summary.noDate += 1
            case .noAccess: summary.noAccess += 1
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
        // Checked before anything is loaded, so a photo added before costs no work and never asks for access.
        do {
            if try memory.hasLibraryPhoto(assetIdentifier: identifier) { return .alreadyAdded }
        } catch {
            AppServices.logMemoryFailure("library photo lookup failed", error)
            return .failed
        }
        let loaded: Data?
        do {
            loaded = try await item.loadTransferable(type: Data.self)
        } catch {
            return .failed
        }
        guard let data = loaded, let prepared = await prepare(data) else { return .failed }

        var takenAt = prepared.metadata.takenAt
        var coordinate = prepared.metadata.coordinate
        var lookup: PhotoImport.AssetLookup?
        if takenAt == nil || coordinate == nil {
            let found = await PhotoImport.asset(identifier)
            lookup = found
            if let asset = found.info {
                takenAt = takenAt ?? asset.creationDate
                if coordinate == nil {
                    coordinate = asset.location.flatMap(PhotoImport.assetFix)?.coordinate
                }
            }
        }
        guard let takenAt else {
            if case .noAccess = lookup { return .noAccess }
            return .noDate
        }

        do {
            let id = try memory.importLibraryPhoto(jpeg: prepared.jpeg, assetIdentifier: identifier,
                                                   takenAt: takenAt, coordinate: coordinate)
            return id == nil ? .alreadyAdded : .added
        } catch {
            AppServices.logMemoryFailure("library photo import failed", error)
            return .failed
        }
    }

    /// Reads the EXIF and downscales on a background thread. Nil for an unreadable image.
    private static func prepare(_ data: Data) async -> Prepared? {
        let longSide = MemoryStore.libraryPhotoLongSide
        let quality = MemoryStore.libraryJPEGQuality
        return await Task.detached(priority: .userInitiated) { () -> Prepared? in
            guard let metadata = PhotoMetadata.read(from: data),
                  let jpeg = try? ImageProcessing.downscaledJPEG(data, maxLongSide: longSide, quality: quality)
            else { return nil }
            return Prepared(metadata: metadata, jpeg: jpeg)
        }.value
    }
}
