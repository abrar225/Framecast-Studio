import Testing
import Foundation
import AVFoundation
import Darwin
@testable import VidystStudio

private struct CheckFailure: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private enum Check {
    static func require(_ value: @autoclosure () -> Bool, _ text: String) throws {
        guard value() else { throw CheckFailure(text: text) }
    }
}

private final class Received: @unchecked Sendable {
    var data = Data() // One writer; main reads only after completion semaphore.
}

@Suite struct MediaFailureTests {
    private func descriptors() -> [Int32] {
        var pair: [Int32] = [0, 0]; precondition(Darwin.pipe(&pair) == 0)
        _ = fcntl(pair[1], F_SETFL, O_NONBLOCK); _ = fcntl(pair[1], F_SETNOSIGPIPE, 1)
        return pair
    }

    @Test func failureClassificationAndBoundedPipeTransport() throws {
        let folder = FileManager.default.temporaryDirectory
        do { try RecordingStorage.preflight(directory: folder, bitRate: 80_000_000, availableBytes: 0); try Check.require(false, "Low-space preflight passed") }
        catch let failure as MediaFailure { try Check.require(failure.code == .storageFull && !failure.recovery.isEmpty, "Low-space error lost code/recovery") }
        let nested = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)])
        try Check.require(MediaFailure.classify(nested, operation: "Record").code == .storageFull, "Underlying disk-full failure was lost")
        let permission = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        try Check.require(MediaFailure.classify(permission, operation: "Record").code == .storagePermission, "Permission classification failed")
        try Check.require(MediaFailure.classify(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue), operation: "Record").code == .storageFull, "Native AV disk-full reason was lost")
        try Check.require(MediaFailure.classify(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.encoderNotFound.rawValue), operation: "Record").code == .encoderUnavailable, "Native encoder reason was lost")
        print("PASS low-space admission and nested disk-full/permission failures preserve code and recovery")

        let pair = descriptors(), received = Received(), done = DispatchSemaphore(value: 0)
        let payload = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        DispatchQueue.global().async {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while received.data.count < payload.count {
                let count = Darwin.read(pair[0], &bytes, bytes.count)
                if count <= 0 { break }; received.data.append(contentsOf: bytes.prefix(count))
            }
            done.signal()
        }
        try PCMTransport.write(payload, to: pair[1], isCancelled: { false })
        try Check.require(done.wait(timeout: .now() + 1) == .success, "PCM consumer did not drain")
        try Check.require(received.data == payload, "Partial transport corrupted PCM bytes/order")
        close(pair[0]); close(pair[1])
        print("PASS actual nonblocking pipe writes complete128KiB ordered PCM through backpressure")

        let stalled = descriptors(), start = ProcessInfo.processInfo.systemUptime
        do { try PCMTransport.write(Data(repeating: 0, count: 256 * 1024), to: stalled[1], isCancelled: { false }); try Check.require(false, "Stalled pipe silently accepted/dropped payload") }
        catch let failure as MediaFailure { try Check.require(failure.code == .transportFailed, "Stall was not classified") }
        try Check.require(ProcessInfo.processInfo.systemUptime - start < 1.5, "Stall exceeded bounded cleanup budget")
        close(stalled[0]); close(stalled[1])
        let cancelled = descriptors()
        do { try PCMTransport.write(Data(repeating: 0, count: 4), to: cancelled[1], isCancelled: { true }); try Check.require(false, "Cancelled transport wrote input") }
        catch let failure as MediaFailure { try Check.require(failure.code == .transportFailed, "Cancellation lost transport reason") }
        close(cancelled[0]); close(cancelled[1])
        let broken = descriptors(); close(broken[0])
        do { try PCMTransport.write(Data(repeating: 0, count: 4), to: broken[1], isCancelled: { false }); try Check.require(false, "Closed pipe succeeded") }
        catch let failure as MediaFailure { try Check.require(failure.code == .transportFailed, "Closed pipe reason lost") }
        close(broken[1])
        print("PASS real stalled/closed pipes and cancellation fail explicitly within bounded time without SIGPIPE")
    }
}
