import Foundation

/// Owns one acquired slot independently of the capture/stream owner. A queued
/// delivery must carry this permit so owner loss and early returns still release
/// capacity before the semaphore itself can be destroyed.
final class CaptureDeliveryPermit: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var released = false

    private init(_ semaphore: DispatchSemaphore) { self.semaphore = semaphore }
    static func acquire(_ semaphore: DispatchSemaphore) -> CaptureDeliveryPermit? {
        guard semaphore.wait(timeout: .now()) == .success else { return nil }
        return CaptureDeliveryPermit(semaphore)
    }
    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        semaphore.signal()
    }
    deinit { release() }
}
