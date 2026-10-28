import Foundation
@main struct DualTest {
    @MainActor static func main() async throws {
        let urls = try await MediaEngine.runDualSelfTest(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        for url in urls { print(url.path) }
        print("VERDICT: PASS")
    }
}
