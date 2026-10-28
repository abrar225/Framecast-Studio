import Foundation
import Darwin

/// One frame at most waits for FFmpeg. A slow network drops whole frames, never partial frames.
final class StreamPipe: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let diagnostics = Pipe()
    private let queue = DispatchQueue(label: "studio.rtmp.frames")
    private let capacity = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var stopped = false
    private var aborting = false
    private var recordedFailure: MediaFailure?
    var diagnosticText: String { lock.lock(); defer { lock.unlock() }; return tail }
    var failure: MediaFailure? { lock.lock(); defer { lock.unlock() }; return recordedFailure }
    private var tail = ""
    private var fifoDirectory: URL?
    private var audioFD: Int32 = -1
    private let audioQueue = DispatchQueue(label: "studio.rtmp.audio")
    private var pendingAudioBytes = 0
    private let maximumAudioBytes = AudioTimelineMixer.rate * 4 * 2
    private var privateValues: [String] = []
    var onFailure: (@Sendable (MediaFailure) -> Void)?
    var onExit: (@Sendable (Int32, String) -> Void)?
    func start(executable: String, destination: String, width: Int, height: Int, fps: Int, settings: StreamEncodingSettings = StreamEncodingSettings(), privateValues: [String] = []) throws {
        guard settings.isValid, MediaLimits.supports(width: width, height: height, fps: fps) else { throw MediaFailure.invalid("Streaming encoding preferences are invalid.") }
        self.privateValues = ([destination] + privateValues).filter { !$0.isEmpty }
        process.executableURL = URL(fileURLWithPath: executable)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Vidyst-stream-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fifoDirectory = directory
        let fifo = directory.appendingPathComponent("microphone.pcm")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw MediaFailure(code: .transportFailed, operation: "Streaming", message: "Cannot create private audio transport.", recovery: "Check temporary-folder permissions and restart the stream.") }
        audioFD = open(fifo.path, O_RDWR | O_NONBLOCK)
        guard audioFD >= 0 else { throw MediaFailure(code: .transportFailed, operation: "Streaming", message: "Cannot open private audio transport.", recovery: "Check temporary-folder permissions and restart the stream.") }
        _ = fcntl(audioFD, F_SETNOSIGPIPE, 1)
        let videoBitrate = settings.bitRate(width: width, height: height, fps: fps)
        let encoder = settings.encoder == .apple ? ["-c:v", "h264_videotoolbox", "-allow_sw", "0", "-realtime", "1", "-flags", "+low_delay", "-bf", "0"] : ["-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency"]
        process.arguments = ["-hide_banner", "-loglevel", "warning", "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(width)x\(height)", "-framerate", "\(fps)", "-use_wallclock_as_timestamps", "1", "-probesize", "32", "-analyzeduration", "1", "-i", "pipe:0", "-thread_queue_size", "64", "-f", "s16le", "-ar", "\(AudioTimelineMixer.rate)", "-ac", "2", "-probesize", "32", "-analyzeduration", "1", "-i", fifo.path] + encoder + ["-vf", "scale=in_range=pc:out_range=tv:out_color_matrix=bt709", "-pix_fmt", "yuv420p", "-fps_mode", "cfr", "-r", "\(fps)", "-color_range", "tv", "-b:v", "\(videoBitrate)", "-g", "\(fps * 2)", "-color_primaries", "bt709", "-color_trc", "iec61966-2-1", "-colorspace", "bt709", "-c:a", "aac", "-b:a", "\(settings.audioBitrateKbps)k", "-f", "flv", destination]

        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardError = diagnostics
        process.standardOutput = FileHandle.nullDevice
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            var text = self.tail + String(decoding: data, as: UTF8.self)
            for value in self.privateValues { text = text.replacingOccurrences(of: value, with: "[private destination]") }
            self.tail = String(text.suffix(1800))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock(); let text = self.tail; self.lock.unlock()
            self.onExit?(process.terminationStatus, text)
        }
        try process.run()
    }
    func send(_ data: Data) {
        guard let permit = CaptureDeliveryPermit.acquire(capacity) else { return }
        lock.lock(); let active = !stopped; lock.unlock()
        guard active else { return }
        queue.async { [weak self] in
            defer { permit.release() }
            guard let self else { return }
            do { try self.input.fileHandleForWriting.write(contentsOf: data) } catch { self.reportFailure(MediaFailure(code: .transportFailed, operation: "Streaming video", message: "The encoder stopped accepting video.", recovery: "Check the server connection and encoder selection, then restart the stream.")) }
        }
    }
    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !stopped, recordedFailure == nil else { lock.unlock(); return }
        guard data.count % 4 == 0, data.count <= maximumAudioBytes - pendingAudioBytes else {
            lock.unlock()
            reportFailure(MediaFailure(code: .transportFailed, operation: "Streaming audio", message: "The audio transport cannot keep up.", recovery: "Reduce output load or check the network, then restart the stream. No partial audio is silently discarded.")); return
        }
        pendingAudioBytes += data.count; lock.unlock()
        // Queued PCM retains its descriptor owner. Byte accounting bounds the
        // backlog to two seconds regardless of incoming block size.
        audioQueue.async { [self] in
            defer { lock.lock(); pendingAudioBytes -= data.count; lock.unlock() }
            lock.lock(); let descriptor = aborting ? -1 : audioFD; lock.unlock()
            guard descriptor >= 0 else { return }
            do {
                try PCMTransport.write(data, to: descriptor) {
                    self.lock.lock(); defer { self.lock.unlock() }; return self.aborting
                }
            } catch let failure as MediaFailure { reportFailure(failure) }
            catch { reportFailure(.classify(error, operation: "Streaming audio", fallback: .transportFailed)) }
        }
    }
    private func reportFailure(_ failure: MediaFailure) {
        lock.lock()
        guard !stopped, recordedFailure == nil else { lock.unlock(); return }
        recordedFailure = failure; lock.unlock()
        onFailure?(failure)
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true; lock.unlock()
        // Close producer ends after admitted writes. Give FFmpeg EOF so it can
        // flush its encoders rather than truncating the stream immediately.
        DispatchQueue.global(qos: .utility).async { [self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 0.75
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                lock.lock(); aborting = true; lock.unlock()
                process.terminate(); process.waitUntilExit()
            }
            // This owner remains retained until exit/cleanup, including timeout.
        }
        diagnostics.fileHandleForReading.readabilityHandler = nil
        queue.async { [self] in try? input.fileHandleForWriting.close() }
        audioQueue.async { [self] in
            lock.lock(); let descriptor = audioFD; audioFD = -1; lock.unlock()
            if descriptor >= 0 { close(descriptor) }
            if let directory = fifoDirectory { try? FileManager.default.removeItem(at: directory) }
        }
    }
    deinit {
        if process.isRunning { process.terminate() }
        if audioFD >= 0 { close(audioFD) }
        if let directory = fifoDirectory { try? FileManager.default.removeItem(at: directory) }
    }
}


/// Nonblocking stereo PCM transport either writes the complete block in order
/// within its bounded deadline, or reports failure. It never skips a remainder.
enum PCMTransport {
    static func write(_ data: Data, to descriptor: Int32, isCancelled: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var position = 0
            while position < bytes.count {
                guard !isCancelled(), ProcessInfo.processInfo.systemUptime < deadline else {
                    throw MediaFailure(code: .transportFailed, operation: "Streaming audio", message: "Audio transport was interrupted or stalled.", recovery: "Reduce output load or check the destination, then restart the stream.")
                }
                let result = Darwin.write(descriptor, base.advanced(by: position), min(2048, bytes.count - position))
                if result > 0 { position += result; continue }
                if result < 0 && errno == EINTR { continue }
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&ready, 1, 10); continue
                }
                throw MediaFailure(code: .transportFailed, operation: "Streaming audio", message: "Audio transport closed (OS error \(errno)).", recovery: "Check the encoder and destination, then restart the stream.")
            }
        }
    }
}
