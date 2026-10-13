@preconcurrency import AVFoundation
import Foundation

/// Canonical PCM audio: Float32, mono, 24 000 Hz. A Sendable value type so it can cross actors;
/// `PlaybackEngine` converts to `AVAudioPCMBuffer` at the edge (decision D-28).
public struct PCMBuffer: Sendable, Equatable {
    public static let sampleRate: Double = 24_000
    public var samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public init(frameCount: Int, fill: Float = 0) {
        samples = [Float](repeating: fill, count: frameCount)
    }

    public var frameCount: Int { samples.count }
    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public var isEmpty: Bool { samples.isEmpty }

    public func scaled(by gain: Float) -> PCMBuffer {
        PCMBuffer(samples: samples.map { $0 * gain })
    }
}

public enum PCMFormat {
    public static let sampleRate: Double = 24_000

    public static var canonical: AVAudioFormat {
        // swiftlint:disable:next force_unwrapping
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Converts any `AVAudioPCMBuffer` to the canonical format and wraps it.
    public static func canonicalBuffer(from buffer: AVAudioPCMBuffer, converter cache: inout AVAudioConverter?) -> PCMBuffer? {
        let format = buffer.format
        if format.sampleRate == sampleRate, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 {
            return PCMBuffer(avBuffer: buffer)
        }
        if cache == nil || cache?.inputFormat != format {
            cache = AVAudioConverter(from: format, to: canonical)
        }
        guard let converter = cache else { return nil }
        let ratio = sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error { return nil }
        return PCMBuffer(avBuffer: out)
    }

    public static func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let v = Int16(bitPattern: lo | (hi << 8))
                out[i] = Float(v) / 32768
            }
        }
        return out
    }
}

extension PCMBuffer {
    /// Reads a canonical-format `AVAudioPCMBuffer` (Float32 mono).
    public init(avBuffer: AVAudioPCMBuffer) {
        let n = Int(avBuffer.frameLength)
        if let ch = avBuffer.floatChannelData, n > 0 {
            samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        } else {
            samples = []
        }
    }

    public func makeAVBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: PCMFormat.canonical, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { src in
            ch[0].update(from: src.baseAddress!, count: samples.count)  // swiftlint:disable:this force_unwrapping
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
