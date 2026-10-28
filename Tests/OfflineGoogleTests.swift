import Foundation
@main struct OfflineGoogleTests {
    @MainActor static func main()async {
        do {
            try GoogleYouTubeController.runSelfTest()
            print("PASS RFC7636 S256, callback state/path/host/duplicate/issuer/escape/size rejection, desktop configuration, channel response")
            try await GoogleYouTubeController.runLoopbackSelfTest()
            print("PASS real IPv4 loopback ephemeral callback, invalid callback recovery, timeout, cancellation")
            print("No live credentials or persisted configuration accessed; no Google service request made.")
            print("VERDICT: PASS")
        } catch {
            print("VERDICT: FAIL -- offline Google integration tests: \(error.localizedDescription)")
            exit(1)
        }
    }
}
