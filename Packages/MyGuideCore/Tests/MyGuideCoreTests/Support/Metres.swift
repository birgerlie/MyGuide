import Foundation
@testable import MyGuideCore

/// metres per degree on the equator = 6 371 000 · π / 180 = 111 194.93
extension Coordinate {
    static func at(north: Double = 0, east: Double = 0) -> Coordinate {
        Coordinate(latitude: north / 111_194.93, longitude: east / 111_194.93)
    }
}
