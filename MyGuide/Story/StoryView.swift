import MyGuideCore
import SwiftUI
import UIKit

/// One photo's story: spinner while working, then thumbnail, title, text and badges; or the error with Retry.
struct StoryView: View {
    let model: StoryViewModel
    let location: LocationProvider

    var body: some View {
        content
            .navigationTitle("Story")
            .navigationBarTitleDisplayMode(.inline)
            // Leaving the screen cancels the work; the cancellation is never shown as an error.
            .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .working(let text):
            VStack(spacing: 16) {
                ProgressView()
                Text(text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .showing:
            if let session = model.session {
                story(session)
            }
        case .failed(let message, let canUseCurrentPosition):
            failure(message: message, canUseCurrentPosition: canUseCurrentPosition)
        }
    }

    private func story(_ session: StorySession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = UIImage(data: session.thumbnailJPEG) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(session.identified.title)
                    .font(.title2.bold())
                ForEach(Self.badges(for: session), id: \.self) { badge in
                    Label(badge, systemImage: "questionmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text(session.levels.first ?? "")
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding()
        }
    }

    private func failure(message: String, canUseCurrentPosition: Bool) -> some View {
        VStack(spacing: 20) {
            Text(message)
                .multilineTextAlignment(.center)
            if canUseCurrentPosition {
                let fix = location.fix()
                Button("Use where I am now") {
                    guard let fix = location.fix() else { return }
                    model.useCurrentPosition(fix.coordinate, accuracy: fix.accuracy)
                }
                .buttonStyle(.borderedProminent)
                .disabled(fix == nil)
                if fix == nil {
                    Text("Waiting for a GPS fix…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Retry") { model.retry() }
                .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Spec 8.1.5: label uncertainty about the subject and missing grounding.
    static func badges(for session: StorySession) -> [String] {
        var badges: [String] = []
        switch session.identified.confidence {
        case .certain: break
        case .likely: badges.append("Probably \(session.identified.subject)")
        case .unsure: badges.append("Not sure: \(session.identified.subject)?")
        }
        if !session.grounding.failedSources.isEmpty {
            badges.append("Less certain: map data unavailable")
        }
        return badges
    }
}
