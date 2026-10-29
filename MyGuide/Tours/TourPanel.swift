import MyGuideCore
import SwiftUI

/// The running tour in the «Rundt deg» sheet, in the place of «Gå en tur» (tours spec 6): «Neste: Pantheon · 300 m»
/// with «2 av 6», then «Tilbake til start» (or «Fram til målet») once every stop is done, and «Turen er ferdig · 6
/// stopp · 1 t 31 min» at the end; «Hopp over stopp» while a stop is next, and «Avslutt turen», which asks first while
/// stops remain. Ending the tour also ends walking mode. The walking panel, or «Fortsett turen», sits under it
/// (`AroundSheet`).
struct TourPanel: View {
    let walking: WalkingController
    let tour: ActiveTour
    /// The owner's position on the map, for the distance to the next stop; nil leaves the distance out.
    let position: Coordinate?
    let language: StoryLanguage

    @State private var confirmingEnd = false

    private var remaining: Int { tour.progress.total - tour.progress.done }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
            HStack(spacing: 12) {
                if !tour.isFinished, tour.next != nil {
                    Button {
                        walking.skipStop()
                    } label: {
                        Label(ToursTexts.skipStop(language), systemImage: "forward.end.fill")
                    }
                    .buttonStyle(.themeSecondary)
                }
                Button {
                    if !tour.isFinished, remaining > 0 { confirmingEnd = true } else { walking.endTour() }
                } label: {
                    Label(ToursTexts.endTour(language), systemImage: "stop.fill")
                }
                .buttonStyle(.themeSecondary)
            }
        }
        .foregroundStyle(Theme.Colour.text)
        .padding(Theme.Spacing.margin)
        .background(Theme.Colour.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Colour.stone))
        .confirmationDialog(ToursTexts.endTourQuestion(language), isPresented: $confirmingEnd,
                            titleVisibility: .visible) {
            Button(ToursTexts.endTour(language), role: .destructive) { walking.endTour() }
            Button(ToursTexts.keepGoing(language), role: .cancel) {}
        } message: {
            Text(ToursTexts.stopsLeft(remaining, language))
        }
    }

    @ViewBuilder
    private var status: some View {
        if tour.isFinished {
            Label(TourFormat.finished(stops: tour.visitedCount, seconds: tour.elapsedSeconds ?? 0, language: language),
                  systemImage: "flag.checkered")
                .font(Theme.Font.bodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.unit) {
                if let next = tour.next {
                    Label(TourFormat.nextStop(next.name, metres: position.map { GeoMath.distance($0, next.coordinate) },
                                              language: language),
                          systemImage: "mappin.and.ellipse")
                        .font(Theme.Font.bodyMedium)
                } else {
                    Label(ToursTexts.finalLeg(isLoop: tour.routed.plan.kind == .loop, language),
                          systemImage: tour.routed.plan.kind == .loop ? "arrow.uturn.backward" : "flag.checkered")
                        .font(Theme.Font.bodyMedium)
                }
                Spacer(minLength: 0)
                Text(TourFormat.progress(done: tour.progress.done, total: tour.progress.total, language: language))
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                    .opacity(0.75)
                    .accessibilityLabel(ToursTexts.progressLabel(done: tour.progress.done, total: tour.progress.total,
                                                                 language))
            }
        }
    }
}
