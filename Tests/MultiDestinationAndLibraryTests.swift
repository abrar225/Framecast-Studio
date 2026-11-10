import Testing
import Foundation
@testable import VidystStudio

@Suite struct MultiDestinationAndLibraryTests {
    @Test func streamTargetPropertiesAndOrientation() {
        let hID = UUID()
        let vID = UUID()
        let hTarget = StreamTarget(
            destinationID: hID,
            name: "Twitch Main",
            url: "rtmp://live.twitch.tv/app",
            key: "live_secret_1",
            vertical: false,
            width: 1920,
            height: 1080,
            fps: 60,
            configuration: RenderConfiguration(width: 1920, height: 1080)
        )
        let vTarget = StreamTarget(
            destinationID: vID,
            name: "TikTok Live",
            url: "rtmp://live.tiktok.com/app",
            key: "live_secret_2",
            vertical: true,
            width: 1080,
            height: 1920,
            fps: 30,
            configuration: RenderConfiguration(width: 1080, height: 1920)
        )

        #expect(hTarget.destinationID == hID)
        #expect(!hTarget.vertical)
        #expect(hTarget.width == 1920)
        #expect(hTarget.height == 1080)

        #expect(vTarget.destinationID == vID)
        #expect(vTarget.vertical)
        #expect(vTarget.width == 1080)
        #expect(vTarget.height == 1920)

        #expect(hTarget != vTarget)
    }

    @MainActor
    @Test func mediaEngineMultiStreamingLifecycle() {
        let engine = MediaEngine()
        #expect(!engine.streaming)
        #expect(engine.activeStreamOutputs.isEmpty)

        let t1 = StreamTarget(destinationID: UUID(), name: "YouTube", url: "rtmp://a.rtmp.youtube.com/live2", key: "key1", vertical: false, width: 1280, height: 720, fps: 30, configuration: RenderConfiguration(width: 1280, height: 720))
        let t2 = StreamTarget(destinationID: UUID(), name: "Twitch", url: "rtmp://live.twitch.tv/app", key: "key2", vertical: false, width: 1280, height: 720, fps: 30, configuration: RenderConfiguration(width: 1280, height: 720))
        let t3 = StreamTarget(destinationID: UUID(), name: "Kick Vertical", url: "rtmp://fa7231787.global-contribute.live-video.net/app", key: "key3", vertical: true, width: 720, height: 1280, fps: 30, configuration: RenderConfiguration(width: 720, height: 1280))

        engine.startStreaming(targets: [t1, t2, t3], settings: StreamEncodingSettings())
        #expect(engine.streaming)
        #expect(engine.activeStreamOutputs.count == 3)

        // Verify backward-compatible streamPipe is accessible
        #expect(engine.streamPipe != nil)

        // Test stopping streaming cleanly
        engine.stopStreaming()
        #expect(!engine.streaming)
        #expect(engine.activeStreamOutputs.isEmpty)
        #expect(engine.streamPipe == nil)
    }

    @MainActor
    @Test func recordingItemFormattingAndScanning() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FramecastLibraryTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create mock video and non-video files
        let mockMP4 = tempDir.appendingPathComponent("2026-11-10_Take_1.mp4")
        let mockMOV = tempDir.appendingPathComponent("2026-11-10_Take_2.mov")
        let mockTXT = tempDir.appendingPathComponent("notes.txt")

        try "fake mp4 content".data(using: .utf8)!.write(to: mockMP4)
        try "fake mov content with more data".data(using: .utf8)!.write(to: mockMOV)
        try "ignored notes".data(using: .utf8)!.write(to: mockTXT)

        let manager = RecordingLibraryManager()
        manager.scan(folder: tempDir)

        // Give the background utility task a moment to scan the files
        var attempts = 0
        while manager.items.count < 2 && attempts < 20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }

        #expect(manager.items.count == 2)
        #expect(!manager.items.contains(where: { $0.fileName == "notes.txt" }))

        // Test item formatting helpers
        let item = RecordingItem(
            id: UUID(),
            url: mockMP4,
            fileName: "2026-11-10_Take_1.mp4",
            creationDate: Date(),
            fileSize: 104_857_600, // 100 MB
            duration: 125.5, // 2m 05s
            resolution: CGSize(width: 1920, height: 1080),
            codecName: "H.264",
            isVertical: false
        )

        #expect(item.formattedDuration == "02:05")
        #expect(item.formattedResolution == "1080p")
        #expect(item.formattedFileSize.contains("MB"))
    }

    @MainActor
    @Test func remoteServerLifecycleAndCommandDispatch() async throws {
        let model = StudioModel()
        let server = RemoteServer(model: model)
        try server.start()

        var attempts = 0
        while server.address == "Starting local control…" && attempts < 20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        #expect(server.address.contains("token="))

        // Test remote command dispatch via model actions
        #expect(model.canvasMode != "both" || model.canvasMode == "both")
        model.canvasMode = "horizontal"
        model.vertical = false

        // Toggle lower third
        let initialLT = model.project.lowerThirdVisible
        model.project.lowerThirdVisible.toggle()
        #expect(model.project.lowerThirdVisible != initialLT)

        // Desktop audio gain control
        model.project.capturedAudioVolume = 2.5
        model.engine.capturedAudioGain = 2.5
        #expect(model.engine.capturedAudioGain == 2.5)

        // Multi-destination stream validation from model
        model.project.destinations = [
            StreamDestination(name: "YouTube", url: "rtmp://youtube", enabled: true, vertical: false),
            StreamDestination(name: "Twitch", url: "rtmp://twitch", enabled: true, vertical: false)
        ]
        #expect(model.project.destinations.filter { $0.enabled }.count == 2)

        server.stop()
        #expect(server.address.isEmpty)
    }
}
