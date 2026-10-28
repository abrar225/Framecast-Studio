import Foundation
import Combine

enum AudioCaptureState: Equatable {
    case inactive, starting, active, denied, unavailable, failed
}

struct AudioMeterReading: Equatable {
    var rmsDB = -60.0
    var peakDB = -60.0
    var status = "Not started"
    var receiving = false
    var clipping = false
    var level: Double { (rmsDB + 60) / 60 }
    var peak: Double { (peakDB + 60) / 60 }
}

struct AudioMeterSnapshot: Equatable {
    var microphone = AudioMeterReading()
    var captured = AudioMeterReading(status: "Share a source and enable captured audio")
    var output = AudioMeterReading(status: "Start recording or streaming")
    var microphoneReady = false
}

/// Only this small observable owner publishes meter updates. Capture packets never
/// republish the project or the complete engine merely to animate an audio indicator.
@MainActor final class AudioSignalMonitor: ObservableObject {
    @Published private(set) var snapshot = AudioMeterSnapshot()
    private struct Signal {
        var rms = 0.0
        var peak = 0.0
        var arrival: Double?
    }
    private var signals = [Signal(), Signal()]
    private var outputSignal = Signal()
    private var lastRefresh = -Double.infinity
    func receive(_ packet: AudioPacket, input: AudioInput, now: Double) {
        guard !packet.samples.isEmpty else { return }
        var sum = 0.0, peak = 0.0
        for sample in packet.samples {
            let value = sample.isFinite ? abs(Double(sample)) : 0
            sum += value * value; peak = max(peak, value)
        }
        signals[input.rawValue] = Signal(rms: sqrt(sum / Double(packet.samples.count)), peak: peak, arrival: now)
    }
    func receiveMixed(_ block: MixedAudioBlock, now: Double) {
        guard !block.samples.isEmpty else { return }
        var sum = 0.0, peak = 0.0
        for sample in block.samples {
            let value = abs(Double(sample)) / 32768
            sum += value * value; peak = max(peak, value)
        }
        outputSignal = Signal(rms: sqrt(sum / Double(block.samples.count)), peak: peak, arrival: now)
    }
    func clear(_ input: AudioInput) { signals[input.rawValue] = Signal() }
    func refresh(now: Double, microphoneState: AudioCaptureState, capturedState: AudioCaptureState,
                 microphoneGain: Double, capturedGain: Double, microphoneMuted: Bool,
                 capturedEnabled: Bool, microphoneReady: Bool, outputRunning: Bool = false, outputPaused: Bool = false) {
        guard now - lastRefresh >= 0.1 else { return }
        lastRefresh = now
        func reading(_ signal: Signal, state: AudioCaptureState, gain: Double, muted: Bool, inactiveText: String) -> AudioMeterReading {
            switch state {
            case .inactive: return AudioMeterReading(status: inactiveText)
            case .starting: return AudioMeterReading(status: "Starting input…")
            case .denied: return AudioMeterReading(status: "Microphone permission denied")
            case .unavailable: return AudioMeterReading(status: "No input device available")
            case .failed: return AudioMeterReading(status: "Input unavailable — check capture settings")
            case .active: break
            }
            let gain = gain.isFinite ? min(4, max(0, gain)) : 0
            if muted { return AudioMeterReading(status: "Muted — unmute to view levels") }
            if gain <= 0 { return AudioMeterReading(status: "Volume is zero") }
            guard let arrival = signal.arrival, now - arrival < 0.35 else {
                return AudioMeterReading(status: signal.arrival == nil ? "Waiting for input…" : "No input data")
            }
            let rms = signal.rms * gain, peak = signal.peak * gain
            func db(_ value: Double) -> Double { value > 0 ? max(-60, min(0, 20 * log10(value))) : -60 }
            let detected = rms > 0.001
            return AudioMeterReading(rmsDB: db(rms), peakDB: db(peak),
                status: peak >= 32767.0/32768 ? "Clipping — lower the volume" : detected ? "Signal detected" : "Receiving silence",
                receiving: true, clipping: peak >= 32767.0/32768)
        }
        let next = AudioMeterSnapshot(
            microphone: reading(signals[0], state: microphoneState, gain: microphoneGain, muted: microphoneMuted, inactiveText: microphoneMuted ? "Microphone muted; unmute to see its level" : "Enable microphone to see its level"),
            captured: reading(signals[1], state: capturedEnabled ? capturedState : .inactive, gain: capturedGain, muted: false, inactiveText: "Share a source and enable captured audio"),
            output: reading(outputSignal, state: outputRunning && !outputPaused ? .active : .inactive, gain: 1, muted: false, inactiveText: outputPaused ? "Recording paused" : "Start recording or streaming"),
            microphoneReady: microphoneReady)
        if next != snapshot { snapshot = next }
    }
}
