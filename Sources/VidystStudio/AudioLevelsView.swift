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
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(reading.clipping ? StudioPalette.coral : StudioPalette.muted)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07))
                    LinearGradient(colors: [StudioPalette.success, StudioPalette.gold, StudioPalette.coral], startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, geometry.size.width * reading.level)) }
                    Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.5)
                        .offset(x: max(0, min(geometry.size.width - 1.5, geometry.size.width * reading.peak - 1))).opacity(reading.receiving ? 1 : 0)
                }.clipShape(RoundedRectangle(cornerRadius: 3))
            }.frame(height: 10).animation(.linear(duration: 0.08), value: reading.level)
            HStack {
                Text(reading.status).font(.system(size: 10)).foregroundStyle(reading.clipping ? StudioPalette.coral : StudioPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 3)
                if reading.receiving { Circle().fill(reading.rmsDB > -60 ? StudioPalette.success : Color.secondary).frame(width: 5, height: 5) }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title) audio level")
            .accessibilityValue("\(reading.status), \(Int(reading.rmsDB)) decibels below full scale")
    }
}

/// Compact live audio monitoring pill for the studio toolbar
struct AudioToolbarPill: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var levels: AudioSignalMonitor

    private var reading: AudioMeterReading {
        levels.snapshot.output.receiving ? levels.snapshot.output : levels.snapshot.microphone
    }
    private var signal: Bool { reading.receiving && reading.level > 0 }
    private var clipping: Bool { levels.snapshot.microphone.clipping || levels.snapshot.output.clipping }

    var body: some View {
        Button { model.panel = "Audio" } label: {
            HStack(spacing: 6) {
                Image(systemName: clipping ? "exclamationmark.triangle.fill" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(clipping ? StudioPalette.coral : signal ? StudioPalette.success : StudioPalette.muted)

                // Live dynamic level meter
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.08))
                    LinearGradient(colors: [StudioPalette.success, StudioPalette.gold, StudioPalette.coral], startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, 32 * reading.level))
                        }
                    if reading.receiving {
                        Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1)
                            .offset(x: max(0, min(31, 32 * reading.peak - 1)))
                    }
                }
                .frame(width: 32, height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 2))

                Text(reading.rmsDB <= -60 ? "−∞" : String(format: "%.0f", reading.rmsDB))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(clipping ? StudioPalette.coral : StudioPalette.muted)
            }
            .padding(.horizontal, 9).frame(height: 33)
            .background(StudioPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(clipping ? StudioPalette.coral.opacity(0.7) : StudioPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio levels")
        .accessibilityValue("\(reading.status), \(Int(reading.rmsDB)) dBFS")
        .help("Audio levels · \(reading.status), \(Int(reading.rmsDB)) dBFS (Click to open Audio mixer)")
    }
}

struct AudioActivityButton: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var levels: AudioSignalMonitor
    private var signal: Bool { levels.snapshot.microphone.level > 0 || levels.snapshot.captured.level > 0 || levels.snapshot.output.level > 0 }
    private var clipping: Bool { levels.snapshot.microphone.clipping || levels.snapshot.captured.clipping || levels.snapshot.output.clipping }
    var body: some View {
        Button { model.panel = "Audio" } label: {
            Image(systemName: "waveform").foregroundStyle(clipping ? StudioPalette.coral : signal ? StudioPalette.success : StudioPalette.muted)
                .frame(width: 30, height: 33).background(StudioPalette.card).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(clipping ? StudioPalette.coral.opacity(0.7) : StudioPalette.border, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("Audio levels")
            .accessibilityValue("Microphone: \(levels.snapshot.microphone.status). Captured audio: \(levels.snapshot.captured.status)")
            .help("Audio levels · Microphone: \(levels.snapshot.microphone.status). Captured audio: \(levels.snapshot.captured.status)")
    }
}
