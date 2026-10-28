import SwiftUI
import AppKit

struct AudioMixerPanel: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    @ObservedObject private var levels: AudioSignalMonitor
    var showSettingsButton = true
    init(model: StudioModel, engine: MediaEngine, showSettingsButton: Bool = true) {
        self.model = model; self.engine = engine; self.levels = engine.audioLevels; self.showSettingsButton = showSettingsButton
    }
    private var microphoneChoices: [(String, String)] {
        var result = [("", "System default")] + engine.microphoneOptions.map { ($0.id, $0.name) }
        let saved = model.project.microphoneDeviceID
        if !result.contains(where: { $0.0 == saved }) { result.append((saved, "Saved input · " + saved)) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            channel {
                HStack {
                    Label("Microphone", systemImage: "mic.fill").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        model.project.microphoneMuted.toggle(); engine.microphoneEnabled = !model.project.microphoneMuted
                    } label: {
                        Label(model.project.microphoneMuted ? "Muted" : "Unmuted", systemImage: model.project.microphoneMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).frame(height: 27)
                            .foregroundStyle(model.project.microphoneMuted ? StudioPalette.coral : StudioPalette.gold)
                            .background((model.project.microphoneMuted ? StudioPalette.coral : StudioPalette.gold).opacity(0.1))
                            .clipShape(Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(model.project.microphoneMuted ? "Unmute microphone" : "Mute microphone")
                }
                StudioMenuField(title: "Microphone device", options: microphoneChoices,
                    selection: Binding(get: { model.project.microphoneDeviceID }, set: {
                        model.project.microphoneDeviceID = $0; engine.selectedMicrophone = $0.isEmpty ? nil : $0
                    }))
                AudioMeterView(title: "Input level", symbol: "waveform", reading: levels.snapshot.microphone)
                StudioValueSlider(title: "Volume", value: Binding(get: { model.project.microphoneVolume }, set: {
                    model.project.microphoneVolume = $0; engine.microphoneGain = $0
                }), range: 0...4, percent: true)
                HStack {
                    Button(levels.snapshot.microphoneReady ? "Pause input" : "Enable microphone", action: engine.toggleMicrophoneInput)
                        .disabled(engine.recording || engine.streaming)
                    Spacer(minLength: 5)
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                    } label: { Image(systemName: "lock.shield") }.help("Microphone permission settings")
                }
            }
            channel {
                Toggle(isOn: Binding(get: { model.project.captureSystemAudio ?? false }, set: {
                    model.project.captureSystemAudio = $0; engine.capturedAudioEnabled = $0
                })) { Label("Screen / app audio", systemImage: "display").font(.system(size: 13, weight: .semibold)) }
                    .toggleStyle(.switch).disabled(engine.screenCaptureBusy)
                AudioMeterView(title: "Input level", symbol: "waveform", reading: levels.snapshot.captured)
                StudioValueSlider(title: "Volume", value: Binding(get: { model.project.capturedAudioVolume ?? 1 }, set: {
                    model.project.capturedAudioVolume = $0; engine.capturedAudioGain = $0
                }), range: 0...4, percent: true).disabled(!engine.capturedAudioEnabled)
                Button(engine.screenActive ? "Change shared source…" : "Choose a shared source…", action: model.startScreen)
                    .disabled(engine.screenCaptureBusy)
                Text(engine.screenCaptureBusy ? "Updating source…" : "Audio follows the shared source. Framecast’s own sound is excluded.")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            channel {
                AudioMeterView(title: "Output mix", symbol: "waveform.path", reading: levels.snapshot.output)
                Text("The combined sound sent to your recordings and stream.")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text("Your permitted microphone stays ready before recording. Pause the input when idle, or mute it to silence the output.")
                .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh inputs") { engine.refreshDevices() }
                if showSettingsButton { Button("Audio settings…") { model.settingsTab = "Audio"; model.showSettings = true } }
            }
        }.buttonStyle(StudioButtonStyle()).tint(StudioPalette.gold).onAppear { engine.refreshDevices() }
    }
    private func channel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioPalette.control.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.border.opacity(0.65)))
    }
}
