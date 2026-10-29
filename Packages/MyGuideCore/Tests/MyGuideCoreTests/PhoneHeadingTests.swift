import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PhoneHeadingTests {
    @Test func azimuthFlatUprightTiltedDegenerate() throws {
        // Flat, top edge east, back down: top (0,1,0) + back (0,0,−1) → horizontal (n 0, e 1) → atan2(1, 0) = 90°.
        let flat = try #require(PhoneHeading.azimuth(top: Vector3(north: 0, east: 1, up: 0), back: Vector3(north: 0, east: 0, up: -1)))
        #expect(abs(flat - 90) < 1e-9)
        // Upright facing north: top (0,0,1) + back (1,0,0) → (1, 0) → 0°.
        let upright = try #require(PhoneHeading.azimuth(top: Vector3(north: 0, east: 0, up: 1), back: Vector3(north: 1, east: 0, up: 0)))
        #expect(abs(upright) < 1e-9)
        // 45° tilt facing south: top (−0.707,0,0.707) + back (−0.707,0,−0.707) → (−1.414, 0) → 180°.
        let south = try #require(PhoneHeading.azimuth(top: Vector3(north: -0.707, east: 0, up: 0.707), back: Vector3(north: -0.707, east: 0, up: -0.707)))
        #expect(abs(south - 180) < 1e-9)
        // Facing west: top (0,0,1) + back (0,−1,0) → (0, −1) → atan2(−1, 0) = −90° → 270°.
        let west = try #require(PhoneHeading.azimuth(top: Vector3(north: 0, east: 0, up: 1), back: Vector3(north: 0, east: -1, up: 0)))
        #expect(abs(west - 270) < 1e-9)
        // Degenerate: top (0,0,1) + back (0,0,−1) → (0,0), length 0 < 0.25 → nil.
        #expect(PhoneHeading.azimuth(top: Vector3(north: 0, east: 0, up: 1), back: Vector3(north: 0, east: 0, up: -1)) == nil)
    }

    @Test func azimuthLengthBoundary() {
        // Horizontal length 0.24 < 0.25 → nil; 0.26 ≥ 0.25 → value (0°).
        let zero = Vector3(north: 0, east: 0, up: 0)
        #expect(PhoneHeading.azimuth(top: Vector3(north: 0.24, east: 0, up: 1), back: zero) == nil)
        #expect(PhoneHeading.azimuth(top: Vector3(north: 0.26, east: 0, up: 1), back: zero) == 0)
        // Non-finite input → nil.
        #expect(PhoneHeading.azimuth(top: Vector3(north: .nan, east: 1, up: 0), back: zero) == nil)
    }

    @Test func smoothingAcrossNorth() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // τ = 0.5, Δt = 0.5 → α = 1 − e^(−1) = 0.6321. 350 then 10 (+20 across north) → 350 + 0.6321·20 = 362.64 → 2.64.
        var a = HeadingSmoother()
        #expect(a.add(350, at: t0) == 350)    // first sample passes through
        let r = a.add(10, at: t0.addingTimeInterval(0.5))
        #expect(abs(r - 2.64) < 0.01)
        // Δt = 0.25 → α = 1 − e^(−0.5) = 0.3935: 0 then 90 → 0.3935·90 = 35.41.
        var b = HeadingSmoother()
        _ = b.add(0, at: t0)
        let s = b.add(90, at: t0.addingTimeInterval(0.25))
        #expect(abs(s - 35.41) < 0.01)
    }

    @Test func alternatingAcrossNorthStaysNearNorth() {
        var s = HeadingSmoother()
        var t = Date(timeIntervalSince1970: 0)
        var out = s.add(355, at: t)
        for i in 0..<40 {
            t = t.addingTimeInterval(0.1)
            out = s.add(i % 2 == 0 ? 5 : 355, at: t)
            // Always within 10° of north (the inputs are ±5°), never near 180.
            let off = abs(PlaceSelector.offset(heading: 0, bearing: out))
            #expect(off <= 10)
            #expect(out >= 0 && out < 360)
        }
    }

    @Test func edgeCases() {
        let t0 = Date(timeIntervalSince1970: 0)
        var s = HeadingSmoother()
        _ = s.add(90, at: t0)
        // Same instant or time going backwards: α = 0, heading unchanged.
        #expect(abs(s.add(200, at: t0) - 90) < 1e-9)
        #expect(abs(s.add(200, at: t0.addingTimeInterval(-5)) - 90) < 1e-9)
        // Non-finite sample ignored.
        #expect(abs(s.add(.nan, at: t0.addingTimeInterval(1)) - 90) < 1e-9)
        // A long gap (Δt = 50 ≫ τ → α ≈ 1) lands on the new heading, normalised from 725 → 5.
        let far = s.add(725, at: t0.addingTimeInterval(60))
        #expect(abs(far - 5) < 0.01)
        // Exactly opposite headings (180° apart) still resolve to a finite value in 0..<360.
        var o = HeadingSmoother()
        _ = o.add(0, at: t0)
        let v = o.add(180, at: t0.addingTimeInterval(0.5))
        #expect(v.isFinite && v >= 0 && v < 360)
    }
}
