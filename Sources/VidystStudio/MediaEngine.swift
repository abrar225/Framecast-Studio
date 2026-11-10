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
    // Internal rather than private: the compositor and self-test extensions live in separate files.
    var microphoneState: AudioCaptureState = .inactive
    var microphoneReady = false
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
    /// Duty cycle (percent) of each render stage over the last statistics window.
    /// Exported with the recording report so performance claims stay measurable.
    @Published private(set) var renderTiming: [String: Double] = [:]
    private var stageNanos: [String: UInt64] = [:]
    private var timingWindowStart: TimeInterval = 0
    private var lastStatisticsTime = 0.0
    @Published private(set) var isFinalizingRecording = false
    @Published private(set) var cameraActive = false
    @Published private(set) var cameraStarting = false
    private var cameraPackets = 0
    private var microphoneSampleRate = 0.0
    @Published private(set) var screenActive = false
    @Published private(set) var screenCaptureBusy = false
    @Published private(set) var screenCaptureSize: CGSize = .zero

    var config = RenderConfiguration()
    var secondaryConfig: RenderConfiguration?
    var imageCache: [String: CGImage] = [:]
    var qrImages: [String: CGImage] = [:]
    let filterContext = CIContext(options: [.cacheIntermediates: false])
    struct ProcessedImage {
        let original: CGImage
        let options: [Double]
        let image: CGImage
    }
    var processedImages: [UUID: ProcessedImage] = [:]
    var cameraFrame: CGImage?
    var screenFrame: CGImage?
    private var cameraSession: AVCaptureSession?
    var audioSession: AVCaptureSession?
    private let screenCapture = ScreenCaptureSession()
    private let receiver = CameraMicrophoneReceiver()
    private let captureQueue = DispatchQueue(label: "studio.capture", qos: .userInitiated)
    private let cameraFrameQueue = DispatchQueue(label: "studio.camera.frames", qos: .userInitiated)
    private let microphoneSampleQueue = DispatchQueue(label: "studio.microphone.samples", qos: .userInitiated)
    var timer: Timer?
    var recordingOutputs: [RecordingOutput] = []
    // Retain ownership until every encoder callback has completed, including failed outputs.
    private var finishingOutputs: [RecordingOutput] = []
    private var finishedOutputIDs: Set<UUID> = []
    private var recordingStart: TimeInterval = 0
    private var recordingPauseStarted: TimeInterval = 0
    private var recordingPausedDuration: TimeInterval = 0
    private var hostStart = CMTime.zero
    struct ActiveStreamOutput: Identifiable {
        let id = UUID()
        let destinationID: UUID?
        let name: String
        let pipe: StreamPipe
        let width: Int
        let height: Int
        let fps: Int
        let isVertical: Bool
        var configuration: RenderConfiguration
        var lastStreamTime: Double = 0
    }
    private(set) var activeStreamOutputs: [ActiveStreamOutput] = []
    var streamPipe: StreamPipe? {
        get { activeStreamOutputs.first?.pipe }
        set {
            if let pipe = newValue {
                let output = ActiveStreamOutput(destinationID: nil, name: "Stream", pipe: pipe, width: streamWidth, height: streamHeight, fps: streamFPS, isVertical: streamHeight > streamWidth, configuration: streamConfiguration ?? config)
                activeStreamOutputs = [output]
            } else {
                activeStreamOutputs.removeAll()
            }
        }
    }
    var streamWidth = 1280
    var streamHeight = 720
    var streamFPS = 30
    var streamConfiguration: RenderConfiguration?
    var streamingVertical: Bool? { streamConfiguration.map { $0.vertical ?? ($0.height > $0.width) } }
    var lastStreamTime: TimeInterval = 0
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
        updateCaptureBudget()
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
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, generation == self.cameraGeneration else { return }
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
                captureQueue.async { [weak self] in
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
            recordingStatistics = []; renderTiming = [:]; stageNanos = [:]; timingWindowStart = 0; lastStatisticsTime = 0
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

    func appendAudio(_ sample: CMSampleBuffer, input: AudioInput = .microphone) {
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
        defer {
            if streaming, !streamAudio.isEmpty {
                for stream in activeStreamOutputs {
                    stream.pipe.sendAudio(streamAudio)
                }
            }
        }
        for block in audioMixer.drain(until: hostTime) {
            audioLevels.receiveMixed(block, now: ProcessInfo.processInfo.systemUptime)
            if streaming { streamAudio.append(block.data) }
            guard recording, let clock = recordingAudioClock else { continue }
            for mapped in clock.mapFloat(block) {
                guard let sample = MixedAudioSample.make(data: mapped.data, frame: mapped.frame, isFloat: true) else { continue }
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

    /// Broadcast simultaneously to multiple RTMP destinations with failure isolation and shared composition.
    static var ffmpegExecutable: String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = String(dir) + "/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    func startStreaming(targets: [StreamTarget], settings: StreamEncodingSettings = StreamEncodingSettings()) {
        guard !streaming, !targets.isEmpty else { return }
        guard settings.isValid else { failure = .invalid("Streaming preferences are invalid."); return }
        guard let executable = Self.ffmpegExecutable else {
            failure = MediaFailure(code: .encoderUnavailable, operation: "Streaming", message: "FFmpeg is unavailable.", recovery: "Install FFmpeg independently at /opt/homebrew/bin/ffmpeg or /usr/local/bin/ffmpeg, then retry."); return
        }

        var started: [ActiveStreamOutput] = []
        for target in targets {
            guard MediaLimits.supports(width: target.width, height: target.height, fps: target.fps) else { continue }
            let trimmed = target.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: trimmed), ["rtmp", "rtmps"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else {
                failure = .invalid("Enter a valid rtmp:// or rtmps:// server URL for \(target.name)."); continue
            }
            let key = target.key
            guard !key.contains("\n"), !key.contains("\r") else {
                failure = .invalid("The stream key for \(target.name) contains an invalid line break."); continue
            }
            let destination = key.isEmpty ? trimmed : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + key
            let pipe = StreamPipe()
            let targetID = target.id
            pipe.onExit = { [weak self, weak pipe] status, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeStreamOutputs.removeAll { $0.id == targetID || $0.pipe === pipe }
                    pipe?.stop()
                    if self.activeStreamOutputs.isEmpty {
                        self.streaming = false
                        self.streamConfiguration = nil
                        if !self.recording && !self.microphoneReady { self.stopMicrophone() }
                        self.updateCaptureCadence()
                    }
                    if status != 0 {
                        self.failure = MediaFailure(code: .encoderFailed, operation: "Streaming (\(target.name))", message: "The encoder exited (status \(status)).", recovery: "Check the destination, network and selected encoder. If Apple encoding is unavailable, explicitly choose Software H.264.")
                    }
                }
            }
            pipe.onFailure = { [weak self, weak pipe] failure in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeStreamOutputs.removeAll { $0.id == targetID || $0.pipe === pipe }
                    pipe?.stop()
                    if self.activeStreamOutputs.isEmpty {
                        self.stopStreaming()
                    }
                    self.failure = failure
                }
            }
            do {
                try pipe.start(executable: executable, destination: destination, width: target.width, height: target.height, fps: target.fps, settings: settings, privateValues: [key, trimmed])
                let initialConfig = boundedConfiguration(target.configuration ?? outputConfiguration(vertical: target.vertical, fallback: config))
                let output = ActiveStreamOutput(destinationID: target.destinationID, name: target.name, pipe: pipe, width: target.width, height: target.height, fps: target.fps, isVertical: target.vertical, configuration: initialConfig)
                started.append(output)
            } catch {
                pipe.stop()
                failure = .classify(error, operation: "Streaming (\(target.name))", fallback: .encoderUnavailable)
            }
        }

        guard !started.isEmpty else {
            if failure == nil { failure = .invalid("No valid streaming destinations were able to start.") }
            return
        }

        activeStreamOutputs = started
        streamWidth = started.map(\.width).max() ?? 1280
        streamHeight = started.map(\.height).max() ?? 720
        streamFPS = started.map(\.fps).max() ?? 30
        streamConfiguration = started.first?.configuration
        lastStreamTime = 0
        updateCaptureBudget()
        if !recording { audioMixer.start(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
        streaming = true
        updateCaptureCadence()
        ensureMicrophone()
    }

    /// Single destination convenience caller preserving backward compatibility.
    func startStreaming(url: String, key: String, width: Int, height: Int, fps: Int, configuration: RenderConfiguration? = nil, settings: StreamEncodingSettings = StreamEncodingSettings()) {
        let isVertical = (configuration?.vertical ?? (height > width))
        let target = StreamTarget(destinationID: nil, name: "Stream", url: url, key: key, vertical: isVertical, width: width, height: height, fps: fps, configuration: configuration)
        startStreaming(targets: [target], settings: settings)
    }

    func stopStreaming() {
        drainAudio(until: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        let pipes = activeStreamOutputs.map(\.pipe)
        activeStreamOutputs.removeAll()
        streaming = false
        streamConfiguration = nil
        for pipe in pipes { pipe.stop() }
        updateCaptureCadence()
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

    private var capturePixelBudget = 0.0
    /// Keep native capture within 4x the largest active output's pixel count: enough detail for
    /// scaled layers without moving a full 4K desktop through composition for a smaller canvas.
    /// The budget never shrinks when streaming stops, so a session is not interrupted by re-selection.
    private func updateCaptureBudget() {
        var pixels = Double(config.width * config.height)
        if let secondary = secondaryConfig { pixels = max(pixels, Double(secondary.width * secondary.height)) }
        if streaming { pixels = max(pixels, Double(streamWidth * streamHeight)) }
        let budget = min(Double(3840 * 2160), pixels * 4)
        guard budget != capturePixelBudget else { return }
        capturePixelBudget = budget
        screenCapture.setPixelBudget(budget)
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

    /// Accumulates wall time spent in one render stage for the timing report.
    private func measured<T>(_ stage: String, _ body: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        stageNanos[stage, default: 0] &+= DispatchTime.now().uptimeNanoseconds &- start
        return result
    }

    private func publishRenderTiming(now: TimeInterval) {
        defer { stageNanos = [:]; timingWindowStart = now }
        guard timingWindowStart > 0, now > timingWindowStart else { renderTiming = [:]; return }
        let seconds = now - timingWindowStart
        renderTiming = stageNanos.mapValues { min(100, Double($0) / 1e9 / seconds * 100) }
    }

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
            let frame = measured("previewCompose") { compose(width: previewWidth, height: previewHeight) }
            if let frame {
                previewImage = frame
                preview = NSImage(cgImage: frame, size: NSSize(width: previewWidth, height: previewHeight))
            }
            if let secondaryConfig {
                let scale = min(1, previewLimit / Double(max(secondaryConfig.width, secondaryConfig.height)))
                let w = max(1, Int(Double(secondaryConfig.width) * scale)), h = max(1, Int(Double(secondaryConfig.height) * scale))
                let secondary = measured("previewCompose") { compose(configuration: secondaryConfig, width: w, height: h) }
                if let secondary { secondaryPreview = NSImage(cgImage: secondary, size: NSSize(width: w, height: h)) }
            }
            lastPreviewTime = now
            previewNeedsUpdate = false
        }
        if recording {
            elapsed = (recordingPaused ? recordingPauseStarted : now) - recordingStart - recordingPausedDuration
        }
        if recording || streaming, now - lastStatisticsTime >= 1 {
            if recording { recordingStatistics = recordingOutputs.map { $0.statistics(elapsed: elapsed) } }
            publishRenderTiming(now: now)
            lastStatisticsTime = now
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
                let buffer = measured("recordCompose") { compositionBuffer(configuration: configuration, width: output.width, height: output.height, pool: output.adaptor.pixelBufferPool) }
                guard let buffer else {
                    failure = MediaFailure(code: .frameAllocation, operation: "Recording", message: "Unable to allocate a video frame.", recovery: "Reduce resolution or close other memory-intensive apps, then start a new recording."); stopRecording(); break
                }
                if output.adaptor.append(buffer, withPresentationTime: time) { output.lastRecordedTime = time; output.submittedFrames += 1 }
                else { failure = output.writer.error.map { MediaFailure.classify($0, operation: "Recording video") } ?? MediaFailure(code: .encoderFailed, operation: "Recording", message: "A video frame could not be written.", recovery: "Check storage and encoder settings, then start a new recording."); stopRecording(); break }
            }
        }
        if streaming {
            for i in activeStreamOutputs.indices {
                let vertical = activeStreamOutputs[i].isVertical
                activeStreamOutputs[i].configuration = outputConfiguration(vertical: vertical, fallback: activeStreamOutputs[i].configuration)
            }
            if let first = activeStreamOutputs.first {
                streamConfiguration = first.configuration
            }

            let horizontalStreams = activeStreamOutputs.filter { !$0.isVertical }
            let verticalStreams = activeStreamOutputs.filter { $0.isVertical }

            func dispatch(streams: [ActiveStreamOutput], vertical: Bool) {
                guard let primary = streams.first, now - primary.lastStreamTime >= 1 / Double(primary.fps) else { return }
                for i in activeStreamOutputs.indices where activeStreamOutputs[i].isVertical == vertical {
                    activeStreamOutputs[i].lastStreamTime = now
                }
                let w = primary.width, h = primary.height
                let pinned = primary.configuration
                if let frame = (pinned == config && w == previewWidth && h == previewHeight ? previewImage : nil) ?? compose(configuration: pinned, width: w, height: h),
                   let buffer = pixelBuffer(image: frame, width: w, height: h) {
                    measured("streamPack") {
                        CVPixelBufferLockBaseAddress(buffer, .readOnly)
                        if let base = CVPixelBufferGetBaseAddress(buffer) {
                            let stride = CVPixelBufferGetBytesPerRow(buffer)
                            var bytes = Data(capacity: w * h * 4)
                            for row in 0..<h {
                                bytes.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: w * 4)
                            }
                            for stream in streams {
                                stream.pipe.send(bytes)
                            }
                        }
                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    }
                }
            }

            if !horizontalStreams.isEmpty { dispatch(streams: horizontalStreams, vertical: false) }
            if !verticalStreams.isEmpty { dispatch(streams: verticalStreams, vertical: true) }
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



}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
