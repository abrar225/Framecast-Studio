import Testing
import Foundation
@testable import VidystStudio

private struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

private final class Owner {
    let capacity = DispatchSemaphore(value: 1)
}

@Suite struct CaptureDeliveryTests {
    private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(message: message) }
    }

    private func earlyReturn(_ capacity: DispatchSemaphore) {
        guard let permit = CaptureDeliveryPermit.acquire(capacity) else { return }
        withExtendedLifetime(permit) {} // Invalid payload/no consumer: no transfer.
    }

    @Test func permitAdmissionReleaseAndOwnerlessDelivery() throws {
        let capacity = DispatchSemaphore(value: 1)
        earlyReturn(capacity)
        guard let first = CaptureDeliveryPermit.acquire(capacity) else { throw Failure(message: "Early return leaked capacity") }
        try require(CaptureDeliveryPermit.acquire(capacity) == nil, "More than one delivery was admitted")
        first.release()
        guard let second = CaptureDeliveryPermit.acquire(capacity) else { throw Failure(message: "Release failed") }
        first.release()
        try require(CaptureDeliveryPermit.acquire(capacity) == nil, "Repeated release overfilled capacity")
        second.release()
        print("PASS invalid/no-consumer return restores capacity; admission bounded; release exactly once")

        let queue = DispatchQueue(label: "test.capture.held-delivery")
        queue.suspend()
        var owner: Owner? = Owner()
        weak let weakOwner = owner
        weak let weakSemaphore = owner!.capacity
        do {
            let permit = CaptureDeliveryPermit.acquire(owner!.capacity)!
            queue.async { [weak owner] in
                defer { permit.release() }
                guard owner != nil else { return }
                fatalError("Owner should already be gone")
            }
        }
        owner = nil
        try require(weakOwner == nil, "Queued delivery retained its owner")
        try require(weakSemaphore != nil, "Permit did not retain acquired semaphore")
        queue.resume()
        queue.sync {}
        try require(weakSemaphore == nil, "Semaphore leaked after ownerless delivery")
        print("PASS late delivery after owner destruction releases its independently retained semaphore without crash")

        let cancelledCapacity = DispatchSemaphore(value: 1)
        var cancelled: (() -> Void)?
        do {
            let permit = CaptureDeliveryPermit.acquire(cancelledCapacity)!
            cancelled = { permit.release() }
        }
        try require(cancelled != nil, "Missing pending delivery")
        cancelled = nil
        guard let restored = CaptureDeliveryPermit.acquire(cancelledCapacity) else { throw Failure(message: "Discarded delivery leaked capacity") }
        restored.release()
        print("PASS discarded queued payload restores capacity through permit destruction")
    }
}
