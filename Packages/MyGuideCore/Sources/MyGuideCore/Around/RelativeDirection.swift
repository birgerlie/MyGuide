import Foundation

/// Where a place lies relative to the way the user faces (or walks): the screen's words and the prompts' side.
public enum RelativeDirection: Sendable, Equatable {
    case ahead, aheadLeft, aheadRight, left, right, behindLeft, behindRight, behind

    /// |r| ≤ 30 ahead; ≤ 60 ahead-left/right; ≤ 120 left/right; ≤ 150 behind-left/right; else behind; r > 0 is right.
    /// `offset` is wrapped into (−180, 180] first, so 350 means −10. Not finite → behind (never claims "ahead").
    public init(offset: Double) {
        guard offset.isFinite else { self = .behind; return }
        let r = GeoMath.signedOffset(from: 0, to: offset)
        let right = r > 0
        switch abs(r) {
        case ...30: self = .ahead
        case ...60: self = right ? .aheadRight : .aheadLeft
        case ...120: self = right ? .right : .left
        case ...150: self = right ? .behindRight : .behindLeft
        default: self = .behind
        }
    }

    /// The English side the prompts send to the model ("behind-left"), as `GuideText.side`. Kept as is: the model
    /// reads it.
    public var promptWord: String {
        switch self {
        case .ahead: "ahead"
        case .aheadLeft: "ahead-left"
        case .aheadRight: "ahead-right"
        case .left: "to your left"
        case .right: "to your right"
        case .behindLeft: "behind-left"
        case .behindRight: "behind-right"
        case .behind: "behind"
        }
    }

    /// The words on screen: "bak deg til venstre" / "behind you to the left".
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

    /// How old the shown list is, once it is older than `staleListAge` (spec 5): "Steder fra for 12 min siden" /
    /// "Places from 12 min ago". Whole minutes under two hours, whole hours under two days, then whole days, all
    /// rounded down. nil up to `staleListAge`, and for an unknown age (nil, negative or not finite).
    public static func listAgeLine(seconds: TimeInterval?, language: StoryLanguage) -> String? {
        guard let seconds, seconds.isFinite, seconds > staleListAge else { return nil }
        let nb = language == .norwegian
        // Clamped before converting, so a huge age cannot trap in Int(_:).
        let minutes = Int(min(seconds, 1_000_000_000) / 60)
        let age: String
        if minutes < 120 {
            age = "\(minutes) min"
        } else if minutes < 48 * 60 {
            age = "\(minutes / 60) \(nb ? "timer" : "hours")"
        } else {
            age = "\(minutes / (24 * 60)) \(nb ? "dager" : "days")"
        }
        return nb ? "Steder fra for \(age) siden" : "Places from \(age) ago"
    }

    /// A list older than this (seconds) is marked with its age: 10 × 60.
    public static let staleListAge: TimeInterval = 600
}
