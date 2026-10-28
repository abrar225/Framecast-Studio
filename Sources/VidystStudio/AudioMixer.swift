import AVFoundation

enum AudioInput: Int { case microphone, captured }

struct AudioPacket {
    var hostTime: Double
    var rate: Double
    var channels: Int
    var samples: [Float]
    var frames: Int { samples.count / channels }

    static func decode(_ sample: CMSampleBuffer) -> AudioPacket? {
        let frames = CMSampleBufferGetNumSamples(sample)
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time.isFinite, time >= 0, frames > 0,
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              (8000...192000).contains(asbd.pointee.mSampleRate),
              (1...2).contains(asbd.pointee.mChannelsPerFrame),
              frames <= Int(asbd.pointee.mSampleRate),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return nil }
        let channels = Int(format.channelCount)
        let stride = format.isInterleaved ? channels : 1
        var result = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let plane = format.isInterleaved ? 0 : channel
            let offset = format.isInterleaved ? channel : 0
            for frame in 0..<frames {
                let index = frame * stride + offset
                let value: Float
                if let data = buffer.floatChannelData { value = data[plane][index] }
                else if let data = buffer.int16ChannelData { value = Float(data[plane][index]) / 32768 }
                else if let data = buffer.int32ChannelData { value = Float(data[plane][index]) / 2147483648 }
                else { return nil }
                result[frame * channels + channel] = value.isFinite ? value : 0
            }
        }
        return AudioPacket(hostTime: time, rate: format.sampleRate, channels: channels, samples: result)
    }
}

struct MixedAudioBlock {
    var firstFrame: Int64
    var samples: [Int16] // interleaved stereo at 48 kHz
    var frames: Int { samples.count / 2 }
    var data: Data { samples.withUnsafeBytes { Data($0) } }
}

/// Common host-clock timeline, one bounded ring per input. Mixing happens once before
/// fanout. Late/duplicate input cannot append a second overlapping encoder packet.
struct AudioTimelineMixer {
    static let rate = 48000
    private static let capacity = rate
    private struct Track {
        var tags = [Int64](repeating: -1, count: capacity)
        var left = [Float](repeating: 0, count: capacity)
        var right = [Float](repeating: 0, count: capacity)
    }
    private var tracks = [Track(), Track()]
    private(set) var cursor: Int64?
    private(set) var lateFrames = 0
    private(set) var skippedFrames: Int64 = 0
    var microphoneGain = 1.0
    var capturedGain = 1.0

    static func frame(at hostTime: Double) -> Int64 { Int64((hostTime * Double(rate)).rounded()) }
    mutating func start(at hostTime: Double) {
        cursor = Self.frame(at: hostTime); lateFrames = 0; skippedFrames = 0
        tracks = [Track(), Track()]
    }
    mutating func reset() { cursor = nil; tracks = [Track(), Track()] }
    mutating func insert(_ packet: AudioPacket, input: AudioInput) {
        guard let cursor, packet.hostTime.isFinite, packet.hostTime >= 0,
              packet.hostTime < Double(Int64.max / Int64(Self.rate)) - 2,
              packet.rate.isFinite, (8000...192000).contains(packet.rate),
              (1...2).contains(packet.channels), !packet.samples.isEmpty,
              packet.samples.count % packet.channels == 0, packet.frames <= Int(packet.rate) else { return }
        let first = Self.frame(at: packet.hostTime)
        let count = Int((Double(packet.frames) / packet.rate * Double(Self.rate)).rounded())
        let lower = max(0, Int(clamping: cursor - first))
        let upper = min(count, Int(clamping: cursor + Int64(Self.capacity) - first))
        lateFrames += min(count, lower)
        guard lower < upper else { return }
        for offset in lower..<upper {
            let position = Double(offset) * packet.rate / Double(Self.rate)
            let a = min(packet.frames - 1, Int(position)), b = min(packet.frames - 1, a + 1)
            let blend = Float(position - Double(a))
            func sample(_ channel: Int) -> Float {
                let channel = min(packet.channels - 1, channel)
                let x = packet.samples[a * packet.channels + channel], y = packet.samples[b * packet.channels + channel]
                let value = x + (y - x) * blend
                return value.isFinite ? value : 0
            }
            let frame = first + Int64(offset), slot = Int(frame % Int64(Self.capacity))
            tracks[input.rawValue].tags[slot] = frame
            tracks[input.rawValue].left[slot] = sample(0); tracks[input.rawValue].right[slot] = sample(1)
        }
    }
    mutating func drain(until hostTime: Double) -> [MixedAudioBlock] {
        guard var cursor, hostTime.isFinite, hostTime >= 0,
              hostTime < Double(Int64.max / Int64(Self.rate)) - 2 else { return [] }
        let end = Self.frame(at: hostTime)
        guard end > cursor else { return [] }
        if end - cursor > Int64(Self.capacity) {
            skippedFrames += end - cursor - Int64(Self.capacity); cursor = end - Int64(Self.capacity)
        }
        let gains = [microphoneGain, capturedGain].map { $0.isFinite ? min(4, max(0, $0)) : 0 }
        var blocks: [MixedAudioBlock] = []
        while cursor < end {
            let count = Int(min(Int64(Self.rate / 100), end - cursor))
            var pcm = [Int16](repeating: 0, count: count * 2)
            for offset in 0..<count {
                let frame = cursor + Int64(offset), slot = Int(frame % Int64(Self.capacity))
                var left = 0.0, right = 0.0
                for input in 0..<tracks.count where tracks[input].tags[slot] == frame {
                    left += Double(tracks[input].left[slot]) * gains[input]
                    right += Double(tracks[input].right[slot]) * gains[input]
                }
                pcm[offset * 2] = Int16(min(32767, max(-32768, left * 32768)))
                pcm[offset * 2 + 1] = Int16(min(32767, max(-32768, right * 32768)))
            }
            blocks.append(MixedAudioBlock(firstFrame: cursor, samples: pcm)); cursor += Int64(count)
        }
        self.cursor = cursor
        return blocks
    }
}

/// Maps host frames into the recording clock. Pauses are removed by interval rather
/// than by callback arrival time, including delayed packets received after resume.
struct RecordingAudioClock {
    var origin: Int64
    private var pauses: [(Int64, Int64?)] = []
    init(hostTime: Double) { origin = AudioTimelineMixer.frame(at: hostTime) }
    mutating func pause(at hostTime: Double) {
        if pauses.last?.1 != nil || pauses.isEmpty { pauses.append((AudioTimelineMixer.frame(at: hostTime), nil)) }
    }
    mutating func resume(at hostTime: Double) {
        guard let last = pauses.last, last.1 == nil else { return }
        pauses[pauses.count - 1].1 = max(last.0, AudioTimelineMixer.frame(at: hostTime))
    }
    func map(_ block: MixedAudioBlock) -> [(frame: Int64, data: Data)] {
        let end = block.firstFrame + Int64(block.frames)
        var cursor = max(origin, block.firstFrame), removed: Int64 = 0
        var result: [(Int64, Data)] = []
        func emit(until boundary: Int64) {
            let stop = min(end, boundary)
            guard stop > cursor else { return }
            let range = Int(cursor - block.firstFrame) * 2..<Int(stop - block.firstFrame) * 2
            result.append((cursor - origin - removed, Array(block.samples[range]).withUnsafeBytes { Data($0) }))
            cursor = stop
        }
        for (start, stop) in pauses {
            if cursor >= end { break }
            emit(until: start)
            if cursor >= start {
                let pauseEnd = stop ?? end
                cursor = max(cursor, min(end, pauseEnd))
                removed += max(0, pauseEnd - max(origin, start))
            }
        }
        emit(until: end)
        return result
    }
}

enum MixedAudioSample {
    static func make(data: Data, frame: Int64) -> CMSampleBuffer? {
        guard !data.isEmpty, data.count % 4 == 0 else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(AudioTimelineMixer.rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?, block: CMBlockBuffer?, sample: CMSampleBuffer?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        guard data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(AudioTimelineMixer.rate)), presentationTimeStamp: CMTime(value: frame, timescale: Int32(AudioTimelineMixer.rate)), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: data.count / 4, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
