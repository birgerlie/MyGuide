import Foundation

/// What the guide server says is left after a call (spec 8): `X-MyGuide-Free-Left: story=12,speech=40,image=4`
/// and `X-MyGuide-Credits: 37`.
public struct ServerAllowance: Sendable, Equatable, Codable {
    /// Free calls left today per kind (`story`, `speech`, `image`).
    public var freeLeft: [String: Int]
    public var credits: Int?

    public init(freeLeft: [String: Int], credits: Int?) {
        self.freeLeft = freeLeft
        self.credits = credits
    }

    /// Parses `HTTPURLResponse.allHeaderFields`. Header names match case-insensitively; spaces around names and
    /// numbers are ignored; a pair or a credits value that is not a name and a non-negative integer is skipped.
    /// Nil when neither header gives anything.
    public init?(headers: [AnyHashable: Any]) {
        var freeText: String?
        var creditsText: String?
        for (key, value) in headers {
            guard let name = (key.base as? String)?.lowercased(), let text = value as? String else { continue }
            switch name {
            case "x-myguide-free-left": freeText = text
            case "x-myguide-credits": creditsText = text
            default: break
            }
        }

        var freeLeft: [String: Int] = [:]
        for pair in (freeText ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let kind = parts[0].trimmingCharacters(in: .whitespaces)
            guard !kind.isEmpty, let count = Self.count(parts[1]) else { continue }
            freeLeft[kind] = count
        }
        let credits = creditsText.flatMap { Self.count($0) }

        guard !freeLeft.isEmpty || credits != nil else { return nil }
        self.init(freeLeft: freeLeft, credits: credits)
    }

    private static func count(_ text: some StringProtocol) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }
}
