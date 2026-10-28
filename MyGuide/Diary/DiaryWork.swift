import MyGuideCore
import Observation
import PhotosUI
import SwiftUI

/// The diary's long-running work: the one photo import and the open day stories. It lives in `AppServices`, not in
/// the screens, because a screen covered by a pushed walk story disappears without leaving the stack; its work must
/// go on and its result must be there when it comes back. Home stops the work when its route leaves the stack.
@MainActor
@Observable
final class DiaryWork {
    /// The summary of an import that finished but has not been shown yet; the diary takes it when it is on screen.
    private(set) var importSummary: LibraryImport.Summary?
    /// Observed mirror of the import task.
    private(set) var isImporting = false

    @ObservationIgnored private var importTask: Task<Void, Never>? {
        didSet { isImporting = importTask != nil }
    }
    /// One model per day key on the stack, so a rebuilt screen joins its day's running write. Not observed: screens
    /// look models up while building their body.
    @ObservationIgnored private var dayStories: [String: DayStoryModel] = [:]

    // MARK: - Import

    /// Imports the picked photos; ignored while an import runs. The summary is kept until `takeImportSummary()`.
    func startImport(_ items: [PhotosPickerItem], memory: MemoryStore) {
        guard importTask == nil, !items.isEmpty else { return }
        importSummary = nil
        importTask = Task {
            let summary = await LibraryImport.run(items, memory: memory)
            // Cancelled: the diary left the stack, and `cancelImport()` has already cleared the task.
            guard !Task.isCancelled else { return }
            importTask = nil
            importSummary = summary
        }
    }

    /// The finished import's summary, once; nil when there is none.
    func takeImportSummary() -> LibraryImport.Summary? {
        defer { importSummary = nil }
        return importSummary
    }

    /// Stops a running import between photos (those saved stay saved) and drops an unshown summary.
    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importSummary = nil
    }

    // MARK: - Day stories

    /// The day's model, made on first use and kept until its route leaves the stack (`keepDayStories`).
    func dayStory(_ dayKey: String, services: AppServices) -> DayStoryModel {
        if let model = dayStories[dayKey] { return model }
        let model = DayStoryModel(dayKey: dayKey, services: services)
        dayStories[dayKey] = model
        return model
    }

    /// Cancels and forgets every day story model whose key is not in `dayKeys`.
    func keepDayStories(_ dayKeys: Set<String>) {
        for (key, model) in dayStories where !dayKeys.contains(key) {
            model.cancel()
            dayStories[key] = nil
        }
    }
}
