import Foundation
import AppKit
@preconcurrency import AVFoundation

// Offline end-to-end engine validation, moved verbatim from MediaEngine.
// These suites never request camera, screen, or microphone access.
extension MediaEngine {
    /// Offline end-to-end validation; does not request camera, screen, or microphone access.
    static func runSelfTest(directory: URL) async throws -> URL {
        let engine = MediaEngine()
        defer { engine.stopAll(); engine.timer?.invalidate() }
        engine.microphoneEnabled = false
        let captureCases: [(CGSize, Double, Int, Int)] = [
            (CGSize(width: 1512, height: 982), 2, 3024, 1964),
            (CGSize(width: 1920, height: 1080), 2, 3840, 2160),
            (CGSize(width: 1080, height: 1920), 2, 2160, 3840),
            (CGSize(width: 2560, height: 720), 2, 3840, 1080),
            (CGSize(width: 1280, height: 720), 1, 1280, 720)
        ]
        for (points, scale, width, height) in captureCases {
            let size = CaptureSizing.dimensions(contentSize: points, pointPixelScale: scale)
            guard size.width == width, size.height == height else { throw EngineError.message("Native/Retina capture dimensions lost source pixels or aspect ratio.") }
        }
        engine.setComposition(RenderConfiguration(width: 2560, height: 1440))
        try await Task.sleep(nanoseconds: 80_000_000)
        guard let initialPreview = engine.preview, initialPreview.size == CGSize(width: 1600, height: 900) else { throw EngineError.message("Single-canvas preview detail was reduced.") }
        try await Task.sleep(nanoseconds: 80_000_000)
        guard engine.preview === initialPreview else { throw EngineError.message("Unchanged preview unnecessarily invalidated the UI.") }
        engine.setComposition(RenderConfiguration(backgroundHex: "FF0000", width: 2560, height: 1440))
        try await Task.sleep(nanoseconds: 80_000_000)
        guard engine.preview !== initialPreview,
              let updatedPreview = engine.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let updatedColor = VideoColor.sample(updatedPreview, x: 100, y: 100),
              updatedColor.redComponent > 0.9, updatedColor.greenComponent < 0.1 else { throw EngineError.message("Composition changes did not refresh the idle preview.") }
        engine.setSecondaryComposition(RenderConfiguration(width: 1080, height: 1920))
        try await Task.sleep(nanoseconds: 80_000_000)
        guard engine.preview?.size == CGSize(width: 1280, height: 720), engine.secondaryPreview?.size == CGSize(width: 720, height: 1280) else { throw EngineError.message("Dual preview dimensions did not retain detail and orientation.") }
        engine.setSecondaryComposition(nil)
        print("PASS Retina/native capture bounds including portrait and ultrawide; detailed single/dual previews; unchanged preview identity")
        var setup = RenderConfiguration(backgroundHex: "102030", title: "Offline self-test", layers: [RenderLayer(kind: "color", text: "FF0000", width: 0.5, height: 0.5), RenderLayer(kind: "text", text: "Native media self-test", x: 0.05, y: 0.6, width: 0.9, height: 0.25)], width: 640, height: 360)
        engine.setComposition(setup)
        guard let composed = engine.compose(width: 640, height: 360), let data = composed.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { throw EngineError.message("Compositor produced no pixels.") }
        let position = 10 * composed.bytesPerRow + 40
        guard bytes[position] == 255, bytes[position + 1] == 0 else { throw EngineError.message("Top-left layer coordinates or color failed.") }
        // Fixture: red/green across the top, blue/white across the bottom.
        // Pixel expectations describe visible outcomes rather than reproducing layout formulas.
        let fixture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 160, bitsPerPixel: 32)!
        for y in 0..<20 {
            for x in 0..<40 {
                let offset = y * fixture.bytesPerRow + x * 4
                let channels: [UInt8] = y < 10 ? (x < 20 ? [255, 0, 0, 255] : [0, 255, 0, 255]) : (x < 20 ? [0, 0, 255, 255] : [255, 255, 255, 255])
                for channel in 0..<4 { fixture.bitmapData![offset + channel] = channels[channel] }
            }
        }
        guard let fixtureImage = fixture.cgImage else { throw EngineError.message("Cannot create synthetic image fixture.") }
        // Distinct corner markers detect cropping, unlike broad color quadrants which remain
        // visible even when a centered portrait crop removes most of the desktop edges.
        let desktop = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 160, bitsPerPixel: 32)!
        for y in 0..<20 {
            for x in 0..<40 {
                let atLeft = x < 4, atRight = x >= 36, atTop = y < 4, atBottom = y >= 16
                let channels: [UInt8] = atLeft && atTop ? [255, 0, 0, 255] : atRight && atTop ? [0, 255, 0, 255] : atLeft && atBottom ? [0, 0, 255, 255] : atRight && atBottom ? [255, 255, 255, 255] : [64, 64, 64, 255]
                for c in 0..<4 { desktop.bitmapData![y * desktop.bytesPerRow + x * 4 + c] = channels[c] }
            }
        }
        engine.screenFrame = desktop.cgImage
        engine.setComposition(RenderConfiguration(backgroundHex: "000000", layers: [RenderLayer(kind: "screen", fit: "fit")], width: 1080, height: 1920))
        guard let portrait = engine.compose(width: 1080, height: 1920) else { throw EngineError.message("Portrait fit fixture did not render.") }
        let cornerSamples: [(Int, Int, [Double])] = [(27, 717, [1, 0, 0]), (1053, 717, [0, 1, 0]), (27, 1203, [0, 0, 1]), (1053, 1203, [1, 1, 1])]
        for (x, y, expected) in cornerSamples {
            guard let pixel = VideoColor.sample(portrait, x: x, y: y),
                  zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], expected).allSatisfy({ abs($0 - $1) < 0.05 }) else { throw EngineError.message("Portrait fit lost a desktop corner marker.") }
        }
        guard let letterbox = VideoColor.sample(portrait, x: 540, y: 100), letterbox.redComponent < 0.01 else { throw EngineError.message("Portrait fit must center the complete desktop with bars.") }
        engine.setComposition(RenderConfiguration(backgroundHex: "000000", layers: [RenderLayer(kind: "screen", fit: "fill")], width: 1080, height: 1920))
        guard let filledPortrait = engine.compose(width: 1080, height: 1920),
              let croppedEdge = VideoColor.sample(filledPortrait, x: 27, y: 27),
              abs(croppedEdge.redComponent - 0.25) < 0.03, abs(croppedEdge.greenComponent - 0.25) < 0.03 else { throw EngineError.message("Explicit fill must crop desktop edges to fill portrait.") }
        engine.screenFrame = nil
        print("PASS portrait1080x1920 fit preserves all four desktop corner markers; explicit fill crops; composition changes refresh idle preview")
        engine.imageCache["fixture:quadrants"] = fixtureImage
        func sample(_ layer: RenderLayer, x: Int, y: Int) throws -> NSColor {
            engine.setComposition(RenderConfiguration(backgroundHex: "000000", layers: [layer], width: 100, height: 100))
            guard let image = engine.compose(width: 100, height: 100), let pixel = VideoColor.sample(image, x: x, y: y) else { throw EngineError.message("Cannot sample transformed composition.") }
            return pixel
        }
        var transform = RenderLayer(kind: "image", path:"fixture:quadrants",fit: "fit")
        let bar = try sample(transform, x: 50, y: 10)
        let fittedRed = try sample(transform, x: 10, y: 35)
        guard bar.redComponent < 0.05, bar.greenComponent < 0.05, fittedRed.redComponent > 0.9, fittedRed.greenComponent < 0.1 else { throw EngineError.message("Fit must preserve image aspect with centered black bars.") }
        let missing=try sample(RenderLayer(kind:"image",path:"/nonexistent/framecast-missing-image.png"),x:50,y:50)
        guard missing.redComponent<0.05 && missing.greenComponent<0.05 && missing.blueComponent<0.05 else {throw EngineError.message("Missing image displayed an unrelated source.")}
        engine.imageCache["fixture:quadrants"]=fixtureImage
        transform.fit = "stretch"
        let stretchedRed = try sample(transform, x: 10, y: 10)
        guard stretchedRed.redComponent > 0.9, stretchedRed.blueComponent < 0.1 else { throw EngineError.message("Stretch must fill bounds without bars.") }
        transform.cropTop = 0.5; transform.cropRight = 0.5
        let croppedBlue = try sample(transform, x: 50, y: 50)
        guard croppedBlue.blueComponent > 0.9, croppedBlue.redComponent < 0.1 else { throw EngineError.message("Top/right crop must retain the bottom-left blue quadrant.") }
        transform.cropTop = 0; transform.cropRight = 0; transform.rotation = 90
        let rotatedBlue = try sample(transform, x: 10, y: 10)
        guard rotatedBlue.blueComponent > 0.9, rotatedBlue.redComponent < 0.1 else { throw EngineError.message("Clockwise rotation must move bottom-left blue to top-left.") }
        transform.rotation = 0; transform.saturation = 0
        let gray = try sample(transform, x: 10, y: 10)
        guard abs(gray.redComponent - gray.greenComponent) < 0.02, abs(gray.greenComponent - gray.blueComponent) < 0.02 else { throw EngineError.message("Zero saturation must remove color.") }
        transform.brightness = 0.3
        let brighter = try sample(transform, x: 10, y: 10)
        guard brighter.redComponent > gray.redComponent + 0.15 else { throw EngineError.message("Brightness must visibly increase luminance.") }
        transform.brightness = 0; transform.contrast = 0
        let flatRed = try sample(transform, x: 10, y: 10)
        let flatWhite = try sample(transform, x: 90, y: 90)
        guard abs(flatRed.redComponent - flatWhite.redComponent) < 0.02 else { throw EngineError.message("Zero contrast must collapse different luminances.") }
        let qrText = "https://example.com/offline-qr-test"
        guard let qr = engine.makeQRCode(qrText), qr.width == qr.height, qr.width > 20 else { throw EngineError.message("QR generator produced no square image.") }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: engine.filterContext, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let qrFeatures = detector?.features(in: CIImage(cgImage: qr).transformed(by: CGAffineTransform(scaleX: 8, y: 8))) as? [CIQRCodeFeature]
        guard qrFeatures?.contains(where: { $0.messageString == qrText }) == true else { throw EngineError.message("Generated QR code could not be decoded to its original text.") }
        engine.setComposition(RenderConfiguration(backgroundHex: "000000", layers: [RenderLayer(kind: "qr", text: qrText)], width: 400, height: 400))
        guard let qrComposition = engine.compose(width: 400, height: 400), let composedFeatures = detector?.features(in: CIImage(cgImage: qrComposition)) as? [CIQRCodeFeature], composedFeatures.contains(where: { $0.messageString == qrText }) else { throw EngineError.message("Composited QR code failed text round-trip.") }
        engine.setComposition(setup)
        print("PASS image fit/stretch, top-left crop, clockwise rotation, saturation/brightness/contrast; generated and composited QR text decode")
        engine.startRecording(directory: directory, width: 640, height: 360, fps: 30)
        guard engine.recording else { throw EngineError.message(engine.errorMessage ?? "Recording did not start.") }
        let wallStart = ProcessInfo.processInfo.systemUptime
        for frame in 0..<45 {
            if frame == 15 {
                engine.toggleRecordingPause()
                let pausedElapsed = engine.elapsed
                try await Task.sleep(nanoseconds: 250_000_000)
                guard engine.recordingPaused, abs(engine.elapsed - pausedElapsed) < 0.01 else { throw EngineError.message("Pause must freeze elapsed time.") }
                engine.toggleRecordingPause()
            }
            setup.layers[0].x = Double(frame) / 100
            engine.setComposition(setup)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        engine.stopRecording()
        for _ in 0..<100 {
            if !engine.isFinalizingRecording { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !engine.isFinalizingRecording, engine.errorMessage == nil, let url = engine.recordingURL else { throw EngineError.message(engine.errorMessage ?? "Recording finalization timed out.") }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        let wallDuration = ProcessInfo.processInfo.systemUptime - wallStart
        guard wallDuration - duration.seconds > 0.18, abs(duration.seconds - engine.elapsed) < 0.2 else { throw EngineError.message("Recorded media duration must exclude paused time.") }
        print("PASS recording pause/resume; wall=\(wallDuration), media=\(duration.seconds), active=\(engine.elapsed)")
        guard tracks.count == 1, duration.seconds > 1 else { throw EngineError.message("Output video track or duration is invalid.") }
        let size = try await tracks[0].load(.naturalSize)
        guard size.width == 640, size.height == 360 else { throw EngineError.message("Output dimensions differ from request.") }
        let generator = AVAssetImageGenerator(asset: asset)
        let (decoded, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        guard decoded.width == 640 else { throw EngineError.message("Recorded video could not be decoded.") }
        guard let red = VideoColor.sample(decoded, x: 200, y: 20), red.redComponent > 0.8, red.greenComponent < 0.2 else { throw EngineError.message("Decoded layer color/orientation is incorrect.") }
        engine.timer?.invalidate()
        engine.stopAll()
        return url
    }

    /// Synthetic shared-camera/audio fixture. Never opens a physical capture device or requests access.
    static func runDualSelfTest(directory: URL) async throws -> [URL] {
        let engine = MediaEngine()
        defer { engine.stopAll(); engine.timer?.invalidate() }
        engine.microphoneEnabled = false
        let horizontal = RenderConfiguration(backgroundHex: "AA0000", layers: [RenderLayer(kind: "camera")], width: 640, height: 360)
        let vertical = RenderConfiguration(backgroundHex: "0000AA", layers: [RenderLayer(kind: "camera")], width: 360, height: 640)
        let fixture = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.green.setFill(); rect.fill(); return true
        }
        guard let sharedFrame = fixture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw EngineError.message("Synthetic camera fixture failed.") }
        engine.cameraFrame = sharedFrame
        engine.setComposition(horizontal); engine.setSecondaryComposition(vertical)
        // Reserve the capture owner with a non-running session: synthetic samples only.
        engine.audioSession = AVCaptureSession(); engine.microphoneState = .active
        engine.toggleMicrophoneInput()
        guard engine.microphoneReady, engine.audioSession != nil else { throw EngineError.message("Ready microphone did not retain its owned input.") }
        engine.microphoneEnabled = true
        engine.microphoneGain = 0.5
        engine.capturedAudioEnabled = true; engine.capturedAudioGain = 0.25
        engine.startRecording(directory: directory, width: 640, height: 360, fps: 30, secondaryFPS: 24)
        guard engine.recording, engine.recordingOutputs.count == 2 else { throw EngineError.message(engine.errorMessage ?? "Dual recording did not start.") }
        let wallStart = ProcessInfo.processInfo.systemUptime
        var description = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw EngineError.message("Synthetic audio format failed.") }
        for frame in 0..<45 {
            if frame == 15 {
                engine.toggleMicrophoneInput()
                guard !engine.microphoneReady, engine.audioSession != nil else { throw EngineError.message("Pausing ready input interrupted recording input.") }
                engine.toggleMicrophoneInput()
                engine.toggleRecordingPause()
                let frozen = engine.elapsed
                try await Task.sleep(nanoseconds: 300_000_000)
                guard engine.recordingPaused, abs(engine.elapsed - frozen) < 0.01 else { throw EngineError.message("Dual pause did not freeze timeline.") }
                engine.toggleRecordingPause()
                // Exercise switching the active editing canvas while both encoders continue.
                engine.setComposition(vertical); engine.setSecondaryComposition(horizontal)
            }
            let count = 1470
            var pcm = [Int16](repeating: 0, count: count)
            for index in pcm.indices { pcm[index] = Int16(sin(Double(frame * count + index) * 440 * 2 * Double.pi / 44100) * 12000) }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw EngineError.message("Synthetic audio allocation failed.") }
            let status = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2) }
            guard status == noErr else { throw EngineError.message("Synthetic audio copy failed.") }
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: hostTime, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else { throw EngineError.message("Synthetic audio sample failed.") }
            engine.appendAudio(sample)
            let capturedCount = AudioTimelineMixer.rate / 30
            var stereo = [Int16](repeating: 0, count: capturedCount * 2)
            for index in 0..<capturedCount {
                let tone = Int16(sin(Double(frame * capturedCount + index) * 880 * 2 * Double.pi / Double(AudioTimelineMixer.rate)) * 8000)
                stereo[index * 2] = tone; stereo[index * 2 + 1] = -tone
            }
            if let captured = MixedAudioSample.make(data: stereo.withUnsafeBytes { Data($0) }, frame: AudioTimelineMixer.frame(at: hostTime.seconds)) {
                engine.appendAudio(captured, input: .captured)
            }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        guard engine.secondaryPreview != nil, engine.preview != nil else { throw EngineError.message("Both previews must publish frames.") }
        engine.stopRecording()
        guard engine.isFinalizingRecording else { throw EngineError.message("Stop did not retain encoder finalization ownership.") }
        let previousURLs = engine.recordingURLs
        engine.startRecording(directory: directory, width: 640, height: 360, fps: 30)
        guard !engine.recording, engine.recordingURLs == previousURLs else { throw EngineError.message("New recording must wait for all prior encoders.") }
        for _ in 0..<200 {
            if !engine.isFinalizingRecording { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard !engine.isFinalizingRecording, engine.errorMessage == nil, engine.recordingURLs.count == 2 else { throw EngineError.message(engine.errorMessage ?? "Dual finalization timed out.") }
        var durations: [Double] = []
        var audioPeaks: [Int] = []
        for (index, url) in engine.recordingURLs.enumerated() {
            let asset = AVURLAsset(url: url)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard video.count == 1, audio.count == 1 else { throw EngineError.message("Each output must contain one video and one audio track.") }
            let size = try await video[0].load(.naturalSize)
            let expected = index == 0 ? CGSize(width: 640, height: 360) : CGSize(width: 360, height: 640)
            guard size == expected else { throw EngineError.message("Dual output dimensions incorrect: \(size).") }
            let fps = try await video[0].load(.nominalFrameRate)
            guard abs(fps - (index == 0 ? 30 : 24)) < 0.5 else { throw EngineError.message("Independent canvas frame rate was lost: \(fps).") }
            let duration = try await asset.load(.duration).seconds
            durations.append(duration)
            guard duration > 1, abs(duration - engine.elapsed) < 0.2, ProcessInfo.processInfo.systemUptime - wallStart - duration > 0.25 else { throw EngineError.message("Dual recording did not preserve shared pause timeline.") }
            let (decoded, _) = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 0.8, preferredTimescale: 600))
            guard let pixel = VideoColor.sample(decoded, x: decoded.width / 2, y: decoded.height / 2), pixel.greenComponent > 0.8, pixel.redComponent < 0.2 else { throw EngineError.message("Shared synthetic camera pixels missing from dual output.") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            guard reader.startReading() else { throw EngineError.message("Cannot decode dual audio.") }
            var peak = 0
            var differenceSquares = 0.0; var stereoFrames = 0
            while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                var samples = [Int16](repeating: 0, count: length / 2)
                let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard status == noErr else { throw EngineError.message("Decoded audio read failed.") }
                peak = max(peak, samples.map { abs(Int($0)) }.max() ?? 0)
                for index in stride(from: 0, to: samples.count - 1, by: 2) {
                    let difference = Double(samples[index]) - Double(samples[index + 1])
                    differenceSquares += difference * difference; stereoFrames += 1
                }
            }
            guard reader.status == .completed, peak > 4000, peak < 8500 else { throw EngineError.message("Dual audio fanout/gain decode failed: peak \(peak).") }
            let stereoDifference = sqrt(differenceSquares / Double(max(1, stereoFrames)))
            guard stereoDifference > 1500, stereoDifference < 4000 else { throw EngineError.message("Captured stereo audio was lost or mixed twice: \(stereoDifference)") }
            audioPeaks.append(peak)
        }
        guard abs(durations[0] - durations[1]) < 0.07, abs(audioPeaks[0] - audioPeaks[1]) < 100 else { throw EngineError.message("Dual outputs differ in shared timing or gain.") }
        guard engine.microphoneReady, engine.audioSession != nil else { throw EngineError.message("Recording stop interrupted ready input.") }
        engine.toggleMicrophoneInput()
        guard !engine.microphoneReady, engine.audioSession == nil else { throw EngineError.message("Pausing the final ready input leaked its capture.") }
        print("PASS independent ready microphone/recording ownership without physical capture")
        let successfulURLs = engine.recordingURLs
        // Mixed encoder failure must retain finalization ownership and report only completed files.
        engine.microphoneEnabled = false
        engine.startRecording(directory: directory, width: 360, height: 640, fps: 30)
        guard engine.recording, engine.recordingOutputs.count == 2 else { throw EngineError.message("Dual restart failed.") }
        try await Task.sleep(nanoseconds: 150_000_000)
        engine.recordingOutputs[1].writer.cancelWriting()
        engine.stopRecording()
        for _ in 0..<200 {
            if !engine.isFinalizingRecording { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard !engine.isFinalizingRecording, engine.errorMessage != nil, engine.recordingURLs.count == 1 else { throw EngineError.message("Mixed encoder failure was hidden or finalization ownership leaked.") }
        print("PASS mixed cancelled/completed encoder finalization; failed output excluded and error surfaced")
        engine.setSecondaryComposition(nil)
        guard engine.secondaryPreview == nil else { throw EngineError.message("Disabled secondary preview was retained.") }
        print("PASS simultaneous 640x360 + 360x640 H264/AAC decode, shared camera pixels, shared audio gain peaks \(audioPeaks), pause timeline \(durations), active canvas swap, aggregate finalization/restart guard")
        return successfulURLs
    }
}
