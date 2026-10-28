import AppKit
import AVFoundation
import Darwin

/// Owned helper intentionally exits without finishWriting. The parent validates
/// the resulting partial movie; this never interrupts the normal studio app.
@main private enum RecordingInterruptionTest {
    @MainActor static func main() async {
        do {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            var settings = RecordingEncodingSettings()
            guard let container = RecordingContainer(rawValue: CommandLine.arguments[2]) else { throw MediaFailure.invalid("Unknown test container") }
            settings.container = container
            settings.codec = settings.container == .mov ? .hevc : .h264
            let output = try RecordingOutput(url: url, width: 640, height: 360, fps: 30, configuration: RenderConfiguration(width: 640, height: 360), settings: settings)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { throw MediaFailure.invalid("Test frame allocation failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let audio = Data(repeating: 0, count: 1600 * 4)
            for frame in 0..<150 {
                if output.video.isReadyForMoreMediaData {
                    guard output.adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw output.writer.error ?? MediaFailure.invalid("Test video append failed") }
                }
                if output.audio.isReadyForMoreMediaData, let sample = MixedAudioSample.make(data: audio, frame: Int64(frame * 1600)) {
                    guard output.audio.append(sample) else { throw output.writer.error ?? MediaFailure.invalid("Test audio append failed") }
                }
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            print("Owned helper exits without finalization; parent must verify partial movie"); fflush(stdout)
            _exit(0)
        } catch { fputs("VERDICT: FAIL -- \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
