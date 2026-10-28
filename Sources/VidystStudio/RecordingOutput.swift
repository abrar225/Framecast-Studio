import AVFoundation

final class RecordingOutput: @unchecked Sendable {
    let id = UUID()
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let url: URL
    let width: Int
    let height: Int
    let fps: Int
    var submittedFrames = 0
    var droppedFrames = 0
    let settings: RecordingEncodingSettings
    var audioBackpressurePackets = 0
    var configuration: RenderConfiguration
    var lastRecordedTime = CMTime.invalid

    init(url: URL, width: Int, height: Int, fps: Int, configuration: RenderConfiguration, settings: RecordingEncodingSettings = RecordingEncodingSettings(), audioBitrate: Int = 256000) throws {
        guard MediaLimits.supports(width: width, height: height, fps: fps), settings.isValid,
              audioBitrate % 1000 == 0, MediaPreferences.audioBitrates.contains(audioBitrate / 1000) else { throw MediaFailure.invalid("Unsupported recording format or bitrate.") }
        self.url = url; self.width = width; self.height = height; self.fps = fps; self.settings = settings; self.configuration = configuration
        writer = try AVAssetWriter(outputURL: url, fileType: settings.container.native)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let videoSettings = settings.videoSettings(width: width, height: height, fps: fps)
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw MediaFailure(code: .encoderUnavailable, operation: "Recording", message: "The selected codec and hardware configuration are unavailable.", recovery: "Choose another codec, reduce output load or disable required hardware encoding.")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw MediaFailure(code: .encoderUnavailable, operation: "Recording", message: "\(settings.codec.title) encoding is unavailable at this size.", recovery: "Choose another codec, reduce the resolution or disable required hardware encoding.") }
        writer.add(video)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioTimelineMixer.rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioBitrate]
        guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else { throw MediaFailure.invalid("Unsupported stereo AAC settings.") }
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(audio) else { throw MediaFailure(code: .encoderUnavailable, operation: "Recording audio", message: "AAC recording is unavailable.", recovery: "Choose a supported audio bitrate and retry.") }
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error.map { MediaFailure.classify($0, operation: "Recording", fallback: .encoderUnavailable) } ?? MediaFailure(code: .encoderUnavailable, operation: "Recording", message: "Could not start the selected encoder.", recovery: "Choose another codec, reduce the resolution or disable required hardware encoding.") }
        writer.startSession(atSourceTime: .zero)
    }
}


struct RecordingStatistics: Codable, Equatable, Identifiable {
    var id: String { fileName }
    let fileName: String
    let width: Int
    let height: Int
    let fps: Int
    let codec: String
    let submittedFrames: Int
    let missedFrameSlots: Int
    let audioBackpressurePackets: Int
}
extension RecordingOutput {
    func statistics(elapsed: Double) -> RecordingStatistics {
        RecordingStatistics(fileName: url.lastPathComponent, width: width, height: height, fps: fps, codec: settings.codec.title,
            submittedFrames: submittedFrames, missedFrameSlots: max(0, Int(elapsed * Double(fps)) + 1 - submittedFrames), audioBackpressurePackets: audioBackpressurePackets)
    }
}
