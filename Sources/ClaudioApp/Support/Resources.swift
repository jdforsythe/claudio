import AVFoundation
import ClaudioCore
import Foundation

/// Loads chime sounds into canonical PCM, with a synthesized fallback when the resource is missing (document 10 §14).
enum ChimeResources {
    static func load() -> [Chime: PCMBuffer] {
        var out: [Chime: PCMBuffer] = [:]
        for chime in Chime.allCases {
            if let url = resourceURL(chime), let buffer = decode(url) {
                out[chime] = buffer
            } else {
                Log.ui.notice("chime resource missing for \(chime.rawValue); using synthesized tone")
                out[chime] = synthesized(chime)
            }
        }
        return out
    }

    private static func resourceURL(_ chime: Chime) -> URL? {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: chime.resourceName, withExtension: "aiff", subdirectory: "sounds"),
            Bundle.module.url(forResource: chime.resourceName, withExtension: "wav", subdirectory: "sounds"),
            Bundle.main.url(forResource: chime.resourceName, withExtension: "aiff"),
        ]
        return candidates.compactMap { $0 }.first
    }

    private static func decode(_ url: URL) -> PCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: raw)) != nil else { return nil }
        var converter: AVAudioConverter?
        return PCMFormat.canonicalBuffer(from: raw, converter: &converter)
    }

    /// Short two-tone chimes so the app works even without bundled sounds.
    static func synthesized(_ chime: Chime) -> PCMBuffer {
        let (f1, f2, seconds): (Float, Float, Double) = switch chime {
        case .finished: (880, 1320, 0.35)
        case .attention: (660, 880, 0.45)
        case .switched: (523, 784, 0.3)
        case .tick: (330, 330, 0.12)
        }
        let n = Int(seconds * PCMBuffer.sampleRate)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / Float(PCMBuffer.sampleRate)
            let f = i < n / 2 ? f1 : f2
            let env = Float(min(1, Double(n - i) / Double(n) * 3))
            samples[i] = sinf(2 * .pi * f * t) * 0.25 * env
        }
        return PCMBuffer(samples: samples)
    }
}
