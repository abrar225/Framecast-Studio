import SwiftUI

struct RecordingEncodingControls: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine

    private func settings(vertical: Bool) -> Binding<RecordingEncodingSettings> {
        Binding(get: { (model.project.mediaPreferences ?? MediaPreferences()).recording(vertical: vertical) }, set: { value in
            var preferences = model.project.mediaPreferences ?? MediaPreferences()
            if vertical { preferences.vertical = value } else { preferences.horizontal = value }
            model.project.mediaPreferences = preferences
            model.save()
        })
    }
    private func canvasCard(vertical: Bool) -> some View {
        let value = settings(vertical: vertical)
        let (width, height, fps) = model.canvasOutput(vertical: vertical)
        let rate = value.wrappedValue.bitRate(width: width, height: height, fps: fps)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: vertical ? "rectangle.portrait" : "rectangle").foregroundStyle(StudioPalette.gold)
                    .frame(width: 30, height: 30).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(vertical ? "Vertical" : "Horizontal").font(.system(size: 14, weight: .semibold))
                    Text("\(width) × \(height) · \(fps) fps").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(model.canvasMode == "both" || model.canvasMode == (vertical ? "vertical" : "horizontal") ? "RECORDED" : "READY")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(StudioPalette.gold)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("File type").font(.system(size: 11)).foregroundStyle(.secondary)
                    StudioMenuField(title: (vertical ? "Vertical" : "Horizontal") + " file type", options: RecordingContainer.allCases.map { ($0.rawValue, $0.rawValue.uppercased()) }, selection: Binding(get: { value.wrappedValue.container.rawValue }, set: { if let chosen = RecordingContainer(rawValue: $0) { value.wrappedValue.container = chosen } }))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Codec").font(.system(size: 11)).foregroundStyle(.secondary)
                    StudioMenuField(title: (vertical ? "Vertical" : "Horizontal") + " codec", options: RecordingCodec.allCases.map { ($0.rawValue, $0.title) }, selection: Binding(get: { value.wrappedValue.codec.rawValue }, set: { if let chosen = RecordingCodec(rawValue: $0) { value.wrappedValue.codec = chosen } }))
                }
            }
            Text("Quality").font(.system(size: 11)).foregroundStyle(.secondary)
            StudioSegmentedControl(options: RecordingQuality.allCases.map { ($0.title, $0) }, selection: value.quality)
            if value.wrappedValue.quality == .custom {
                StudioValueSlider(title: "Video bitrate · Mbps", value: value.bitrateMbps, range: 0.5...120)
            }
            Toggle("Require hardware encoding", isOn: value.requireHardware).font(.system(size: 11))
            Text("Estimated video · \(String(format: "%.1f", Double(rate) / 1_000_000)) Mbps")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioPalette.gold)
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StudioPalette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.border))
        .disabled(engine.recording || engine.isFinalizingRecording)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                canvasCard(vertical: false)
                canvasCard(vertical: true)
            }
            AudioBitrateField(value: Binding(get: { (model.project.mediaPreferences ?? MediaPreferences()).recordingAudioBitrateKbps }, set: { value in
                var preferences = model.project.mediaPreferences ?? MediaPreferences()
                preferences.recordingAudioBitrateKbps = value
                model.project.mediaPreferences = preferences
                model.save()
            })).disabled(engine.recording || engine.isFinalizingRecording)
            Text("Both canvases keep their own format and quality. Only completed movies appear as saved. HEVC saves space; H.264 has wider playback support. Interrupted files may lose the current fragment, up to about 10 seconds.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StreamingEncodingControls: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    private var settings: Binding<StreamEncodingSettings> {
        Binding(get: { (model.project.mediaPreferences ?? MediaPreferences()).streaming }, set: { value in
            var preferences = model.project.mediaPreferences ?? MediaPreferences(); preferences.streaming = value
            model.project.mediaPreferences = preferences; model.save()
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Encoder quality").font(.headline)
            StudioMenuField(title: "H.264 encoder", options: StreamEncoder.allCases.map { ($0.rawValue, $0.title) }, selection: Binding(get: { settings.wrappedValue.encoder.rawValue }, set: { if let value = StreamEncoder(rawValue: $0) { settings.wrappedValue.encoder = value } }))
            Toggle("Automatic video bitrate", isOn: settings.automaticBitrate)
            if !settings.wrappedValue.automaticBitrate { StudioValueSlider(title: "Video bitrate · Mbps", value: settings.bitrateMbps, range: 0.5...80) }
            AudioBitrateField(value: settings.audioBitrateKbps)
            Text("Apple VideoToolbox requires hardware encoding. Choose Software H.264 explicitly if the encoder is unavailable. Destination canvas controls stream size and frame rate; bitrate is independent from local recording. A running encoder does not confirm viewers receive the stream.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(engine.streaming)
    }
}

private struct AudioBitrateField: View {
    @Binding var value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Stereo audio ·48kHz").font(.system(size: 11)).foregroundStyle(.secondary)
            StudioMenuField(title: "Stereo audio bitrate", options: MediaPreferences.audioBitrates.map { (String($0), "\($0) kbps") }, selection: Binding(get: { String(value) }, set: { if let parsed = Int($0), MediaPreferences.audioBitrates.contains(parsed) { value = parsed } }))
        }
    }
}
