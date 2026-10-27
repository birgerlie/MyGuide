import Foundation

/// A generated sine tone as a WAV file, for checking that audio can start from the background.
public enum TestTone {
    /// 16-bit mono PCM WAV at 0.3 of full scale. A duration of zero or less gives a header-only file.
    public static func wavData(frequency: Double, duration: Double, sampleRate: Int) -> Data {
        let count = max(0, Int(duration * Double(sampleRate)))
        let dataSize = UInt32(count * 2)
        var data = Data(capacity: 44 + count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                       // fmt chunk size
        append(UInt16(1))                        // PCM
        append(UInt16(1))                        // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))           // byte rate
        append(UInt16(2))                        // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for k in 0..<count {
            let value = 0.3 * Double(Int16.max) * sin(2 * .pi * frequency * Double(k) / Double(sampleRate))
            append(Int16(value.rounded()))
        }
        return data
    }
}
