import Foundation
import AppKit
@preconcurrency import AVFoundation
import Combine
import Darwin

private final class CameraMicrophoneReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var video: (@Sendable (CGImage, CaptureDeliveryPermit) -> Void)?
    var audio: (@Sendable (CMSampleBuffer, CaptureDeliveryPermit) -> Void)?
    let cameraCapacity = DispatchSemaphore(value: 1)
    let audioCapacity = DispatchSemaphore(value: 8)
    private let context = CIContext(options: [.cacheIntermediates: false])
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            if let permit = CaptureDeliveryPermit.acquire(audioCapacity) { audio?(sampleBuffer, permit) }
            return
        }
        deliver(sampleBuffer)
    }
    private func deliver(_ sample: CMSampleBuffer) {
        guard let permit = CaptureDeliveryPermit.acquire(cameraCapacity) else { return }
        guard CMSampleBufferIsValid(sample), let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let frame = CIImage(cvPixelBuffer: buffer)
        if let image = context.createCGImage(frame, from: frame.extent) { video?(image, permit) }
    }
}

@MainActor final class MediaEngine: ObservableObject {
    @Published var preview: NSImage?
    @Published var secondaryPreview: NSImage?
    @Published var recording = false
    @Published private(set) var recordingPaused = false
    @Published var streaming = false
    @Published var failure: MediaFailure?
    var errorMessage: String? { failure?.localizedDescription }
    @Published var elapsed: TimeInterval = 0
    @Published var microphoneEnabled = true {
        didSet { if microphoneEnabled && (recording || streaming || microphoneReady) { ensureMicrophone() } }
    }
    let audioLevels = AudioSignalMonitor()
    private var microphoneState: AudioCaptureState = .inactive
    private var microphoneReady = false
    private var microphonePackets = 0
    private var microphoneDecodedPackets = 0
    @Published var microphoneGain: Double = 1
    @Published var capturedAudioEnabled = false {
        didSet { screenCapture.setIncludeAudio(capturedAudioEnabled) }
    }
    @Published var capturedAudioGain: Double = 1
    @Published private(set) var capturedAudioActive = false
    var selectedMicrophone: String? {
        didSet {
            if selectedMicrophone != oldValue {
                stopMicrophone()
                if recording || streaming || microphoneReady { ensureMicrophone() }
            }
        }
    }
    @Published private(set) var cameraOptions: [CaptureDeviceOption] = []
    @Published private(set) var microphoneOptions: [CaptureDeviceOption] = []
    @Published var recordingURL: URL?
    @Published private(set) var recordingURLs: [URL] = []
    @Published private(set) var recordingStatistics: [RecordingStatistics] = []
    private var lastStatisticsTime = 0.0
    @Published private(set) var isFinalizingRecording = false
    @Published private(set) var cameraActive = false
    @Published private(set) var cameraStarting = false
    private var cameraPackets = 0
    private var microphoneSampleRate = 0.0
    @Published private(set) var screenActive = false
    @Published private(set) var screenCaptureBusy = false
    @Published private(set) var screenCaptureSize: CGSize = .zero

    private var config = RenderConfiguration()
    private var secondaryConfig: RenderConfiguration?
    private var imageCache: [String: CGImage] = [:]
    private var qrImages: [String: CGImage] = [:]
    private let filterContext = CIContext(options: [.cacheIntermediates: false])
    private struct ProcessedImage {
        let original: CGImage
        let options: [Double]
        let image: CGImage
    }
    private var processedImages: [UUID: ProcessedImage] = [:]
    private var cameraFrame: CGImage?
    private var screenFrame: CGImage?
    private var cameraSession: AVCaptureSession?
    private var audioSession: AVCaptureSession?
    private let screenCapture = ScreenCaptureSession()
    private let receiver = CameraMicrophoneReceiver()
    private let captureQueue = DispatchQueue(label: "studio.capture", qos: .userInitiated)
    private let cameraFrameQueue = DispatchQueue(label: "studio.camera.frames", qos: .userInitiated)
    private let microphoneSampleQueue = DispatchQueue(label: "studio.microphone.samples", qos: .userInitiated)
    private var timer: Timer?
    private var recordingOutputs: [RecordingOutput] = []
    // Retain ownership until every encoder callback has completed, including failed outputs.
    private var finishingOutputs: [RecordingOutput] = []
    private var finishedOutputIDs: Set<UUID> = []
    private var recordingStart: TimeInterval = 0
    private var recordingPauseStarted: TimeInterval = 0
    private var recordingPausedDuration: TimeInterval = 0
    private var hostStart = CMTime.zero
    private var streamPipe: StreamPipe?
    private var streamWidth = 1280
    private var streamHeight = 720
    private var streamFPS = 30
    private var streamConfiguration:RenderConfiguration?
    var streamingVertical:Bool? {streamConfiguration.map{$0.vertical ?? ($0.height>$0.width)}}
    private var lastStreamTime: TimeInterval = 0
    private var cameraGeneration = UUID()
    private var microphoneGeneration = UUID()
    private var audioMixer = AudioTimelineMixer()
    private var recordingAudioClock: RecordingAudioClock?
    private var lastPreviewTime: TimeInterval = 0
    private var previewNeedsUpdate = true
    private var cameraDevices: [AVCaptureDevice] = []
    private var microphoneDevices: [AVCaptureDevice] = []

    init() {
        receiver.video = { [weak self] frame, permit in
            Task { @MainActor in
                defer { permit.release() }
                guard let self else { return }
                if self.cameraActive { self.cameraFrame = frame; self.cameraPackets += 1; self.previewNeedsUpdate = true }
            }
        }
        screenCapture.frame = { [weak self] frame in
            guard let self else { return }
            self.screenFrame = frame
            let size = CGSize(width: frame.width, height: frame.height)
            if self.screenCaptureSize != size { self.screenCaptureSize = size }
            self.previewNeedsUpdate = true
        }
        screenCapture.changed = { [weak self] active, busy, includesAudio in
            guard let self else { return }
            self.screenActive = active; self.screenCaptureBusy = busy; self.capturedAudioActive = active && includesAudio
            if !active { self.audioLevels.clear(.captured); self.screenFrame = nil; self.screenCaptureSize = .zero; self.previewNeedsUpdate = true }
        }
        screenCapture.audio = { [weak self] sample in self?.appendAudio(sample, input: .captured) }
        screenCapture.failed = { [weak self] in self?.failure = MediaFailure(code: .captureFailed, operation: "Screen capture", message: $0, recovery: "Choose the source again or check Screen Recording access.") }
        receiver.audio = { [weak self] sample, permit in Task { @MainActor in
            defer { permit.release() }
            self?.appendAudio(sample)
        } }
        refreshDevices()
        timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {self?.renderTick()}
        }
        RunLoop.main.add(timer!,forMode:.common)
    }

    func refreshDevices() {
        cameraDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        microphoneDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        cameraOptions = cameraDevices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        microphoneOptions = microphoneDevices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func device(in devices: [AVCaptureDevice], selection: String?, default fallback: AVCaptureDevice?) -> AVCaptureDevice? {
        guard let selection, !selection.isEmpty else { return fallback }
        if let exact = devices.first(where: { $0.uniqueID == selection }) { return exact }
        let legacy = devices.filter { $0.localizedName == selection }
        return legacy.count == 1 ? legacy[0] : nil
    }

    func setComposition(_ configuration:RenderConfiguration) {setCompositions(configuration,secondary:secondaryConfig)}
    func setSecondaryComposition(_ configuration:RenderConfiguration?) {setCompositions(config,secondary:configuration)}
    /// Replace both canvas configurations atomically and refresh resources once.
    func setCompositions(_ primary:RenderConfiguration,secondary:RenderConfiguration?) {
        let next=boundedConfiguration(primary),other=secondary.map(boundedConfiguration)
        guard config != next || secondaryConfig != other else{return}
        config=next;secondaryConfig=other;previewNeedsUpdate=true
        if other==nil,secondaryPreview != nil {secondaryPreview=nil}
        refreshCompositionResources()
        renderTick()
    }
    /// Geometry-only gesture updates never publish the document, reload resources,
    /// or synchronously compose video. The common-mode frame timer samples the latest state.
    func updateSourceTransform(_ id:UUID,vertical:Bool,x:Double,y:Double,width:Double,height:Double,cornerRadius:Double,shape:String?) {
        func update(_ value:inout RenderConfiguration)->Bool {
            guard (value.vertical ?? (value.height>value.width))==vertical,
                  let index=value.layers.firstIndex(where:{$0.id==id}) else{return false}
            let before=value.layers[index]
            value.layers[index].x=x;value.layers[index].y=y;value.layers[index].width=width;value.layers[index].height=height;value.layers[index].cornerRadius=cornerRadius;value.layers[index].shape=shape
            return value.layers[index] != before
        }
        var dirty=update(&config)
        if var other=secondaryConfig {dirty=update(&other) || dirty;secondaryConfig=other}
        if dirty {previewNeedsUpdate=true}
    }
    private func boundedConfiguration(_ configuration: RenderConfiguration) -> RenderConfiguration {
        var result = configuration
        result.width = min(3840, max(64, configuration.width))
        result.height = min(3840, max(64, configuration.height))
        if result.width * result.height > 3840 * 2160 {
            let scale = sqrt(Double(3840 * 2160) / Double(result.width * result.height))
            result.width = Int(Double(result.width) * scale)
            result.height = Int(Double(result.height) * scale)
        }
        // H.264 requires even dimensions, including the secondary composition.
        result.width -= result.width % 2; result.height -= result.height % 2
        return result
    }

    private func refreshCompositionResources() {
        let layers = config.layers + (secondaryConfig?.layers ?? [])
        let qrTexts = Set(layers.filter { $0.kind == "qr" }.map(\.text))
        qrImages = qrImages.filter { qrTexts.contains($0.key) }
        for text in qrTexts where qrImages[text] == nil {
            if let image = makeQRCode(text) { qrImages[text] = image }
        }
        let layerIDs = Set(layers.map(\.id))
        processedImages = processedImages.filter { layerIDs.contains($0.key) }
        let paths = Set(layers.filter { $0.kind == "image" && !$0.path.isEmpty }.map(\.path))
        imageCache = imageCache.filter { paths.contains($0.key) }
        for path in paths where imageCache[path] == nil {
            if let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { imageCache[path] = cg }
        }
    }

    func startCamera(deviceID: String? = nil) {
        stopCamera()
        let generation = UUID(); cameraGeneration = generation; cameraStarting = true
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard generation == cameraGeneration else { return }
            guard granted else { cameraStarting = false; failure = MediaFailure(code: .inputPermission, operation: "Camera", message: "Camera access was denied.", recovery: "Enable Framecast in System Settings → Privacy & Security → Camera."); return }
            refreshDevices()
            guard let device = Self.device(in: cameraDevices, selection: deviceID, default: AVCaptureDevice.default(for: .video)) else {
                cameraStarting = false; failure = MediaFailure(code: .inputUnavailable, operation: "Camera", message: "The selected camera is unavailable.", recovery: "Reconnect it or choose another camera in Settings."); return
            }
            do {
                let session = AVCaptureSession()
                session.beginConfiguration(); session.sessionPreset = .high
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw EngineError.message("Camera input is unavailable.") }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(receiver, queue: cameraFrameQueue)
                guard session.canAddOutput(output) else { throw EngineError.message("Camera output is unavailable.") }
                session.addOutput(output); session.commitConfiguration()
                cameraSession = session
                captureQueue.async {
                    session.startRunning(); let running = session.isRunning
                    Task { @MainActor [weak self] in
                        guard let self, self.cameraGeneration == generation, self.cameraSession === session else { return }
                        self.cameraStarting = false; self.cameraActive = running
                        if running, self.failure?.operation == "Camera" { self.failure = nil }
                        if !running { self.failure = MediaFailure(code: .inputUnavailable, operation: "Camera", message: "The camera did not start.", recovery: "Check whether another app is using it, or select another camera.") }
                    }
                }
            } catch { cameraStarting = false; failure = .classify(error, operation: "Camera", fallback: .inputUnavailable) }
        }
    }

    func stopCamera() {
        cameraGeneration = UUID()
        if let session = cameraSession { captureQueue.async { session.stopRunning() } }
        cameraSession = nil; cameraFrame = nil; cameraActive = false; cameraStarting = false; previewNeedsUpdate = true
    }

    func chooseScreenCapture() { screenCapture.present() }

    func stopScreenCapture() { screenCapture.stop() }

    func startRecording(directory: URL, width: Int, height: Int, fps: Int, secondaryFPS: Int? = nil, preferences: MediaPreferences = MediaPreferences()) {
        guard !recording, !isFinalizingRecording else { return }
        guard MediaLimits.supports(width: width, height: height, fps: fps) else { failure = .invalid("Recording requires even dimensions of64–3840, at most8,294,400 pixels, and1–60fps."); return }
        guard preferences.isValid else { failure = .invalid("Recording encoding preferences are invalid."); return }
        var prepared: [RecordingOutput] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let stem = "Studio-\(timestamp)-\(UUID().uuidString.prefix(6))"
            var targets = [(config, width, height, fps, false)]
            if let secondaryConfig {
                guard MediaLimits.supports(width: secondaryConfig.width, height: secondaryConfig.height, fps: secondaryFPS ?? fps) else { throw MediaFailure.invalid("Unsupported secondary recording dimensions or frame rate.") }
                targets.append((secondaryConfig, secondaryConfig.width, secondaryConfig.height, secondaryFPS ?? fps, true))
            }
            let totalBitrate = targets.reduce(0) { sum, target in
                sum + preferences.recordingBitRate(width: target.1, height: target.2, fps: target.3, vertical: target.0.vertical ?? (target.2 > target.1))
            }
            try RecordingStorage.preflight(directory: directory, bitRate: totalBitrate)
            for (configuration, w, h, rate, secondary) in targets {
                let settings = preferences.recording(vertical: configuration.vertical ?? (h > w))
                let orientation = w >= h ? "horizontal" : "vertical"
                let suffix = targets.count > 1 ? "-\(secondary ? "secondary-" : "")\(orientation)" : ""
                let url = directory.appendingPathComponent("\(stem)\(suffix).\(settings.container.rawValue)")
                prepared.append(try RecordingOutput(url: url, width: w, height: h, fps: rate, configuration: configuration, settings: settings, audioBitrate: preferences.recordingAudioBitrateKbps * 1000))
            }
            recordingOutputs = prepared
            updateCaptureCadence()
            recordingStatistics = []; lastStatisticsTime = 0
            recordingStart = ProcessInfo.processInfo.systemUptime
            hostStart = CMClockGetTime(CMClockGetHostTimeClock())
            recordingAudioClock = RecordingAudioClock(hostTime: hostStart.seconds)
            if !streaming { audioMixer.start(at: hostStart.seconds) }
            elapsed = 0; failure = nil
            recordingPaused = false; recordingPausedDuration = 0; recordingPauseStarted = 0; recording = true
            ensureMicrophone()
            renderTick()
        } catch {
            for output in prepared { output.writer.cancelWriting() }
            recordingOutputs = []
            failure = .classify(error, operation: "Recording")
        }
    }

    func toggleRecordingPause() {
        guard recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if recordingPaused {
            recordingAudioClock?.resume(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            recordingPausedDuration += now - recordingPauseStarted
            recordingPaused = false
        } else {
            recordingAudioClock?.pause(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            recordingPauseStarted = now
            elapsed = now - recordingStart - recordingPausedDuration
            recordingPaused = true
        }
    }

    func stopRecording() {
        guard recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = (recordingPaused ? recordingPauseStarted : now) - recordingStart - recordingPausedDuration
        drainAudio(until: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        recording = false; recordingPaused = false; isFinalizingRecording = true; recordingAudioClock = nil
        if !streaming { audioMixer.reset() }
        if !streaming && !microphoneReady { stopMicrophone() }
        recordingStatistics = recordingOutputs.map { $0.statistics(elapsed: elapsed) }
        finishingOutputs = recordingOutputs; recordingOutputs = []; finishedOutputIDs = []; updateCaptureCadence()
        for output in finishingOutputs {
            if output.writer.status == .writing && output.lastRecordedTime.isValid {
                output.video.markAsFinished(); output.audio.markAsFinished()
                output.writer.finishWriting { [self, output] in
                    Task { @MainActor in self.didFinish(output) }
                }
            } else {
                if output.writer.status == .writing { output.writer.cancelWriting() }
                didFinish(output)
            }
        }
    }

    private func didFinish(_ output: RecordingOutput) {
        guard finishingOutputs.contains(where: { $0 === output }) else { return }
        finishedOutputIDs.insert(output.id)
        if output.writer.status != .completed {
            failure = output.writer.error.map { MediaFailure.classify($0, operation: "Recording finalization") } ?? MediaFailure(code: .encoderFailed, operation: "Recording finalization", message: "The file could not be finalized (\(output.url.lastPathComponent)).", recovery: "Keep any recoverable partial file; verify storage and encoder settings before retrying.")
        }
        guard finishedOutputIDs.count == finishingOutputs.count else { return }
        recordingURLs = finishingOutputs.filter { $0.writer.status == .completed }.map(\.url)
        recordingURL = recordingURLs.first
        finishingOutputs = []; finishedOutputIDs = []; isFinalizingRecording = false
    }

    private func ensureMicrophone() {
        guard audioSession == nil, microphoneState != .starting, microphoneEnabled || microphoneReady else { return }
        microphoneState = .starting
        let generation = UUID(); microphoneGeneration = generation
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard (recording || streaming || microphoneReady), generation == microphoneGeneration else { return }
            guard granted else { microphoneState = .denied; microphoneReady = false; failure = MediaFailure(code: .inputPermission, operation: "Microphone", message: "Microphone access was denied.", recovery: "Enable Framecast in System Settings → Privacy & Security → Microphone."); return }
            refreshDevices()
            guard let device = Self.device(in: microphoneDevices, selection: selectedMicrophone, default: AVCaptureDevice.default(for: .audio)) else {
                microphoneState = .unavailable; microphoneReady = false
                failure = MediaFailure(code: .inputUnavailable, operation: "Microphone", message: "The selected microphone is unavailable.", recovery: "Reconnect it or select System default in Audio."); return
            }
            do {
                let session = AVCaptureSession()
                session.beginConfiguration()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioTimelineMixer.rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
                guard session.canAddInput(input), session.canAddOutput(output) else { throw EngineError.message("Microphone capture is unavailable.") }
                session.addInput(input); session.addOutput(output)
                output.setSampleBufferDelegate(receiver, queue: microphoneSampleQueue)
                session.commitConfiguration(); audioSession = session
                captureQueue.async {
                    session.startRunning()
                    let running = session.isRunning
                    Task { @MainActor [weak self = self] in
                        guard let self, self.microphoneGeneration == generation, self.audioSession === session else { return }
                        self.microphoneState = running ? .active : .failed
                        if running, self.failure?.operation == "Microphone" { self.failure = nil }
                        if !running { self.microphoneReady = false }
                    }
                }
            } catch { microphoneState = .failed; microphoneReady = false; failure = .classify(error, operation: "Microphone", fallback: .inputUnavailable) }
        }
    }

    private func stopMicrophone() {
        microphoneGeneration = UUID()
        if let session = audioSession { captureQueue.async { session.stopRunning() } }
        audioSession = nil; microphoneState = .inactive; audioLevels.clear(.microphone)
    }

    private func appendAudio(_ sample: CMSampleBuffer, input: AudioInput = .microphone) {
        if input == .microphone { microphonePackets += 1 }
        guard let packet = AudioPacket.decode(sample) else { return }
        if input == .microphone { microphoneDecodedPackets += 1; microphoneSampleRate = packet.rate }
        audioLevels.receive(packet, input: input, now: ProcessInfo.processInfo.systemUptime)
        guard recording || streaming else { return }
        audioMixer.insert(packet, input: input)
    }

    private func drainAudio(until hostTime: Double) {
        guard recording || streaming else { return }
        audioMixer.microphoneGain = microphoneEnabled ? microphoneGain : 0
        audioMixer.capturedGain = capturedAudioEnabled ? capturedAudioGain : 0
        var streamAudio = Data()
        defer { if streaming, !streamAudio.isEmpty { streamPipe?.sendAudio(streamAudio) } }
        for block in audioMixer.drain(until: hostTime) {
            audioLevels.receiveMixed(block, now: ProcessInfo.processInfo.systemUptime)
            if streaming { streamAudio.append(block.data) }
            guard recording, let clock = recordingAudioClock else { continue }
            for mapped in clock.map(block) {
                guard let sample = MixedAudioSample.make(data: mapped.data, frame: mapped.frame) else { continue }
                for output in recordingOutputs where output.writer.status == .writing {
                    guard output.audio.isReadyForMoreMediaData else { output.audioBackpressurePackets += 1; continue }
                    if !output.audio.append(sample) {
                        failure = output.writer.error.map { MediaFailure.classify($0, operation: "Recording audio") } ?? MediaFailure(code: .encoderFailed, operation: "Recording audio", message: "An audio packet could not be written.", recovery: "Check storage and output load, then retry.")
                        // Stop outside this loop; re-entering a drain would duplicate audio.
                        DispatchQueue.main.async { [weak self] in self?.stopRecording() }
                        return
                    }
                }
            }
        }
    }

    func startStreaming(url: String, key: String, width: Int, height: Int, fps: Int,configuration:RenderConfiguration?=nil,settings:StreamEncodingSettings=StreamEncodingSettings()) {
        guard !streaming else { return }
        guard settings.isValid else { failure = .invalid("Streaming preferences are invalid."); return }
        guard MediaLimits.supports(width: width, height: height, fps: fps) else { failure = .invalid("Unsupported streaming dimensions or frame rate."); return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), ["rtmp", "rtmps"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else {
            failure = .invalid("Enter a valid rtmp:// or rtmps:// server URL."); return
        }
        guard !key.contains("\n"), !key.contains("\r") else { failure = .invalid("The stream key contains an invalid line break."); return }
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            failure = MediaFailure(code: .encoderUnavailable, operation: "Streaming", message: "FFmpeg is unavailable.", recovery: "Install FFmpeg independently at /opt/homebrew/bin/ffmpeg or /usr/local/bin/ffmpeg, then retry."); return
        }
        let destination = key.isEmpty ? trimmed : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + key
        let pipe = StreamPipe()
        pipe.onExit = { [weak self, weak pipe] status, _ in
            Task { @MainActor in
                guard let self, self.streamPipe === pipe else { return }
                self.streaming = false; self.streamPipe = nil;self.streamConfiguration=nil
                pipe?.stop()
                if !self.recording && !self.microphoneReady { self.stopMicrophone() }
                self.updateCaptureCadence()
                if status != 0 { self.failure = MediaFailure(code: .encoderFailed, operation: "Streaming", message: "The encoder exited (status \(status)).", recovery: "Check the destination, network and selected encoder. If Apple encoding is unavailable, explicitly choose Software H.264.") }
            }
        }
        pipe.onFailure = { [weak self, weak pipe] failure in
            Task { @MainActor in
                guard let self, self.streamPipe === pipe else { return }
                self.stopStreaming(); self.failure = failure
            }
        }
        do {
            try pipe.start(executable: executable, destination: destination, width: width, height: height, fps: fps, settings: settings, privateValues: [key, trimmed])
            streamConfiguration=boundedConfiguration(configuration ?? outputConfiguration(vertical:height>width,fallback:config))
            streamWidth = width; streamHeight = height; streamFPS = fps; lastStreamTime = 0
            if !recording { audioMixer.start(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
            streamPipe = pipe; streaming = true; updateCaptureCadence()
            ensureMicrophone()
        } catch { pipe.stop(); failure = .classify(error, operation: "Streaming", fallback: .encoderUnavailable) }
    }

    func stopStreaming() {
        drainAudio(until: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        let pipe = streamPipe; streamPipe = nil; streaming = false;streamConfiguration=nil;pipe?.stop();updateCaptureCadence()
        if !recording { if !microphoneReady { stopMicrophone() }; audioMixer.reset() }
    }

    /// Diagnostic metadata only: no audio samples or recording files are saved.
    static func probePermittedMicrophone(deviceID: String?) async throws -> [String: Any] {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw EngineError.message("Microphone access is not already granted; use the app's permission controls first.")
        }
        let engine = MediaEngine(); engine.selectedMicrophone = deviceID; engine.microphoneEnabled = true
        defer { engine.stopAll() }
        engine.prepareMicrophone()
        var loudest = -60.0
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            loudest = max(loudest, engine.audioLevels.snapshot.microphone.rmsDB)
        }
        let report: [String: Any] = ["permissionAlreadyGranted": true, "inputReady": engine.microphoneReady,
            "sessionRunning": engine.audioSession?.isRunning ?? false, "receivedPackets": engine.microphonePackets,
            "decodedPackets": engine.microphoneDecodedPackets, "sampleRate": engine.microphoneSampleRate, "loudestRMSdBFS": loudest,
            "meterStatus": engine.audioLevels.snapshot.microphone.status, "audioSamplesSaved": false]
        engine.stopAll()
        await withCheckedContinuation { continuation in engine.captureQueue.async { continuation.resume() } }
        guard engine.microphoneDecodedPackets > 0 else { throw EngineError.message("Microphone probe received no decodable audio. \(report)") }
        return report
    }

    private var requestedCaptureFPS = 30
    func setCaptureFrameRate(_ fps: Int) {
        requestedCaptureFPS = min(60, max(1, fps)); updateCaptureCadence()
    }
    private func updateCaptureCadence() {
        screenCapture.setFrameRate(max(requestedCaptureFPS, recordingOutputs.map(\.fps).max() ?? 1, streaming ? streamFPS : 1))
    }

    static func probePermittedCamera(deviceID: String?) async throws -> [String: Any] {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw MediaFailure(code: .inputPermission, operation: "Camera probe", message: "Camera access is not already granted.", recovery: "Enable it through Framecast’s permission guide first.") }
        let engine = MediaEngine(); defer { engine.stopAll() }
        engine.startCamera(deviceID: deviceID); engine.stopCamera()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard !engine.cameraActive, !engine.cameraStarting, engine.cameraSession == nil else { throw MediaFailure.invalid("Cancelled camera startup was adopted.") }
        engine.startCamera(deviceID: deviceID)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        guard engine.cameraActive, engine.cameraPackets > 0, let frame = engine.cameraFrame else { throw engine.failure ?? MediaFailure(code: .inputUnavailable, operation: "Camera probe", message: "No camera frames were received.", recovery: "Check the selected camera and retry.") }
        let report: [String: Any] = ["permissionAlreadyGranted": true, "sessionRunning": engine.cameraSession?.isRunning ?? false,
            "capturedWidth": frame.width, "capturedHeight": frame.height, "receivedVideoFrames": engine.cameraPackets,
            "cancelledStartupStayedStopped": true, "imagesSaved": false]
        engine.stopAll()
        await withCheckedContinuation { continuation in engine.captureQueue.async { continuation.resume() } }
        return report
    }
    func prepareMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        if !microphoneReady { microphoneReady = true; ensureMicrophone() }
    }
    func toggleMicrophoneInput() {
        microphoneReady.toggle()
        if microphoneReady { ensureMicrophone() }
        else if !recording && !streaming { stopMicrophone() }
    }
    func stopAll() { microphoneReady = false; stopRecording(); stopStreaming(); stopMicrophone(); stopCamera(); stopScreenCapture() }

    func renderTick() {
        let now = ProcessInfo.processInfo.systemUptime
        audioLevels.refresh(now: now, microphoneState: microphoneState,
            capturedState: screenCaptureBusy ? .starting : capturedAudioActive ? .active : screenActive && capturedAudioEnabled ? .failed : .inactive,
            microphoneGain: microphoneGain, capturedGain: capturedAudioGain,
            microphoneMuted: !microphoneEnabled, capturedEnabled: capturedAudioEnabled, microphoneReady: microphoneReady,
            outputRunning: recording || streaming, outputPaused: recordingPaused && !streaming)
        let previewDue = previewNeedsUpdate && now - lastPreviewTime >= 1.0 / 30
        if !recording && !streaming && !previewDue { return }
        drainAudio(until: CMClockGetTime(CMClockGetHostTimeClock()).seconds - 0.08)
        // Output encoding always composes at its own dimensions. These budgets affect only
        // on-screen previews, and unchanged frames do not invalidate the SwiftUI view tree.
        let previewLimit = secondaryConfig == nil ? 1600.0 : 1280.0
        let previewScale = min(1, previewLimit / Double(max(config.width, config.height)))
        let previewWidth = max(1, Int(Double(config.width) * previewScale))
        let previewHeight = max(1, Int(Double(config.height) * previewScale))
        var previewImage: CGImage?
        if previewDue {
            if let frame = compose(width: previewWidth, height: previewHeight) {
                previewImage = frame
                preview = NSImage(cgImage: frame, size: NSSize(width: previewWidth, height: previewHeight))
            }
            if let secondaryConfig {
                let scale = min(1, previewLimit / Double(max(secondaryConfig.width, secondaryConfig.height)))
                let w = max(1, Int(Double(secondaryConfig.width) * scale)), h = max(1, Int(Double(secondaryConfig.height) * scale))
                if let frame = compose(configuration: secondaryConfig, width: w, height: h) {
                    secondaryPreview = NSImage(cgImage: frame, size: NSSize(width: w, height: h))
                }
            }
            lastPreviewTime = now
            previewNeedsUpdate = false
        }
        if recording {
            elapsed = (recordingPaused ? recordingPauseStarted : now) - recordingStart - recordingPausedDuration
        }
        if recording, now - lastStatisticsTime >= 1 {
            recordingStatistics = recordingOutputs.map { $0.statistics(elapsed: elapsed) }; lastStatisticsTime = now
        }
        if recording && !recordingPaused {
            for output in recordingOutputs {
                let time = CMTime(value: Int64(elapsed * Double(output.fps)), timescale: Int32(output.fps))
                guard !output.lastRecordedTime.isValid || time > output.lastRecordedTime else { continue }
                guard output.writer.status == .writing else {
                    failure = output.writer.error.map { MediaFailure.classify($0, operation: "Recording video") } ?? MediaFailure(code: .encoderFailed, operation: "Recording", message: "The video encoder stopped unexpectedly.", recovery: "Reduce output load or choose another codec, then start a new recording.")
                    stopRecording(); break
                }
                guard output.video.isReadyForMoreMediaData else { output.droppedFrames += 1; continue }
                let configuration = recordingConfiguration(for: output)
                guard let buffer = compositionBuffer(configuration: configuration, width: output.width, height: output.height, pool: output.adaptor.pixelBufferPool) else {
                    failure = MediaFailure(code: .frameAllocation, operation: "Recording", message: "Unable to allocate a video frame.", recovery: "Reduce resolution or close other memory-intensive apps, then start a new recording."); stopRecording(); break
                }
                if output.adaptor.append(buffer, withPresentationTime: time) { output.lastRecordedTime = time; output.submittedFrames += 1 }
                else { failure = output.writer.error.map { MediaFailure.classify($0, operation: "Recording video") } ?? MediaFailure(code: .encoderFailed, operation: "Recording", message: "A video frame could not be written.", recovery: "Check storage and encoder settings, then start a new recording."); stopRecording(); break }
            }
        }
        if let pinned=streamConfiguration {streamConfiguration=outputConfiguration(vertical:pinned.vertical ?? (pinned.height>pinned.width),fallback:pinned)}
        if streaming, now - lastStreamTime >= 1 / Double(streamFPS), let streamPipe,let pinned=streamConfiguration,
           let frame = (pinned==config && streamWidth==previewWidth && streamHeight==previewHeight ? previewImage:nil) ?? compose(configuration:pinned,width:streamWidth,height:streamHeight),
           let buffer = pixelBuffer(image: frame, width: streamWidth, height: streamHeight) {
            lastStreamTime = now
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                var bytes = Data(capacity: streamWidth * streamHeight * 4)
                for row in 0..<streamHeight { bytes.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: streamWidth * 4) }
                streamPipe.send(bytes)
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
    }

    /// All layer positions are normalized with a top-left origin. Images fill and clip their bounds.
    private func outputConfiguration(vertical:Bool,fallback:RenderConfiguration)->RenderConfiguration {
        if (config.vertical ?? (config.height>config.width))==vertical {return config}
        if let secondaryConfig,(secondaryConfig.vertical ?? (secondaryConfig.height>secondaryConfig.width))==vertical {return secondaryConfig}
        return fallback
    }
    func updateStreamingComposition(_ configuration:RenderConfiguration) {
        guard let vertical=streamingVertical,(configuration.vertical ?? (configuration.height>configuration.width))==vertical else{return}
        streamConfiguration=boundedConfiguration(configuration)
    }
    private func recordingConfiguration(for output:RecordingOutput)->RenderConfiguration {
        let vertical=output.configuration.vertical ?? (output.height>output.width)
        let current=outputConfiguration(vertical:vertical,fallback:output.configuration)
        output.configuration=current
        return current
    }

    func compose(width: Int, height: Int) -> CGImage? {
        compose(configuration: config, width: width, height: height)
    }

    private func compose(configuration config: RenderConfiguration, width: Int, height: Int) -> CGImage? {
        guard width > 0, width <= 3840, height > 0, height <= 3840, width * height <= 3840 * 2160,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: VideoColor.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawComposition(configuration: config, in: context, width: width, height: height)
        return context.makeImage()
    }

    /// One drawing interpretation serves preview images and native encoder buffers.
    private func drawComposition(configuration config: RenderConfiguration, in context: CGContext, width: Int, height: Int) {
        context.setFillColor(color(config.backgroundHex).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for layer in config.layers where layer.visible && layer.opacity > 0 {
            guard [layer.x, layer.y, layer.width, layer.height, layer.opacity, layer.cornerRadius, layer.rotation, layer.cropLeft, layer.cropTop, layer.cropRight, layer.cropBottom, layer.brightness, layer.contrast, layer.saturation].allSatisfy(\.isFinite), layer.width > 0, layer.height > 0 else { continue }
            let bounds = CGRect(x: layer.x * Double(width), y: (1 - layer.y - layer.height) * Double(height), width: layer.width * Double(width), height: layer.height * Double(height))
            context.saveGState(); context.setAlpha(CGFloat(min(1, max(0, layer.opacity))))
            if layer.rotation != 0 {
                context.translateBy(x: bounds.midX, y: bounds.midY)
                context.rotate(by: -CGFloat(layer.rotation.truncatingRemainder(dividingBy: 360)) * .pi / 180)
                context.translateBy(x: -bounds.midX, y: -bounds.midY)
            }
            let radius = min(Double(min(bounds.width, bounds.height)) / 2, max(0, layer.cornerRadius) * Double(width) / Double(config.width))
            let mask=layer.shape=="circle" ? CGPath(ellipseIn:bounds,transform:nil):CGPath(roundedRect:bounds,cornerWidth:radius,cornerHeight:radius,transform:nil)
            context.addPath(mask);context.clip()
            var source: CGImage?
            switch layer.kind {
            case "camera": source = cameraFrame
            case "screen": source = screenFrame
            case "image": source = imageCache[layer.path]
            case "qr": source = qrImages[layer.text]
            case "color": context.setFillColor(color(layer.text.isEmpty ? "7658F2" : layer.text).cgColor); context.fill(bounds)
            case "text":
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(12, min(96, bounds.height * 0.42)), weight: .semibold), .foregroundColor: NSColor.white]
                (layer.text as NSString).draw(in: bounds.insetBy(dx: 8, dy: 4), withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
            default: break
            }
            if let original = source, let source = processedImage(original, layer: layer) {
                let horizontal = bounds.width / CGFloat(source.width)
                let vertical = bounds.height / CGFloat(source.height)
                let scale = (layer.kind == "qr" || layer.fit.lowercased() == "fit") ? min(horizontal, vertical) : max(horizontal, vertical)
                let imageWidth = layer.fit.lowercased() == "stretch" ? bounds.width : CGFloat(source.width) * scale
                let imageHeight = layer.fit.lowercased() == "stretch" ? bounds.height : CGFloat(source.height) * scale
                var rect = CGRect(x: bounds.midX - imageWidth / 2, y: bounds.midY - imageHeight / 2, width: imageWidth, height: imageHeight)
                if layer.mirrored {
                    context.translateBy(x: bounds.midX * 2, y: 0); context.scaleBy(x: -1, y: 1)
                    rect.origin.x = bounds.midX - rect.width / 2
                }
                context.interpolationQuality = layer.kind == "qr" ? .none : .high; context.draw(source, in: rect)
            }
            context.restoreGState()
        }
    }

    private func makeQRCode(_ text: String) -> CGImage? {
        // ISO QR version 40, error correction M has at most 2,331 byte-mode data bytes.
        guard !text.isEmpty, let data = text.data(using: .utf8), data.count <= 2331,
              let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": data, "inputCorrectionLevel": "M"]),
              let code = filter.outputImage else { return nil }
        let padded = code.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: padded)
        return filterContext.createCGImage(code.composited(over: white), from: padded)
    }

    /// CGImage crop rectangles have a top-left pixel origin; canvas geometry remains bottom-left internally.
    private func processedImage(_ original: CGImage, layer: RenderLayer) -> CGImage? {
        let onePixelX = 1 / Double(original.width), onePixelY = 1 / Double(original.height)
        let left = min(1 - onePixelX, max(0, layer.cropLeft)), top = min(1 - onePixelY, max(0, layer.cropTop))
        let right = min(1 - left - onePixelX, max(0, layer.cropRight)), bottom = min(1 - top - onePixelY, max(0, layer.cropBottom))
        let brightness = min(1, max(-1, layer.brightness))
        let contrast = min(4, max(0, layer.contrast)), saturation = min(4, max(0, layer.saturation))
        let options = [left, top, right, bottom, brightness, contrast, saturation]
        if let cached = processedImages[layer.id], cached.original === original, cached.options == options { return cached.image }
        var result = original
        if left != 0 || top != 0 || right != 0 || bottom != 0 {
            let crop = CGRect(x: left * Double(original.width), y: top * Double(original.height), width: (1 - left - right) * Double(original.width), height: (1 - top - bottom) * Double(original.height)).integral
            guard let cropped = original.cropping(to: crop) else { return nil }
            result = cropped
        }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            let input = CIImage(cgImage: result)
            let filtered = input.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
            guard let rendered = filterContext.createCGImage(filtered, from: input.extent) else { return nil }
            result = rendered
        }
        // Each entry retains source identity and transformed pixels, so stale identities cannot alias.
        if processedImages.count >= 32, processedImages[layer.id] == nil { processedImages.removeAll(keepingCapacity: true) }
        processedImages[layer.id] = ProcessedImage(original: original, options: options, image: result)
        return result
    }

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

    private func color(_ hex: String) -> NSColor {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return .black }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private func compositionBuffer(configuration: RenderConfiguration, width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        makePixelBuffer(width: width, height: height, pool: pool) { context in
            drawComposition(configuration: configuration, in: context, width: width, height: height)
        }
    }

    private func pixelBuffer(image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        makePixelBuffer(width: width, height: height, pool: pool) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The pixel buffer owns its storage through encoder submission; no intermediate full-frame image.
    private func makePixelBuffer(width: Int, height: Int, pool: CVPixelBufferPool?, draw: (CGContext) -> Void) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let status: CVReturn
        if let pool { status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) }
        else { status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &output) }
        guard status == kCVReturnSuccess, let output else { return nil }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let address = CVPixelBufferGetBaseAddress(output), let context = CGContext(data: address, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(output), space: VideoColor.space, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, VideoColor.space, .shouldPropagate)
        draw(context)
        return output
    }
}

private enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
