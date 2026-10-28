import SwiftUI
import AppKit
import AVFoundation

struct SettingsView: View {
    @ObservedObject var model: StudioModel
    var viewport: CGSize? = nil
    @Environment(\.dismiss) private var dismiss
    private let tabs: [(String, String)] = [
        ("General", "gearshape"), ("Video", "rectangle.on.rectangle"), ("Audio", "waveform"),
        ("Recording", "record.circle"), ("Streaming", "antenna.radiowaves.left.and.right"),
        ("Camera", "video"), ("Remote", "iphone"), ("Hotkeys", "keyboard"), ("About", "info.circle")
    ]
    private var workspaceWidth: CGFloat {
        min(1160, max(790, (viewport?.width ?? NSApp.mainWindow?.contentView?.bounds.width ?? NSScreen.main?.visibleFrame.width ?? 1240) - 24))
    }
    private var workspaceHeight: CGFloat {
        min(820, max(570, (viewport?.height ?? NSApp.mainWindow?.contentView?.bounds.height ?? NSScreen.main?.visibleFrame.height ?? 900) - 24))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") { model.refreshComposition(); model.save(); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 5) {
                    ForEach(tabs, id: \.0) { item in
                        Button { model.settingsTab = item.0 } label: {
                            Label(item.0, systemImage: item.1)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                                .background(model.settingsTab == item.0 ? Color(hex: "#38332A") : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(12).frame(width: 205).background(Color(hex: "#141310"))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(model.settingsTab).font(.system(size: 22, weight: .semibold))
                        contents
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(30)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: workspaceWidth, height: workspaceHeight).foregroundStyle(Color(hex: "#EEE9E2"))
            .background(StudioPalette.panel).tint(StudioPalette.gold).buttonStyle(StudioButtonStyle()).textFieldStyle(StudioTextFieldStyle()).toggleStyle(.switch).preferredColorScheme(.dark)
    }
    @ViewBuilder private var contents: some View {
        switch model.settingsTab {
        case "General": general
        case "Video": video
        case "Audio": AudioSettingsPane(model: model, engine: model.engine)
        case "Recording": recording
        case "Streaming": streaming
        case "Camera": CameraSettingsPane(model: model, engine: model.engine)
        case "Remote": remote
        case "Hotkeys": hotkeys
        default: about
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            labeledField("Studio name", text: $model.project.name)
            description("Your scenes, sources and preferences are saved locally every two seconds. Stream keys stay in macOS Keychain.")
            HStack { Button("Import studio…", action: model.importProject); Button("Export studio…", action: model.exportProject) }
            Divider()
            Text("Local project file").font(.headline)
            Text(model.projectURL.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Show in Finder") { model.save(); NSWorkspace.shared.activateFileViewerSelecting([model.projectURL]) }
        }
    }
    private var video: some View { VideoSettingsPane(model: model, engine: model.engine) }
    private var recording: some View {
        VStack(alignment: .leading, spacing: 22) {
            RecordingSpaceSummary(model: model)
            Text("What to record").font(.headline)
            description("Horizontal and vertical use their own file format and quality. The studio canvas mode chooses which files are recorded.")
            RecordingEncodingControls(model: model, engine: model.engine)
            Divider()
            HStack {
                Text("Where to save").font(.headline)
                Spacer()
                Button("Choose folder…", action: model.chooseRecordingFolder)
            }
            Text(model.project.recordingFolder).font(.system(size: 12)).textSelection(.enabled).foregroundStyle(.secondary)
            Button("Open recordings", action: model.revealRecordings)
            Divider()
            Text("Recording controls and health").font(.headline)
            RecordingSettingsStatus(model: model, engine: model.engine)
        }
    }
    private var streaming: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Custom RTMP", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
            description("Connect your own Google account for private YouTube broadcasts and live chat, or configure a custom RTMP destination.")
            Text("\(model.project.destinations.count) configured destination\(model.project.destinations.count == 1 ? "" : "s")").font(.system(size: 12))
            Button("Manage destinations…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.showDestinations = true } }
            Divider()
            StreamingEncodingControls(model: model, engine: model.engine)
            description("One active RTMP destination is supported. Streaming requires FFmpeg on your computer. Microphone and enabled captured audio are mixed into stereo recording and RTMP output.")
        }
    }
    private var remote: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Remote control", systemImage: "iphone").font(.headline)
            description("Start the local remote server to control your studio through its generated address. Keep this address private; stop the server when you finish.")
            if model.remoteActive {
                Text(model.remoteAddress).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.remoteAddress, forType: .string) }
                    Button("Open remote") { if let url = URL(string: model.remoteAddress) { NSWorkspace.shared.open(url) } }
                    Button("Stop remote", action: model.stopRemote)
                }
            } else { Button("Start remote control", action: model.startRemote) }
        }
    }
    private var hotkeys: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                shortcut("Settings", "⌘ ,")
                shortcut("Import studio", "⌘ O")
                shortcut("Export studio", "⌘ S")
                shortcut("Start / stop recording", "⌘ R")
                shortcut("Mute / unmute microphone", "⌘ M")
                shortcut("Switch layout", "⌘ 1 … 9")
            }
            description("Custom global hotkeys and Stream Deck integration are not implemented in this reconstruction.")
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "video.badge.waveform.fill").font(.system(size: 42))
            Text(ProductInfo.name).font(.system(size: 23, weight: .semibold))
            Text("Version \(ProductInfo.version) (\(ProductInfo.build))").font(.system(size: 12)).foregroundStyle(.secondary)
            description("A native macOS implementation informed by the installed application and public product materials. It is independent of Vidyst and does not include their cloud services, account access or proprietary assets.")
            description(ProductInfo.capabilities)
            description(ProductInfo.limits)
        }
    }
    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }.font(.system(size: 12))
    }
    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 12, weight: .semibold)); TextField(title, text: text).textFieldStyle(StudioTextFieldStyle()) }
    }
    private func description(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct CameraSettingsPane: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Camera", selection: $model.project.cameraDeviceID) {
                Text("System default").tag("")
                ForEach(engine.cameraOptions) { device in Text(device.name).tag(device.id) }
            }
            HStack {
                Button("Refresh devices") { engine.refreshDevices() }
                Button("Enable camera", action: model.startCamera)
                Button("Stop camera") { engine.stopCamera() }
            }
            Text("Camera access is requested only when you enable a camera. Add a camera source to show it in the studio output.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Add camera to scene") { model.addSource("camera") }
            Divider()
            Text("Screen capture").font(.headline)
            HStack {
                Button(engine.screenActive ? "Change capture source…" : "Choose display, window or app…", action: model.startScreen)
                Button("Stop screen capture") { engine.stopScreenCapture() }
            }
            Text("Choose the source in Apple’s screen-sharing chooser. Screen Recording permission is managed by macOS. Captured audio can be enabled in Audio settings.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.onAppear { engine.refreshDevices() }
    }
}
private struct AudioSettingsPane: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    var body: some View { AudioMixerPanel(model: model, engine: engine, showSettingsButton: false) }
}
private struct RecordingSpaceSummary: View {
    @ObservedObject var model: StudioModel

    private var estimatedBitRate: Int {
        let preferences = model.project.mediaPreferences ?? MediaPreferences()
        let canvases = model.canvasMode == "both" ? [false, true] : [model.canvasMode == "vertical"]
        return canvases.reduce(0) { total, vertical in
            let output = model.canvasOutput(vertical: vertical)
            return total + preferences.recordingBitRate(width: output.width, height: output.height, fps: output.fps, vertical: vertical)
        }
    }
    private func timeLabel(bytes: Int64) -> String {
        let seconds = Double(bytes) * 8 / Double(max(1, estimatedBitRate))
        guard seconds.isFinite else { return "Estimate unavailable" }
        let hours = Int(seconds / 3600)
        return hours > 0 ? "About \(hours) h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min" : "About \(Int(seconds / 60)) min"
    }
    var body: some View {
        let status = try? RecordingStorage.status(directory: URL(fileURLWithPath: model.project.recordingFolder))
        let bytes = status?.availableBytes
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.canvasMode == "both" ? "Both canvases" : model.canvasMode == "vertical" ? "Vertical canvas" : "Horizontal canvas")
                    .font(.system(size: 13, weight: .semibold))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Available space").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown")
                    .font(.system(size: 13, weight: .semibold))
            }.padding(.leading, 18).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Estimated recording time").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(bytes.map(timeLabel) ?? (status?.writable == false ? "Folder not writable" : "Unknown"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(status?.writable == false || (bytes.map { Double($0) * 8 / Double(max(1, estimatedBitRate)) < 600 } ?? false) ? .orange : StudioPalette.gold)
            }.padding(.leading, 18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 76).padding(.horizontal, 18)
        .background(StudioPalette.panel).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioPalette.border))
        .accessibilityElement(children: .contain)
    }
}
private struct RecordingSettingsStatus: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.recording { Text("Recording in progress").foregroundStyle(.red) }
            if engine.isFinalizingRecording { ProgressView("Finishing recording…") }
            Button(engine.recording ? "Stop recording" : "Start recording", action: model.toggleRecording)
                .disabled(engine.isFinalizingRecording)
            if let url = engine.recordingURL, !engine.recording, !engine.isFinalizingRecording {
                Button("Reveal last recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            ForEach(engine.recordingStatistics) { stats in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.width) × \(stats.height) · \(stats.fps)fps · \(stats.codec)").font(.system(size: 12, weight: .semibold))
                    Text("\(stats.submittedFrames) frames submitted · \(stats.missedFrameSlots) missed slots · \(stats.audioBackpressurePackets) audio backpressure packets")
                        .font(.system(size: 11)).foregroundStyle(stats.missedFrameSlots > 0 || stats.audioBackpressurePackets > 0 ? .orange : .secondary)
                }
            }
            Button("Export recording report…", action: model.exportRecordingReport).disabled(engine.recordingStatistics.isEmpty || engine.recording || engine.isFinalizingRecording)
            if let error = engine.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

private struct VideoSettingsPane: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine

    private func canvasCard(vertical: Bool) -> some View {
        let output = model.canvasOutput(vertical: vertical)
        let selected = "\(output.width)x\(output.height)"
        let presets: [(String, Int, Int)] = [("HD", 1280, 720), ("1080p", 1920, 1080), ("1440p", 2560, 1440), ("4K", 3840, 2160)]
            .map { ($0.0, vertical ? $0.2 : $0.1, vertical ? $0.1 : $0.2) }
        let choices = presets.map { ("\($0.1)x\($0.2)", "\($0.1) × \($0.2) · \($0.0)") }
        let options = choices.contains(where: { $0.0 == selected }) ? choices : choices + [(selected, "\(output.width) × \(output.height) · Custom")]
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: vertical ? "rectangle.portrait" : "rectangle")
                    .foregroundStyle(StudioPalette.gold).frame(width: 40, height: 40)
                    .background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(vertical ? "Vertical" : "Horizontal").font(.system(size: 15, weight: .semibold))
                    Text(vertical ? "Short-form canvas" : "Main canvas").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            Text("Resolution").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            StudioMenuField(title: (vertical ? "Vertical" : "Horizontal") + " canvas resolution", options: options,
                selection: Binding(get: { "\(model.canvasOutput(vertical: vertical).width)x\(model.canvasOutput(vertical: vertical).height)" }, set: { choice in
                    let parts = choice.split(separator: "x").compactMap { Int($0) }
                    guard parts.count == 2 else { return }
                    model.setCanvasResolution(width: parts[0], height: parts[1], vertical: vertical)
                }))
            Text("Frame rate").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            StudioSegmentedControl(options: MediaPreferences.frameRates.map { (String($0), $0) },
                selection: Binding(get: { model.canvasOutput(vertical: vertical).fps }, set: { model.setCanvasFrameRate($0, vertical: vertical) }))
            Text("\(output.width) × \(output.height) · \(output.fps) fps")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioPalette.gold)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StudioPalette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.border))
        .disabled(engine.recording || engine.streaming || engine.isFinalizingRecording)
    }
    var body: some View {
        let horizontal = model.canvasOutput(vertical: false)
        let vertical = model.canvasOutput(vertical: true)
        let configuredMillions = Double(horizontal.width * horizontal.height * horizontal.fps + vertical.width * vertical.height * vertical.fps) / 1_000_000
        VStack(alignment: .leading, spacing: 18) {
            Text("Canvases").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                canvasCard(vertical: false)
                canvasCard(vertical: true)
            }
            HStack {
                Image(systemName: "speedometer").foregroundStyle(StudioPalette.gold)
                Text("Configured render load").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f million pixels/s across both canvases", configuredMillions))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(16).background(StudioPalette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
            Text("These are configured sizes and frame rates, not guaranteed delivery. The recording report shows submitted and missed frames. Use the toolbar to record one canvas or both. Changes are locked while outputs run.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if engine.screenActive, engine.screenCaptureSize.width > 0 {
                Text("Native screen input: \(Int(engine.screenCaptureSize.width)) × \(Int(engine.screenCaptureSize.height))")
                    .font(.system(size: 12, weight: .medium))
                Text("A larger output cannot add detail missing from the selected display or window.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
