import Foundation

/// Where a place lies relative to the way the user faces, in the bands of `GuideText.side`.
public enum RelativeDirection: Sendable, Equatable {
    case ahead, aheadLeft, aheadRight, left, right, behindLeft, behindRight, behind

    /// Bands of GuideText.side: |r| ≤ 30 ahead; ≤ 60 ahead-left/right; ≤ 120 left/right; ≤ 150 behind-left/right; else behind.
    /// `offset` is wrapped into (−180, 180] first, so 350 means −10. Not finite → behind (never claims "ahead").
    public init(offset: Double) {
        guard offset.isFinite else { self = .behind; return }
        let r = PlaceSelector.offset(heading: 0, bearing: offset)
        let right = r > 0
        switch abs(r) {
        case ...30: self = .ahead
        case ...60: self = right ? .aheadRight : .aheadLeft
        case ...120: self = right ? .right : .left
        case ...150: self = right ? .behindRight : .behindLeft
        default: self = .behind
        }
    }

    public func words(_ language: StoryLanguage) -> String {
        switch language {
        case .norwegian:
            switch self {
            case .ahead: "foran deg"
            case .aheadLeft: "foran til venstre"
            case .aheadRight: "foran til høyre"
            case .left: "til venstre for deg"
            case .right: "til høyre for deg"
            case .behindLeft: "bak deg til venstre"
            case .behindRight: "bak deg til høyre"
            case .behind: "bak deg"
            }
        case .english:
            switch self {
            case .ahead: "ahead"
            case .aheadLeft: "ahead to the left"
            case .aheadRight: "ahead to the right"
            case .left: "to your left"
            case .right: "to your right"
            case .behindLeft: "behind you to the left"
            case .behindRight: "behind you to the right"
            case .behind: "behind you"
            }
        }
    }
}

public enum AroundText {
    /// "50 m · foran deg"; without `relative`: "i nærheten · 50 m" / "nearby · 50 m".
    public static func whereLine(distance: Double, relative: Double?, language: StoryLanguage) -> String {
        let d = BuzzText.roundedDistance(distance)
        guard let relative else {
            return language == .norwegian ? "i nærheten · \(d) m" : "nearby · \(d) m"
        }
        return "\(d) m · \(RelativeDirection(offset: relative).words(language))"
    }
}

extension BuzzText {
    /// "50 m foran deg" / "50 m til høyre" / "50 m til venstre" / "90 m bak deg" / "50 m unna"; English as `detail`.
    /// Uses the same four bands and boundaries as `detail`.
    public static func localizedDetail(distance: Double, bearing: Double, course: Double?, language: StoryLanguage) -> String {
        let english = detail(distance: distance, bearing: bearing, course: course)
        guard language == .norwegian else { return english }
        let d = roundedDistance(distance)
        // Map by the English suffix so the bands can never drift from `detail`.
        if english.hasSuffix(" away") { return "\(d) m unna" }
        if english.hasSuffix(" ahead") { return "\(d) m foran deg" }
        if english.hasSuffix(" right") { return "\(d) m til høyre" }
        if english.hasSuffix(" left") { return "\(d) m til venstre" }
        return "\(d) m bak deg"
    }
}
