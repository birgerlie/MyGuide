import MyGuideCore
import SwiftUI

/// The walking status line ("Paused · N buzzes" while walking mode is paused), refreshed every second so a stale fix
/// turns into "waiting for GPS", and the first thing that keeps walking mode from starting, in orange.
struct WalkingStatusPill: View {
    let controller: WalkingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                if let text = WalkingStatus.text(isOn: controller.isOn, lastFixAt: controller.lastFixAt,
                                                 buzzCount: controller.buzzCount, now: context.date, pause: controller.isPaused ? .auto : nil) {
                    pill(text, color: .white)
                }
                if let problem = controller.problems.first {
                    pill(problem, color: .orange)
                }
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }
}
