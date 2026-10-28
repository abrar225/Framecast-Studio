import SwiftUI
import AppKit

struct AudioMeterView: View {
    let title: String
    let symbol: String
    let reading: AudioMeterReading
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(reading.rmsDB <= -60 ? "−∞ dBFS" : String(format: "%.0f dBFS", reading.rmsDB))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(reading.clipping ? Color.orange : .secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07))
                    LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * reading.level) }
                    Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1)
                        .offset(x: max(0, geometry.size.width * reading.peak - 1)).opacity(reading.receiving ? 1 : 0)
                }.clipShape(RoundedRectangle(cornerRadius: 3))
            }.frame(height: 10).animation(.linear(duration: 0.08), value: reading.level)
            HStack {
                Text(reading.status).font(.system(size: 10)).foregroundStyle(reading.clipping ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 3)
                if reading.receiving { Circle().fill(reading.rmsDB > -60 ? Color.green : Color.secondary).frame(width: 5, height: 5) }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title) audio level")
            .accessibilityValue("\(reading.status), \(Int(reading.rmsDB)) decibels below full scale")
    }
}

struct AudioActivityButton: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var levels: AudioSignalMonitor
    private var signal: Bool { levels.snapshot.microphone.level > 0 || levels.snapshot.captured.level > 0 || levels.snapshot.output.level > 0 }
    private var clipping: Bool { levels.snapshot.microphone.clipping || levels.snapshot.captured.clipping || levels.snapshot.output.clipping }
    var body: some View {
        Button { model.panel = "Audio" } label: {
            Image(systemName: "waveform").foregroundStyle(clipping ? Color.orange : signal ? Color.green : Color.secondary)
                .frame(width: 30, height: 33).background(Color.white.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel("Audio levels")
            .accessibilityValue("Microphone: \(levels.snapshot.microphone.status). Captured audio: \(levels.snapshot.captured.status)")
            .help("Audio levels · Microphone: \(levels.snapshot.microphone.status). Captured audio: \(levels.snapshot.captured.status)")
    }
}
