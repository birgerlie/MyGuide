import Foundation
import Testing
@testable import MyGuideCore

@Suite struct TestToneTests {
    @Test func headerAndLength() {
        // 1 s at 8000 Hz, 16-bit mono: 8000 samples · 2 bytes = 16000 data bytes; file = 44 + 16000 = 16044
        // 0.5 s at 8000 Hz: 4000 samples · 2 = 8000; file = 8044
        let one = TestTone.wavData(frequency: 880, duration: 1, sampleRate: 8000)
        #expect(one.count == 16044)
        #expect(TestTone.wavData(frequency: 880, duration: 0.5, sampleRate: 8000).count == 8044)
        #expect(String(decoding: one[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: one[8..<12], as: UTF8.self) == "WAVE")
        // RIFF chunk size = file − 8 = 16036; data chunk size = 16000 (little-endian UInt32 at 4 and 40)
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) } == 16036)
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) } == 16000)
        // Sample rate at 24, bits per sample at 34
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) } == 8000)
        #expect(one.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self) } == 16)
    }

    @Test func zeroOrNegativeDurationIsHeaderOnly() {
        #expect(TestTone.wavData(frequency: 880, duration: 0, sampleRate: 8000).count == 44)
        #expect(TestTone.wavData(frequency: 880, duration: -1, sampleRate: 8000).count == 44)
    }

    @Test func samplesAreASineAtThirtyPercentAmplitude() {
        // 2000 Hz at 8000 Hz is 4 samples per cycle: sample k = 0.3 · 32767 · sin(k · π/2).
        // k=0: 0; k=1: 0.3 · 32767 = 9830.1 -> 9830; k=2: sin(π) ≈ 0 -> 0; k=3: -9830.
        // Same tone at 1000 Hz (8 per cycle): k=1 is 0.3 · 32767 · sin(π/4) = 6951.0 -> 6951 (±1 for rounding).
        func samples(_ frequency: Double, count: Int) -> [Int] {
            let wav = TestTone.wavData(frequency: frequency, duration: Double(count) / 8000, sampleRate: 8000)
            return (0..<count).map { k in Int(wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44 + 2 * k, as: Int16.self) }) }
        }
        let fast = samples(2000, count: 4)
        #expect(fast[0] == 0)
        #expect(abs(fast[1] - 9830) <= 1)
        #expect(abs(fast[2]) <= 1)
        #expect(abs(fast[3] + 9830) <= 1)
        #expect(abs(samples(1000, count: 2)[1] - 6951) <= 1)
    }
}
