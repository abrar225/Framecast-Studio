import AppKit
import ScreenCaptureKit
import Combine

enum CaptureSizing {
    /// Capture source pixels, rather than logical desktop points. Preserve portrait and ultrawide
    /// aspect ratios with the same 4K pixel budget as the compositor; never upscale small displays.
    static func dimensions(contentSize: CGSize, pointPixelScale: Double) -> (width: Int, height: Int) {
        let scale = pointPixelScale.isFinite && pointPixelScale > 0 ? pointPixelScale : 1
        let w = Double(contentSize.width) * scale, h = Double(contentSize.height) * scale
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return (2, 2) }
        let reduction = min(1, 3840 / w, 3840 / h, sqrt(Double(3840 * 2160) / (w * h)))
        return (max(2, Int(w * reduction) / 2 * 2), max(2, Int(h * reduction) / 2 * 2))
    }

}

/// One pending selection and one starting resource. A working input remains owned until
/// its replacement starts; failed cleanup stays owned for the next explicit retry.
@MainActor final class CaptureReplacement<Selection, Resource: AnyObject> {
    private(set) var active: Resource?
    private(set) var retired: [Resource] = []
    private(set) var working = false
    var changed: () -> Void = {}
    var failed: (String) -> Void = { _ in }
    private let make: (Selection) throws -> Resource
    private let start: (Resource) async throws -> Void
    private let stop: (Resource) async throws -> Void
    private var revision = UUID()
    private var pending: (UUID, Selection)?
    private var starting: Resource?
    private var startingFailure: String?

    init(make: @escaping (Selection) throws -> Resource,
         start: @escaping (Resource) async throws -> Void,
         stop: @escaping (Resource) async throws -> Void) {
        self.make = make; self.start = start; self.stop = stop
    }
    func select(_ selection: Selection) {
        revision = UUID(); pending = (revision, selection); run()
    }
    func stopAll() {
        revision = UUID(); pending = nil
        if let active { retire(active); self.active = nil }
        changed(); run()
    }
    func didFail(_ resource: Resource, message: String) {
        if starting === resource { startingFailure = message; return }
        guard active === resource else { return }
        active = nil; retire(resource); changed(); failed(message); run()
    }
    func didFail(matching predicate: (Resource) -> Bool, message: String) {
        if let starting, predicate(starting) { didFail(starting, message: message) }
        else if let active, predicate(active) { didFail(active, message: message) }
    }
    private func retire(_ resource: Resource) {
        if !retired.contains(where: { $0 === resource }) { retired.append(resource) }
    }
    private func run() {
        guard !working else { return }
        guard pending != nil || !retired.isEmpty else { return }
        working = true; changed()
        Task { @MainActor in
            repeat {
                if let (ticket, selection) = pending {
                    pending = nil
                    do {
                        let candidate = try make(selection)
                        starting = candidate; startingFailure = nil
                        do {
                            try await start(candidate)
                            if ticket == revision, startingFailure == nil {
                                if let active { retire(active) }
                                active = candidate; changed()
                            } else { retire(candidate) }
                            if ticket == revision, let message = startingFailure { failed(message) }
                        } catch {
                            retire(candidate)
                            if ticket == revision { failed(error.localizedDescription) }
                        }
                        starting = nil; startingFailure = nil
                    } catch { if ticket == revision { failed(error.localizedDescription) } }
                }
                // Snapshot avoids losing resources retired while an asynchronous stop is running.
                for resource in retired {
                    do {
                        try await stop(resource)
                        retired.removeAll { $0 === resource }
                    } catch { failed("Capture cleanup needs a retry: \(error.localizedDescription)") }
                }
            } while pending != nil
            working = false; changed()
        }
    }
}

private final class ScreenFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var frame: (@Sendable (CGImage, SCStream, CaptureDeliveryPermit) -> Void)?
    var failure: (@Sendable (SCStream, String) -> Void)?
    var audio: (@Sendable (CMSampleBuffer, SCStream, CaptureDeliveryPermit) -> Void)?
    let audioCapacity = DispatchSemaphore(value: 8)
    let capacity = DispatchSemaphore(value: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard let permit = CaptureDeliveryPermit.acquire(audioCapacity) else { return }
            audio?(sampleBuffer, stream, permit)
            return
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let permit = CaptureDeliveryPermit.acquire(capacity) else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        if let cg = context.createCGImage(image, from: image.extent) { frame?(cg, stream, permit) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failure?(stream, error.localizedDescription) }
}

private final class NativeScreenInput {
    let stream: SCStream
    let filter: SCContentFilter
    let includesAudio: Bool
    let frameRate: Int
    init(stream: SCStream, filter: SCContentFilter, includesAudio: Bool, frameRate: Int) {
        self.stream = stream; self.filter = filter; self.includesAudio = includesAudio; self.frameRate = frameRate
    }
}

/// System-owned selection filters are ephemeral. Window IDs/PIDs and picker grants are
/// never serialized or reused as identity after relaunch.
@MainActor final class ScreenCaptureSession: NSObject, SCContentSharingPickerObserver {
    var frame: (CGImage) -> Void = { _ in }
    var changed: (Bool, Bool, Bool) -> Void = { _, _, _ in }
    var audio: (CMSampleBuffer) -> Void = { _ in }
    var failed: (String) -> Void = { _ in }
    private static var diagnosticOwners: [UUID: ScreenCaptureSession] = [:]
    private var diagnosticID: UUID?
    private let receiver = ScreenFrameReceiver()
    private let queue = DispatchQueue(label: "studio.screen", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "studio.screen.audio", qos: .userInitiated)
    private var observing = false
    private var enabled = false
    private var includeAudio = false
    private var frameRate = 30
    private var configurationChangePending = false
    private lazy var replacement = CaptureReplacement<SCContentFilter, NativeScreenInput>(make: { [weak self, receiver = self.receiver, queue = self.queue, audioQueue = self.audioQueue] filter in
        let settings = SCStreamConfiguration()
        let size = CaptureSizing.dimensions(contentSize: filter.contentRect.size, pointPixelScale: Double(filter.pointPixelScale))
        settings.width = size.width; settings.height = size.height
        settings.captureResolution = .best; settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.preservesAspectRatio = true; settings.ignoreShadowsSingleWindow = true
        settings.minimumFrameInterval = CMTime(value: 1, timescale: Int32(self?.frameRate ?? 30))
        settings.queueDepth = 3; settings.showsCursor = true
        settings.capturesAudio = self?.includeAudio ?? false
        settings.sampleRate = 48000; settings.channelCount = 2
        settings.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: filter, configuration: settings, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        if settings.capturesAudio { try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: audioQueue) }
        return NativeScreenInput(stream: stream, filter: filter, includesAudio: settings.capturesAudio, frameRate: self?.frameRate ?? 30)
    }, start: { try await $0.stream.startCapture() }, stop: { try await $0.stream.stopCapture() })

    override init() {
        super.init()
        replacement.changed = { [weak self] in
            guard let self else { return }
            self.changed(self.replacement.active != nil, self.replacement.working, self.replacement.active?.includesAudio ?? false)
            if let id = self.diagnosticID, !self.replacement.working, self.replacement.active == nil, self.replacement.retired.isEmpty {
                Self.diagnosticOwners.removeValue(forKey: id)
            }
            if !self.replacement.working, self.configurationChangePending {
                self.configurationChangePending = false
                if let active = self.replacement.active, (active.includesAudio != self.includeAudio || active.frameRate != self.frameRate) { self.replacement.select(active.filter) }
            }
        }
        replacement.failed = { [weak self] in self?.failed($0) }
        receiver.frame = { [weak self] image, stream, permit in
            Task { @MainActor in
                defer { permit.release() }
                guard let self else { return }
                guard self.replacement.active?.stream === stream else { return }
                self.frame(image)
            }
        }
        receiver.failure = { [weak self] stream, message in
            Task { @MainActor in self?.replacement.didFail(matching: { $0.stream === stream }, message: message) }
        }
        receiver.audio = { [weak self] sample, stream, permit in
            Task { @MainActor in
                defer { permit.release() }
                guard let self else { return }
                guard self.replacement.active?.stream === stream, self.replacement.active?.includesAudio == true else { return }
                self.audio(sample)
            }
        }
    }
    /// Uses the same capture/receiver/replacement path as the studio. It saves
    /// metadata only and refuses to trigger a first-time permission prompt.
    static func probePermittedDisplay(includeAudio: Bool) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw MediaFailure(code: .inputPermission, operation: "Screen probe", message: "Screen Recording access is not already granted.", recovery: "Enable Framecast Studio in System Settings and restart it before running this diagnostic.")
        }
        for owner in diagnosticOwners.values { owner.stop() }
        for _ in 0..<200 where !diagnosticOwners.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        guard diagnosticOwners.isEmpty else { throw MediaFailure(code: .captureFailed, operation: "Screen probe", message: "Previous capture cleanup is still owned and pending.", recovery: "Retry cleanup or restart Framecast before probing again.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw MediaFailure(code: .inputUnavailable, operation: "Screen probe", message: "The main display is unavailable.", recovery: "Check the display connection and try again.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let expected = CaptureSizing.dimensions(contentSize: filter.contentRect.size, pointPixelScale: Double(filter.pointPixelScale))
        let owner = ScreenCaptureSession(), id = UUID()
        owner.diagnosticID = id; diagnosticOwners[id] = owner
        owner.setFrameRate(60); owner.setIncludeAudio(includeAudio)
        var frames = 0, width = 0, height = 0, audioPackets = 0, audioFrames = 0
        var audioRate = 0.0, captureError: String?
        owner.frame = { image in frames += 1; width = image.width; height = image.height }
        owner.audio = { sample in
            audioPackets += 1; audioFrames += CMSampleBufferGetNumSamples(sample)
            if let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) { audioRate = asbd.pointee.mSampleRate }
        }
        owner.failed = { captureError = $0 }
        owner.replacement.select(filter)
        defer { owner.stop() }
        for _ in 0..<150 {
            if !owner.replacement.working { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard owner.replacement.active != nil else { throw MediaFailure(code: .captureFailed, operation: "Screen probe", message: captureError ?? "Native capture did not start.", recovery: "Check Screen Recording access and display availability.") }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        owner.stop()
        for _ in 0..<150 {
            if !owner.replacement.working { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard owner.replacement.retired.isEmpty, !owner.replacement.working else { throw MediaFailure(code: .captureFailed, operation: "Screen probe", message: "Capture cleanup remains pending and retained.", recovery: "Retry this diagnostic to retry cleanup, or restart Framecast.") }
        guard frames > 0, width == expected.width, height == expected.height else { throw MediaFailure(code: .captureFailed, operation: "Screen probe", message: "No valid native-sized frames were received.", recovery: "Check the display and Screen Recording permission.") }
        return ["permissionAlreadyGranted": true, "capturedWidth": width, "capturedHeight": height, "receivedVideoFrames": frames,
                "requestedMaximumFPS": 60, "sourceMayBeIdle": true, "capturedAudioEnabled": includeAudio, "receivedAudioPackets": audioPackets,
                "receivedAudioFrames": audioFrames, "audioSampleRate": audioRate, "captureStopped": true, "imagesOrAudioSaved": false]
    }
    func setFrameRate(_ value: Int) {
        let value = min(60, max(1, value))
        guard frameRate != value else { return }
        frameRate = value
        if replacement.working { configurationChangePending = true }
        else if let active = replacement.active { replacement.select(active.filter) }
    }
    func setIncludeAudio(_ value: Bool) {
        guard includeAudio != value else { return }
        includeAudio = value
        if replacement.working { configurationChangePending = true }
        else if let active = replacement.active { replacement.select(active.filter) }
    }
    func present() {
        let picker = SCContentSharingPicker.shared
        if !observing { picker.add(self); observing = true }
        var settings = SCContentSharingPickerConfiguration()
        settings.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        settings.excludedBundleIDs = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        settings.allowsChangingSelectedContent = true
        picker.defaultConfiguration = settings; picker.maximumStreamCount = 1
        enabled = true; picker.isActive = true
        if let stream = replacement.active { picker.present(for: stream.stream) } else { picker.present() }
    }
    func stop() {
        enabled = false; configurationChangePending = false
        if observing {
            let picker = SCContentSharingPicker.shared
            picker.isActive = false; picker.remove(self); observing = false
        }
        replacement.stopAll()
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // Cancellation leaves the current capture and its selection unchanged.
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.enabled, stream == nil || self.replacement.active?.stream === stream else { return }
            self.replacement.select(filter)
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in if self.enabled { self.failed("Screen chooser: \(error.localizedDescription)") } }
    }
}
