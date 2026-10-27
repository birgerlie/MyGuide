import Foundation
import Testing
@testable import MyGuideCore

@Suite struct BuzzLogExportTests {
    // 2026-10-27T09:00:00Z: 1970–2025 = 56·365 + 14 leap days = 20 454 days; Jan–Sep 2026 = 273, + 26 → 299;
    // 20 753 days · 86 400 = 1 793 059 200 s; + 9 h (32 400 s) = 1 793 091 600.
    static func e(_ kind: String, _ outcome: BuzzOutcome, name: String = "P", level: Int = 0, at: TimeInterval = 0,
                  distance: Double = 47.6) -> BuzzLogEntry {
        BuzzLogEntry(id: UUID(), at: Date(timeIntervalSince1970: 1_793_091_600 + at), placeID: "osm:node/1", placeName: name,
                     kind: kind, tier: 2, distance: distance, outcome: outcome, deepestLevel: level)
    }

    @Test func counts() {
        let log = [Self.e("historic=memorial", .skipped), Self.e("historic=memorial", .heard, level: 1),
                   Self.e("amenity=place_of_worship", .ignored), Self.e("historic=memorial", .pending)]
        #expect(BuzzLogExport.counts(log) == [
            KindCount(kind: "historic=memorial", buzzes: 3, heard: 1, skipped: 1, ignored: 0),
            KindCount(kind: "amenity=place_of_worship", buzzes: 1, heard: 0, skipped: 0, ignored: 1),
        ])
        #expect(BuzzLogExport.counts([]).isEmpty)
    }

    @Test func countsTieBreaksByKind() {
        let log = [Self.e("b", .heard), Self.e("a", .heard)]
        #expect(BuzzLogExport.counts(log).map(\.kind) == ["a", "b"])
    }

    @Test func csv() {
        // 1 793 091 600 s = 2026-10-27T09:00:00Z (see helper); distance 47.6 → 48
        let csv = BuzzLogExport.csv([Self.e("historic=castle", .heard, name: "Hofburg, \"old\" palace", level: 2)])
        #expect(csv == "time,place,kind,tier,distance_m,outcome,level\n2026-10-27T09:00:00Z,\"Hofburg, \"\"old\"\" palace\",historic=castle,2,48,heard,2\n")
        #expect(BuzzLogExport.csv([]) == "time,place,kind,tier,distance_m,outcome,level\n")
    }

    @Test func csvRowsAndRounding() {
        // +900 s = 09:15:00; distance 47.4 → 47, 0.4 → 0; a newline in a name is quoted; a plain name is not
        let csv = BuzzLogExport.csv([Self.e("k", .pending, name: "Line\nbreak", at: 900, distance: 47.4),
                                     Self.e("k", .skipped, name: "Plain", distance: 0.4)])
        #expect(csv == "time,place,kind,tier,distance_m,outcome,level\n"
                + "2026-10-27T09:15:00Z,\"Line\nbreak\",k,2,47,pending,0\n"
                + "2026-10-27T09:00:00Z,Plain,k,2,0,skipped,0\n")
    }
}
