import AppKit
import AVFoundation

private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
@main private enum MediaQualityTests {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func chart(width: Int, height: Int, directory: URL) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "Chart allocation failed") }
        c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        //4-pixel black/white detail is destroyed if a preview-sized image is
        // mistakenly upscaled and encoded as4K. Test actual output pixels.
        for x in stride(from: 0, to: width, by: 8) {
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: 4, height: height))
        }
        let colors: [[CGFloat]] = [[1,0,0,1],[0,1,0,1],[0,0,1,1],[1,1,1,1]]
        for (index, components) in colors.enumerated() {
            c.setFillColor(CGColor(colorSpace: space, components: components)!)
            c.fill(CGRect(x: index * width / 4, y: height - 128, width: width / 4, height: 128))
        }
        guard let image = c.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure(message: "Chart PNG failed") }
        let url = directory.appendingPathComponent("chart-\(width)x\(height).png"); try png.write(to: url); return url
    }
    @MainActor static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        let cases: [(Int, Int, Int, RecordingCodec, RecordingContainer)] = [
            (3840, 2160, 30, .h264, .mp4), (2160, 3840, 30, .hevc, .mov),
            (3840, 2160, 60, .hevc, .mp4), (640, 360, 24, .h264, .mov)
        ]
        for (width, height, fps, codec, container) in cases {
            let engine = MediaEngine(); engine.microphoneEnabled = false
            let url = try chart(width: width, height: height, directory: directory)
            var configuration = RenderConfiguration(layers: [RenderLayer(kind: "image", path: url.path, fit: "stretch"), RenderLayer(kind: "color", text: "00FF00", x: 0.1, y: 0.68, width: 0.08, height: 0.06)], width: width, height: height, vertical: height > width)
            engine.setComposition(configuration)
            var preferences = MediaPreferences()
            var settings = RecordingEncodingSettings(); settings.codec = codec; settings.container = container
            preferences.horizontal = settings; preferences.vertical = settings
            engine.startRecording(directory: directory, width: width, height: height, fps: fps, preferences: preferences)
            try require(engine.recording, engine.errorMessage ?? "Native recording did not start")
            try require(engine.recordingURL == nil && engine.recordingURLs.isEmpty, "An unfinished file was advertised as saved")
            let start = ProcessInfo.processInfo.systemUptime
            var next = start
            while ProcessInfo.processInfo.systemUptime - start < 1.6 {
                configuration.layers[1].x = 0.1 + (ProcessInfo.processInfo.systemUptime - start) * 0.2
                engine.setComposition(configuration)
                engine.renderTick()
                next += 1 / Double(fps)
                let delay = max(0.001, next - ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            engine.stopRecording()
            for _ in 0..<200 {
                if !engine.isFinalizingRecording { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try require(!engine.isFinalizingRecording, "Native finalization timed out")
            try require(engine.failure == nil, engine.errorMessage ?? "Native recording failed")
            guard let movie = engine.recordingURL else { throw Failure(message: "No finalized movie") }
            let asset = AVURLAsset(url: movie)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let audio = try await asset.loadTracks(withMediaType: .audio)[0]
            let size = try await video.load(.naturalSize)
            let format = try await video.load(.formatDescriptions)[0]
            let type = CMFormatDescriptionGetMediaSubType(format)
            let expected: FourCharCode = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
            try require(type == expected && Int(size.width) == width && Int(size.height) == height, "Codec or true output dimensions differ")
            let audioFormat = try await audio.load(.formatDescriptions)[0]
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat) else { throw Failure(message: "Missing recorded audio description") }
            try require(asbd.pointee.mSampleRate == 48000 && asbd.pointee.mChannelsPerFrame == 2, "Output is not48kHz stereo")
            guard let extensions = CMFormatDescriptionGetExtensions(format) else { throw Failure(message: "Missing video format metadata") }
            let color = extensions as NSDictionary
            try require(color[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, "Missing BT.709 output metadata")
            let generator = AVAssetImageGenerator(asset: asset)
            let (image, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            let bitmap = NSBitmapImageRep(cgImage: image)
            var error = 0.0
            for x in stride(from: 18, to: min(1000, width - 4), by: 4) {
                guard let c = bitmap.colorAt(x: x, y: height / 2)?.usingColorSpace(.sRGB) else { throw Failure(message: "Cannot read decoded detail") }
                let expected = x % 8 < 4 ? 1.0 : 0.0
                error += abs(c.redComponent - expected)
            }
            let count = Array(stride(from: 18, to: min(1000, width - 4), by: 4)).count
            try require(error / Double(count) < 0.12, "Encoded4-pixel detail lost: mean error\(error / Double(count))")
            guard let red = VideoColor.sample(image, x: width / 8, y: 64) else { throw Failure(message: "Cannot inspect encoded color") }
            try require(red.redComponent > 0.8 && red.greenComponent < 0.2 && red.blueComponent < 0.2, "Encoded color was shifted")
            let reader = try AVAssetReader(asset: asset), compressed = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            reader.add(compressed); try require(reader.startReading(), "Cannot count encoded frames")
            var frameCount = 0
            while let sample = compressed.copyNextSampleBuffer() { frameCount += CMSampleBufferGetNumSamples(sample) }
            let videoTime = try await video.load(.timeRange).duration.seconds
            let effective = Double(frameCount) / videoTime
            let nominal = try await video.load(.nominalFrameRate)
            try require(effective >= Double(fps) * 0.8, "Delivered frame rate too low: \(effective) of\(fps)")
            results.append(["file": movie.lastPathComponent, "width": width, "height": height, "codec": codec.rawValue, "container": container.rawValue, "requestedFPS": fps, "nominalFPS": nominal, "actualEncodedFrames": frameCount, "effectiveFPS": effective, "detailMeanAbsoluteError": error / Double(count), "audioRate": 48000, "audioChannels": 2, "hardwareRequired": true, "movingCompositionAndPreview": true, "wallSeconds": ProcessInfo.processInfo.systemUptime - start])
            engine.stopAll()
            print("PASS native hardware\(codec.title)\(container.rawValue)\(width)x\(height),\(nominal)fps,48kHz stereo, BT.709, decoded4-pixel detail error\(error / Double(count))")
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("quality-results.json"))
    }
    @MainActor static func main() async {
        do { try await run(directory: URL(fileURLWithPath: CommandLine.arguments[1])); print("VERDICT: PASS") }
        catch { fputs("VERDICT: FAIL -- \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
