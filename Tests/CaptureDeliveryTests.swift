import Foundation

private final class Owner {
    let capacity = DispatchSemaphore(value: 1)
}

@main private enum CaptureDeliveryTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("VERDICT: FAIL -- \(message)\n", stderr); exit(1) }
    }
    static func earlyReturn(_ capacity: DispatchSemaphore) {
        guard let permit = CaptureDeliveryPermit.acquire(capacity) else { return }
        withExtendedLifetime(permit) {} // Invalid payload/no consumer: no transfer.
    }
    static func main() {
        let capacity = DispatchSemaphore(value: 1)
        earlyReturn(capacity)
        guard let first = CaptureDeliveryPermit.acquire(capacity) else { fatalError("Early return leaked capacity") }
        require(CaptureDeliveryPermit.acquire(capacity) == nil, "More than one delivery was admitted")
        first.release()
        guard let second = CaptureDeliveryPermit.acquire(capacity) else { fatalError("Release failed") }
        first.release()
        require(CaptureDeliveryPermit.acquire(capacity) == nil, "Repeated release overfilled capacity")
        second.release()
        print("PASS invalid/no-consumer return restores capacity; admission bounded; release exactly once")

        let queue = DispatchQueue(label: "test.capture.held-delivery")
        queue.suspend()
        var owner: Owner? = Owner()
        weak var weakOwner = owner
        weak var weakSemaphore = owner!.capacity
        do {
            let permit = CaptureDeliveryPermit.acquire(owner!.capacity)!
            queue.async { [weak owner] in
                defer { permit.release() }
                guard owner != nil else { return }
                fatalError("Owner should already be gone")
            }
        }
        owner = nil
        require(weakOwner == nil, "Queued delivery retained its owner")
        require(weakSemaphore != nil, "Permit did not retain acquired semaphore")
        queue.resume()
        queue.sync {}
        require(weakSemaphore == nil, "Semaphore leaked after ownerless delivery")
        print("PASS late delivery after owner destruction releases its independently retained semaphore without crash")

        let cancelledCapacity = DispatchSemaphore(value: 1)
        var cancelled: (() -> Void)?
        do {
            let permit = CaptureDeliveryPermit.acquire(cancelledCapacity)!
            cancelled = { permit.release() }
        }
        require(cancelled != nil, "Missing pending delivery")
        cancelled = nil
        guard let restored = CaptureDeliveryPermit.acquire(cancelledCapacity) else { fatalError("Discarded delivery leaked capacity") }
        restored.release()
        print("PASS discarded queued payload restores capacity through permit destruction")
        print("VERDICT: PASS")
    }
}
