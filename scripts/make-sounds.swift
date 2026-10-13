// Generates the event chimes as 24 kHz mono AIFF files. Usage: swift make-sounds.swift <outdir>
import AVFoundation
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
let specs: [(String, [(Float, Double)])] = [
    ("finished", [(880, 0.16), (1320, 0.22)]),
    ("attention", [(660, 0.14), (880, 0.14), (660, 0.18)]),
    ("switch", [(523, 0.12), (784, 0.2)]),
    ("tick", [(330, 0.1)]),
]
for (name, notes) in specs {
    let total = notes.reduce(0) { $0 + $1.1 }
    let frames = Int(total * 24_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    var i = 0
    for (freq, seconds) in notes {
        let n = Int(seconds * 24_000)
        for j in 0..<n {
            let t = Float(j) / 24_000
            let env = min(1, Float(j) / 240) * min(1, Float(n - j) / 1200)
            buffer.floatChannelData![0][i] = sinf(2 * .pi * freq * t) * 0.35 * env
            i += 1
        }
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).aiff")
    let file = try! AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true], commonFormat: .pcmFormatFloat32, interleaved: false)
    try! file.write(from: buffer)
    print("✓ \(url.path)")
}
