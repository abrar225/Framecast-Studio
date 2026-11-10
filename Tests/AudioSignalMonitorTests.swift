import Testing
import Foundation
import Combine
@testable import VidystStudio

private struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor @Suite struct AudioSignalMonitorTests {
    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    @Test func meterStatesAndBoundedPublication() throws {
        let monitor = AudioSignalMonitor()
        var changes = 0
        let subscription = monitor.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        func refresh(_ now: Double, state: AudioCaptureState = .active, gain: Double = 0.5,
                     muted: Bool = false, captured: Bool = true, output: Bool = false, paused: Bool = false) {
            monitor.refresh(now: now, microphoneState: state, capturedState: .active,
                microphoneGain: gain, capturedGain: 1, microphoneMuted: muted,
                capturedEnabled: captured, microphoneReady: true, outputRunning: output, outputPaused: paused)
        }
        monitor.receive(AudioPacket(hostTime: 1, rate: 44100, channels: 1, samples: [0.25, -0.25]), input: .microphone, now: 1)
        try require(changes == 0, "Capture packets published observable state directly")
        refresh(1.1)
        try require(abs(monitor.snapshot.microphone.rmsDB - -18.06179974) < 0.001 && monitor.snapshot.microphone.receiving, "Meter does not show actual post-gain RMS")
        try require(monitor.snapshot.microphone.status == "Signal detected", "Audible packet was not identified")
        refresh(1.3, muted: true)
        try require(monitor.snapshot.microphone.level == 0 && monitor.snapshot.microphone.status.hasPrefix("Muted"), "Muted microphone shows a false output signal")
        refresh(1.5)
        try require(monitor.snapshot.microphone.level == 0 && monitor.snapshot.microphone.status == "No input data", "Meter froze after input stopped")
        refresh(1.7, state: .denied)
        try require(monitor.snapshot.microphone.status == "Microphone permission denied", "Denied access is shown as silence")
        refresh(1.9, state: .unavailable)
        try require(monitor.snapshot.microphone.status == "No input device available", "Missing device was not identified")
        monitor.receive(AudioPacket(hostTime: 2, rate: 44100, channels: 1, samples: [0, 0]), input: .microphone, now: 2)
        refresh(2.1)
        try require(monitor.snapshot.microphone.receiving && monitor.snapshot.microphone.status == "Receiving silence", "Captured silence is indistinguishable from missing input")
        refresh(2.3, captured: false)
        try require(!monitor.snapshot.captured.receiving && monitor.snapshot.captured.level == 0, "Disabled captured audio shows live signal")
        print("PASS actual RMS/gain, mute, fresh silence, stale input, denied access and unavailable-device states")

        monitor.receiveMixed(MixedAudioBlock(firstFrame: 0, samples: [32767, -32768]), now: 2.4)
        refresh(2.5, output: true)
        try require(monitor.snapshot.output.clipping && monitor.snapshot.output.level > 0.99, "Output mix does not reflect actual full-scale PCM/clipping")
        refresh(2.7, output: true, paused: true)
        try require(monitor.snapshot.output.status == "Recording paused" && monitor.snapshot.output.level == 0, "Paused output still shows recorded sound")
        refresh(2.9, output: false)
        try require(monitor.snapshot.output.status == "Start recording or streaming", "Stopped output shows active data")
        print("PASS actual mixed-PCM output level/clipping, pause and stopped-output states")

        let initialChanges = changes
        for index in 0..<240 {
            let now = 10 + Double(index) / 240
            monitor.receive(AudioPacket(hostTime: now, rate: 44100, channels: 1, samples: [Float(index + 1) / 500]), input: .microphone, now: now)
            refresh(now)
        }
        try require(changes - initialChanges <= 11 && changes - initialChanges >= 8, "Meter updates were not bounded near 10 Hz: \(changes - initialChanges)")
        print("PASS 240 incoming updates yield \(changes - initialChanges) meter publications; capture packets never publish directly")
    }
}
