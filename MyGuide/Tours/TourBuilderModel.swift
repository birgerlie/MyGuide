import CoreLocation
import Foundation
import ImageIO
import MyGuideCore
import Observation
import os
import UIKit

/// The «Turer» tab's planning flow (tours spec 5, 6): the owner picks a loop duration or a destination, «Lag tur»
/// finds the area's places (`TourPlaceSource`), picks the candidates (`TourCandidates`), plans (`TourPlanner`) and
/// checks the plan against walking routes (`TourRouter`), then shows the preview. «Fjern» removes a stop, re-orders
/// the rest and re-fits.
///
/// Planning can take minutes in the worst case (Overpass ≈ 90 s, routing ≈ 160 s), so every step shows a progress
/// line and can be cancelled. A cancelled run is discarded: each run has a generation, and a result whose generation
/// is no longer current, or whose task was cancelled, never reaches the screen, so a fit cut short by cancellation
/// (all straight legs) can never pass for an approximate tour.
@MainActor
@Observable
final class TourBuilderModel {
    enum Mode: Hashable { case loop, destination }

    /// What one «Lag tur» asked for, kept with the preview.
    enum Request: Equatable, Sendable {
        case loop(minutes: Int)
        case destination(TourDestination)
    }

    enum Step: Equatable { case locating, findingPlaces, routing }

    enum Failure: Equatable {
        case locationDenied, noPosition, placesFailed
        /// The destination is over `TourPlanner.maxDirectMetres` away in a straight line.
        case destinationTooFar
    }

    struct Preview {
        var request: Request
        var routed: RoutedTour
        /// The places found for the tour by id, for each stop's kind symbol and picture.
        var places: [String: Candidate]
        /// A source, or part of one, did not answer, so places may be missing.
        var partialSources: Bool
        /// How many stops the owner removed with «Fjern».
        var removedByOwner: Int
    }

    enum Phase {
        case choosing
        case planning(Step, since: Date)
        case failed(Failure)
        case preview(Preview)
    }

    /// Loop durations in minutes (global constraint).
    nonisolated static let durations = [30, 45, 60, 90, 120, 180]
    nonisolated static let defaultMinutes = 60
    /// How long «Lag tur» waits for a position before saying it found none.
    nonisolated static let positionWait: Duration = .seconds(15)
    /// A fix at least this accurate (metres) is taken at once; a poorer one only when the wait runs out.
    nonisolated static let goodAccuracy = 100.0
    nonisolated static let log = Logger(subsystem: "io.github.birgerlie.MyGuide", category: "tours")

    var mode: Mode = .loop { didSet { clearFailure() } }
    var minutes = TourBuilderModel.defaultMinutes { didSet { clearFailure() } }
    var destination: TourDestination? { didSet { clearFailure() } }
    private(set) var phase: Phase = .choosing
    /// True while «Fjern» re-fits the shown preview.
    private(set) var refitting = false
    /// Moves on when pictures of the shown stops may have reached the cache, so rows look again.
    private(set) var picturesVersion = 0
    /// The destination field's suggestions.
    let search = DestinationSearch()

    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let memory: MemoryStore
    @ObservationIgnored private let placeImages: PlaceImages
    @ObservationIgnored private let source: TourPlaceSource
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Bumped by every run, re-fit, cancel and close; work checks it before touching state.
    @ObservationIgnored private var generation = 0

    init(location: LocationProvider, memory: MemoryStore, placeImages: PlaceImages, source: TourPlaceSource) {
        self.location = location
        self.memory = memory
        self.placeImages = placeImages
        self.source = source
    }

    // MARK: - State for the screens

    /// The request «Lag tur» would make now; nil in destination mode without a destination.
    var request: Request? {
        switch mode {
        case .loop: .loop(minutes: minutes)
        case .destination: destination.map(Request.destination)
        }
    }

    var isPlanning: Bool {
        if case .planning = phase { return true }
        return false
    }

    var preview: Preview? {
        if case .preview(let preview) = phase { return preview }
        return nil
    }

    var canMakeTour: Bool { request != nil && !isPlanning }

    /// Whether the shared provider has a usable fix now (observed through `LocationProvider.location`).
    var hasFix: Bool { location.fix() != nil }

    /// The next longer loop duration, offered when no stop fits (spec 5); nil after the longest.
    nonisolated static func longerDuration(than minutes: Int) -> Int? {
        durations.first { $0 > minutes }
    }

    // MARK: - Actions

    func makeTour() {
        guard let request, !isPlanning else { return }
        run(request)
    }

    /// «Prøv 90 minutter»: the same loop with the next longer duration.
    func tryLonger() {
        guard case .preview(let preview) = phase, case .loop(let current) = preview.request,
              let longer = Self.longerDuration(than: current) else { return }
        mode = .loop
        minutes = longer
        run(.loop(minutes: longer))
    }

    /// Stops planning (back to choosing) or a re-fit (the preview stays as it was). The result is discarded.
    func cancel() {
        work?.cancel()
        work = nil
        generation += 1
        if refitting {
            refitting = false
        } else if isPlanning {
            phase = .choosing
        }
    }

    /// Leaves the preview (back, «Ny tur», after «Start turen»). Does nothing in other phases, so a navigation pop
    /// caused by a new run starting never cancels that run.
    func closePreview() {
        guard case .preview = phase else { return }
        work?.cancel()
        work = nil
        generation += 1
        refitting = false
        phase = .choosing
    }

    /// «Fjern»: the plan without the stop, re-ordered by 2-opt, re-fitted against walking routes. Legs that did not
    /// change are reused, not routed again.
    func remove(_ stopID: String) {
        guard case .preview(let preview) = phase, !refitting else { return }
        let plan = TourPlanner.removing(stopID, from: preview.routed.plan)
        guard plan != preview.routed.plan else { return }
        let earlier = preview.routed
        let token = begin()
        refitting = true
        work = Task {
            let routed = await TourRouter.fit(plan, reusing: earlier)
            guard self.isCurrent(token) else { return }
            var updated = preview
            updated.routed = routed
            updated.removedByOwner += 1
            self.refitting = false
            self.phase = .preview(updated)
            self.work = nil
        }
    }

    /// Steers the destination suggestions towards the owner's surroundings, once a fix exists; later calls do
    /// nothing, so the region does not jump while the owner types.
    func biasSearch() {
        guard !search.isBiased, let fix = location.fix() else { return }
        search.bias(around: fix.coordinate)
    }

    /// The stop's picture when it is in the cache, decoded as a thumbnail of at most `maxPixels` on its long side;
    /// nil otherwise (never fetched here).
    func cachedPicture(for stop: TourStop, in preview: Preview, maxPixels: Int) async -> UIImage? {
        guard let candidate = preview.places[stop.id], let title = PlaceImages.title(for: candidate),
              let stored = await placeImages.cached(wikipediaTitle: title) else { return nil }
        let url = stored.fileURL
        return await Task.detached(priority: .userInitiated) { Self.thumbnail(at: url, maxPixels: maxPixels) }.value
    }

    /// Decodes only what a thumbnail needs (a full Wikimedia picture can be several megapixels).
    nonisolated private static func thumbnail(at url: URL, maxPixels: Int) -> UIImage? {
        guard maxPixels > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: - Planning

    private func begin() -> Int {
        work?.cancel()
        generation += 1
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool {
        !Task.isCancelled && token == generation
    }

    private func clearFailure() {
        if case .failed = phase { phase = .choosing }
    }

    private func run(_ request: Request) {
        let token = begin()
        refitting = false
        phase = .planning(.locating, since: .now)
        work = Task { await self.plan(request, token: token) }
    }

    private func plan(_ request: Request, token: Int) async {
        guard let start = await currentPosition() else {
            guard isCurrent(token) else { return }
            phase = .failed(isLocationDenied ? .locationDenied : .noPosition)
            work = nil
            return
        }
        guard isCurrent(token) else { return }
        if case .destination(let destination) = request,
           !TourPlanner.isWithinWalkingRange(from: start, to: destination.coordinate) {
            phase = .failed(.destinationTooFar)
            work = nil
            return
        }
        phase = .planning(.findingPlaces, since: .now)

        let area: TourArea = switch request {
        case .loop(let minutes): .loop(from: start, minutes: minutes)
        case .destination(let destination): .corridor(from: start, to: destination.coordinate)
        }
        let search: TourPlaceSearch
        do {
            search = try await source.search(in: area, language: AppServices.currentStoryLanguage())
        } catch {
            guard isCurrent(token) else { return }
            AppServices.logNearbyFailure("tour places failed", error)
            phase = .failed(.placesFailed)
            work = nil
            return
        }
        guard isCurrent(token) else { return }
        if search.isPartial {
            Self.log.notice("tour places partial: osm failed \(search.osmFailed, privacy: .public), wiki tiles failed \(search.failedTiles, privacy: .public) of \(search.tileCount, privacy: .public), osm capped \(search.osmCapped, privacy: .public)")
        }

        let heard: Set<String>
        do {
            heard = try memory.heardPlaceIDs(since: Date.now.addingTimeInterval(-TourCandidates.heardWindow))
        } catch {
            // Without the heard places every place keeps its full score; the tour is still worth making.
            AppServices.logMemoryFailure("tour heard places failed", error)
            heard = []
        }
        phase = .planning(.routing, since: .now)
        let plan = await Self.plannedTour(request, from: start, places: search.places, area: area, heard: heard)
        guard isCurrent(token) else { return }
        let routed = await TourRouter.fit(plan)
        // A cancelled fit returns straight legs for everything it did not route; it must never be shown.
        guard isCurrent(token) else { return }

        var places: [String: Candidate] = [:]
        for place in search.places where places[place.candidate.id] == nil { places[place.candidate.id] = place.candidate }
        phase = .preview(Preview(request: request, routed: routed, places: places, partialSources: search.isPartial,
                                 removedByOwner: 0))
        work = nil
        prefetchPictures(of: routed.plan.stops, places: places)
    }

    /// Candidates and plan off the main actor: insertion over 2000 candidates takes about 0.2 s.
    nonisolated private static func plannedTour(_ request: Request, from start: Coordinate, places: [WalkingPlace],
                                                area: TourArea, heard: Set<String>) async -> TourPlan {
        await Task.detached(priority: .userInitiated) {
            let candidates = TourCandidates.select(places, in: area, heardWithin30Days: heard)
            switch request {
            case .loop(let minutes):
                return TourPlanner.loop(from: start, minutes: minutes, candidates: candidates)
            case .destination(let destination):
                return TourPlanner.aToB(from: start, to: destination.coordinate, candidates: candidates)
            }
        }.value
    }

    /// The owner's position: the first fix within `goodAccuracy`, or, when `positionWait` runs out, the latest usable
    /// fix however poor. While the owner has not yet answered the location prompt it keeps waiting, and the wait
    /// starts over once they have. Nil without any fix, when location is denied, or when cancelled. The shared
    /// provider runs while this tab is visible or a run is planning (HomeScreen).
    private func currentPosition() async -> Coordinate? {
        let clock = ContinuousClock()
        var deadline = clock.now + Self.positionWait
        while !Task.isCancelled {
            let fix = location.fix()
            if let fix, fix.accuracy <= Self.goodAccuracy { return fix.coordinate }
            if isLocationDenied { return nil }
            if location.authorization == .notDetermined { deadline = clock.now + Self.positionWait }
            if clock.now >= deadline { return fix?.coordinate }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private var isLocationDenied: Bool {
        location.authorization == .denied || location.authorization == .restricted
    }

    /// Fetches the stops' pictures into the shared cache in the background, so the preview (and later the tour's
    /// notifications) find them; the rows look again when it is done.
    private func prefetchPictures(of stops: [TourStop], places: [String: Candidate]) {
        let titles = stops.compactMap { places[$0.id].flatMap(PlaceImages.title(for:)) }
        guard !titles.isEmpty else { return }
        let placeImages = placeImages
        Task {
            await Task.detached(priority: .utility) { await placeImages.prefetch(titles) }.value
            // Looking again costs only cache reads, so any preview shown by then may look.
            if self.preview != nil { self.picturesVersion += 1 }
        }
    }
}
