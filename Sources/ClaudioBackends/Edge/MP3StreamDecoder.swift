import AudioToolbox
import ClaudioCore
import Foundation

/// Incremental MP3 → canonical PCM via `AudioFileStream` + `AudioConverter` (document 06 §2.4).
/// Not thread-safe: the owning backend calls it from one task.
final class MP3StreamDecoder {
    private var streamID: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()
    private var packets: [(data: Data, description: AudioStreamPacketDescription)] = []
    private var currentPacket: Data = Data()
    private var currentDescription = AudioStreamPacketDescription()
    private(set) var framesProduced = 0
    private var ready = false
    private var failure: OSStatus = noErr
    private let framesPerBlock: UInt32 = 4800
    var onPCM: ((PCMBuffer) -> Void)?

    static let noDataStatus: OSStatus = 0x6E6F6474  // 'nodt'

    init() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var id: AudioFileStreamID?
        let status = AudioFileStreamOpen(selfPtr, { clientData, streamID, propertyID, _ in
            let decoder = Unmanaged<MP3StreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
            decoder.property(streamID: streamID, propertyID: propertyID)
        }, { clientData, byteCount, packetCount, data, descriptions in
            let decoder = Unmanaged<MP3StreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
            decoder.packets(byteCount: byteCount, packetCount: packetCount, data: data, descriptions: descriptions)
        }, kAudioFileMP3Type, &id)
        if status == noErr { streamID = id } else { failure = status }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        if let streamID { AudioFileStreamClose(streamID) }
    }

    func feed(_ data: Data) throws {
        guard let streamID else { throw BackendError.decode("AudioFileStream open failed \(failure)") }
        let status = data.withUnsafeBytes { raw -> OSStatus in
            AudioFileStreamParseBytes(streamID, UInt32(raw.count), raw.baseAddress, [])
        }
        guard status == noErr else { throw BackendError.decode("AudioFileStream \(status)") }
        if failure != noErr { throw BackendError.decode("AudioConverter \(failure)") }
        try drain(final: false)
    }

    func flush() throws {
        try drain(final: true)
    }

    func abort() {
        packets.removeAll()
    }

    private func property(streamID: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
        guard propertyID == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        guard AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &format) == noErr else {
            failure = -1
            return
        }
        inputFormat = format
        var out = AudioStreamBasicDescription(
            mSampleRate: PCMFormat.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var c: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &out, &c)
        if status == noErr, let c {
            converter = c
            ready = true
        } else {
            failure = status
        }
    }

    private func packets(byteCount: UInt32, packetCount: UInt32, data: UnsafeRawPointer, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        if let descriptions {
            for i in 0..<Int(packetCount) {
                let d = descriptions[i]
                let bytes = Data(bytes: data + Int(d.mStartOffset), count: Int(d.mDataByteSize))
                packets.append((bytes, AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: d.mVariableFramesInPacket, mDataByteSize: d.mDataByteSize)))
            }
        } else {
            let bytes = Data(bytes: data, count: Int(byteCount))
            packets.append((bytes, AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: byteCount)))
        }
    }

    private func drain(final: Bool) throws {
        guard ready, let converter else { return }
        while !packets.isEmpty || final {
            var frames = framesPerBlock
            var samples = [Float](repeating: 0, count: Int(framesPerBlock))
            let status: OSStatus = samples.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                return AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, outDescriptions, userData in
                    let decoder = Unmanaged<MP3StreamDecoder>.fromOpaque(userData!).takeUnretainedValue()  // swiftlint:disable:this force_unwrapping
                    return decoder.supplyInput(ioPackets: ioPackets, ioData: ioData, outDescriptions: outDescriptions)
                }, selfPtr, &frames, &list, nil)
            }
            if frames > 0 {
                framesProduced += Int(frames)
                onPCM?(PCMBuffer(samples: Array(samples.prefix(Int(frames)))))
            }
            if status == Self.noDataStatus { return }
            if status != noErr { throw BackendError.decode("AudioConverter \(status)") }
            if frames < framesPerBlock { return }
            if final, packets.isEmpty, frames == 0 { return }
        }
    }

    private func supplyInput(ioPackets: UnsafeMutablePointer<UInt32>, ioData: UnsafeMutablePointer<AudioBufferList>,
                             outDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        guard !packets.isEmpty else {
            ioPackets.pointee = 0
            return Self.noDataStatus
        }
        let packet = packets.removeFirst()
        currentPacket = packet.data
        currentDescription = packet.description
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        currentPacket.withUnsafeMutableBytes { raw in
            buffers[0].mData = raw.baseAddress
            buffers[0].mDataByteSize = UInt32(raw.count)
            buffers[0].mNumberChannels = 1
        }
        if let outDescriptions {
            withUnsafeMutablePointer(to: &currentDescription) { outDescriptions.pointee = $0 }
        }
        ioPackets.pointee = 1
        return noErr
    }
}
