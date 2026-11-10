import Testing
import Foundation
@testable import VidystStudio

private struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor private final class Input {
    let id: Int
    init(_ id: Int) { self.id = id }
}

@MainActor private final class Driver {
    var made: [Int] = []
    var stops: [Int] = []
    var heldStarts: Set<Int> = []
    var heldStops: Set<Int> = []
    var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    var stopWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    var badMake: Set<Int> = []
    var badStart: Set<Int> = []
    var badStop: Set<Int> = []
    lazy var owner = CaptureReplacement<Int, Input>(make: { [self] id in
        made.append(id)
        if badMake.contains(id) { throw Failure(message: "make \(id)") }
        return Input(id)
    }, start: { [self] input in
        if heldStarts.contains(input.id) { await withCheckedContinuation { startWaiters[input.id] = $0 } }
        if badStart.contains(input.id) { throw Failure(message: "start \(input.id)") }
    }, stop: { [self] input in
        stops.append(input.id)
        if heldStops.contains(input.id) { await withCheckedContinuation { stopWaiters[input.id] = $0 } }
        if badStop.contains(input.id) { throw Failure(message: "stop \(input.id)") }
    })
}

@MainActor @Suite struct CaptureLifecycleTests {
    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure(message: "Lifecycle did not settle")
    }

    @Test func replacementFailuresSupersedeStopAndStaleCallbacks() async throws {
        let d = Driver()
        d.owner.stopAll()
        try require(!d.owner.working, "Idle shutdown unnecessarily schedules asynchronous cleanup")
        d.owner.select(1); try await until { !d.owner.working }
        try require(d.owner.active?.id == 1, "Initial input was not adopted")
        d.badMake = [2]; d.owner.select(2); try await until { !d.owner.working }
        try require(d.owner.active?.id == 1 && d.stops.isEmpty, "Construction failure stopped the working input")
        d.badStart = [3]; d.owner.select(3); try await until { !d.owner.working }
        try require(d.owner.active?.id == 1 && d.stops == [3], "Start failure lost the old input or failed candidate ownership")
        print("PASS failed creation/start retain the working capture and clean failed candidates")

        d.heldStarts = [4, 6]; d.owner.select(4)
        try await until { d.startWaiters[4] != nil }
        d.owner.select(5); d.owner.select(6)
        try require(d.owner.active?.id == 1, "Pending selection replaced the input before startup")
        d.startWaiters.removeValue(forKey: 4)?.resume()
        try await until { d.startWaiters[6] != nil }
        try require(!d.made.contains(5) && d.stops.contains(4) && d.owner.active?.id == 1, "Superseded selection was adopted or unbounded selections started")
        d.startWaiters.removeValue(forKey: 6)?.resume()
        try await until { !d.owner.working }
        try require(d.owner.active?.id == 6 && d.stops.contains(1), "Replacement did not transfer ownership after successful startup")
        print("PASS rapid changes coalesce, stale completion is retired, old capture survives until success")

        d.badStop = [6]; d.owner.stopAll(); try await until { !d.owner.working }
        try require(d.owner.active == nil && d.owner.retired.map(\.id) == [6], "Cleanup failure lost resource ownership")
        d.badStop = []; d.owner.stopAll(); try await until { !d.owner.working }
        try require(d.owner.retired.isEmpty && d.stops.filter { $0 == 6 }.count == 2, "Explicit cleanup retry did not retain and stop the resource")

        d.heldStarts.insert(7); d.owner.select(7)
        try await until { d.startWaiters[7] != nil }
        d.owner.stopAll(); d.startWaiters.removeValue(forKey: 7)?.resume()
        try await until { !d.owner.working }
        try require(d.owner.active == nil && d.stops.contains(7), "Late startup resurrected capture after Stop")
        print("PASS stop during startup, failed cleanup retention, and retry")

        d.owner.select(8); try await until { !d.owner.working }
        let failed = d.owner.active!
        d.owner.didFail(failed, message: "source closed")
        try await until { !d.owner.working }
        d.owner.select(9); try await until { !d.owner.working }
        d.owner.didFail(failed, message: "late callback")
        try require(d.owner.active?.id == 9, "Stale failure cleared the new capture")

        d.heldStops = [9]; d.owner.stopAll()
        try await until { d.stopWaiters[9] != nil }
        d.owner.select(10)
        d.stopWaiters.removeValue(forKey: 9)?.resume()
        try await until { !d.owner.working }
        try require(d.owner.active?.id == 10 && d.owner.retired.isEmpty, "Selection arriving during final cleanup was lost")
        d.owner.stopAll(); try await until { !d.owner.working }
        print("PASS stale failure isolation and selection during final cleanup")
    }
}
