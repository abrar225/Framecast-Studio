import Testing
import AVFoundation
@testable import VidystStudio

private struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@Suite struct AudioMixerTests {
    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    @Test func timelineMixingGainClippingResamplingAndPauseMapping() throws {
        let base = 10.0, origin = AudioTimelineMixer.frame(at: base)
        var mixer = AudioTimelineMixer(); mixer.start(at: base)
        let mic = AudioPacket(hostTime: base, rate: 44100, channels: 1, samples: [Float](repeating: 0.25, count: 441))
        let system = AudioPacket(hostTime: base, rate: 44100, channels: 2, samples: (0..<441).flatMap { _ in [Float(0.5), Float(-0.5)] })
        mixer.insert(mic, input: .microphone); mixer.insert(system, input: .captured)
        mixer.insert(mic, input: .microphone) // duplicate input overwrites its slots
        let mixed = mixer.drain(until: base + 0.01)
        try require(mixed.count == 1 && mixed[0].frames == 480, "Mixer emitted overlapping/duplicate packets")
        try require(mixed[0].samples[0] == 24576 && mixed[0].samples[1] == -8192, "Stereo sum/downmix is incorrect")
        try require(mixer.drain(until: base + 0.01).isEmpty, "Already drained audio was emitted twice")
        mixer.insert(mic, input: .microphone)
        try require(mixer.lateFrames == 480, "Late input was not recognized")
        try require(mixer.drain(until: base + 0.02)[0].samples.allSatisfy { $0 == 0 }, "Missing input reused stale audio instead of silence")
        print("PASS stereo mixing, mono duplication, duplicate overwrite, silence and late-input isolation")

        mixer.start(at: base); mixer.microphoneGain = 0; mixer.capturedGain = 0.5
        mixer.insert(mic, input: .microphone); mixer.insert(system, input: .captured)
        let gain = mixer.drain(until: base + 0.01)[0].samples
        try require(gain[0] == 8192 && gain[1] == -8192, "Independent gain/mute failed")
        mixer.start(at: base); mixer.microphoneGain = 4; mixer.capturedGain = 4
        mixer.insert(mic, input: .microphone); mixer.insert(system, input: .captured)
        let clipped = mixer.drain(until: base + 0.01)[0].samples
        try require(clipped[0] == 32767 && clipped[1] == -32768, "Clipping overflowed")
        mixer.start(at: base); mixer.microphoneGain = 1; mixer.capturedGain = 0
        mixer.insert(AudioPacket(hostTime: base, rate: 48000, channels: 1, samples: [Float](repeating: 0.5, count: 4800)), input: .microphone)
        let resampled = mixer.drain(until: base + 0.1)
        try require(resampled.reduce(0) { $0 + $1.frames } == 4800 && resampled.flatMap(\.samples).allSatisfy { $0 == 16384 }, "Rate normalization lost duration or level")
        mixer.insert(AudioPacket(hostTime: .infinity, rate: 44100, channels: 1, samples: [1]), input: .captured)
        mixer.insert(AudioPacket(hostTime: base, rate: 44100, channels: 0, samples: [1]), input: .captured)
        _ = mixer.drain(until: base + 10)
        try require(mixer.skippedFrames > 0, "Long stalls did not bound retained work")
        print("PASS independent gain/mute, clipping, rate normalization and bounded backlog")

        let block = MixedAudioBlock(firstFrame: origin, samples: [Int16](repeating: 100, count: 2000))
        var clock = RecordingAudioClock(hostTime: base)
        clock.pause(at: base + 100.0 / Double(AudioTimelineMixer.rate)); clock.resume(at: base + 300.0 / Double(AudioTimelineMixer.rate))
        clock.pause(at: base + 500.0 / Double(AudioTimelineMixer.rate)); clock.resume(at: base + 600.0 / Double(AudioTimelineMixer.rate))
        let slices = clock.map(block)
        try require(slices.map(\.frame) == [0, 100, 300] && slices.map { $0.data.count / 4 } == [100, 200, 400], "Delayed audio did not remove multiple pauses precisely")
        clock.pause(at: base + 800.0 / Double(AudioTimelineMixer.rate))
        try require(clock.map(block).reduce(0) { $0 + $1.data.count / 4 } == 500, "Open pause leaked audio")
        let lateBlock = MixedAudioBlock(firstFrame: origin + 1000, samples: [Int16](repeating: 100, count: 200))
        clock.resume(at: base + 1000.0 / Double(AudioTimelineMixer.rate))
        try require(clock.map(lateBlock).first?.frame == 500, "Resume clock retained paused duration")
        print("PASS recording pause boundaries split delayed packets and preserve a contiguous sample clock")

        let data = MixedAudioBlock(firstFrame: origin, samples: [8192, -16384, 8192, -16384]).data
        guard let sample = MixedAudioSample.make(data: data, frame: origin), let decoded = AudioPacket.decode(sample) else { throw Failure(message: "Actual CoreMedia stereo PCM roundtrip failed") }
        try require(decoded.channels == 2 && decoded.samples == [0.25, -0.5, 0.25, -0.5] && abs(decoded.hostTime - base) < 0.00001, "Actual PCM channels/time changed")

        // ScreenCaptureKit's planar Float32 layout, including distinct left/right planes.
        var description = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?, buffer: CMBlockBuffer?, planar: CMSampleBuffer?
        let planes: [Float] = [0.25, 0.5, -0.25, -0.5]
        try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, "Float format failed")
        try require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 16, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 16, flags: 0, blockBufferOut: &buffer) == noErr, "Float allocation failed")
        try require(planes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: buffer!, offsetIntoDestination: 0, dataLength: 16) } == noErr, "Float copy failed")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: CMTime(value: origin, timescale: 44100), decodeTimeStamp: .invalid)
        try require(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer, formatDescription: format, sampleCount: 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &planar) == noErr, "Float sample failed")
        guard let planar, let unpacked = AudioPacket.decode(planar) else { throw Failure(message: "Planar PCM did not decode") }
        try require(unpacked.samples == [0.25, -0.25, 0.5, -0.5], "Planar channels were mixed or read with an incorrect stride")
        // 32-bit Float Audio Engine, AudioLimiter, and Float32 PCM sample buffer
        try require(AudioLimiter.limit(0.5) == 0.5 && AudioLimiter.limit(-0.75) == -0.75, "Limiter altered linear range")
        let hot = AudioLimiter.limit(3.0)
        try require(hot > 1.0 && hot < 1.25 && hot > AudioLimiter.limit(2.0), "Limiter failed to smoothly saturate")
        let floatData = MixedAudioBlock(firstFrame: origin, floatSamples: [0.25, -0.5, 0.75, -0.125]).floatData
        guard let floatSample = MixedAudioSample.make(data: floatData, frame: origin, isFloat: true),
              let floatDecoded = AudioPacket.decode(floatSample) else { throw Failure(message: "Native Float32 PCM roundtrip failed") }
        try require(floatDecoded.channels == 2 && abs(floatDecoded.samples[0] - 0.25) < 1e-6 && abs(floatDecoded.samples[1] - -0.5) < 1e-6, "Float32 PCM decoded channels/values differed")
        print("PASS 32-bit float audio engine, smooth soft-knee limiter and native CoreMedia Float32 PCM")

        print("PASS actual CoreMedia signed interleaved and Float32 planar PCM decoding")
    }
}
