import Foundation
@main struct MediaSelfTest {
    @MainActor static func main() async throws {
        let url = try await MediaEngine.runSelfTest(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        print("PASS compositor top-left bounds/color, H264 MP4 write/finalize, output dimensions/duration, decoded frame color/orientation")
        print("Output: \(url.path)")
        print("VERDICT: PASS")
    }
}
