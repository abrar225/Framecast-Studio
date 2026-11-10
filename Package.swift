// swift-tools-version: 6.0
import Foundation
import PackageDescription

var testSettings: [SwiftSetting] = [.unsafeFlags(["-swift-version", "5"])]
let activeDevDir: String = {
    if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty {
        return env
    }
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    proc.arguments = ["-p"]
    proc.standardOutput = pipe
    guard (try? proc.run()) != nil else { return "" }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}()
if activeDevDir.contains("CommandLineTools") {
    let cltPlugin = "\(activeDevDir)/usr/lib/swift/host/plugins/testing"
    let cltServer = "\(activeDevDir)/usr/bin/swift-plugin-server"
    if FileManager.default.fileExists(atPath: cltPlugin) && FileManager.default.fileExists(atPath: cltServer) {
        testSettings.append(.unsafeFlags(["-external-plugin-path", "\(cltPlugin)#\(cltServer)"]))
    }
}

let package = Package(
    name: "VidystReconstructed",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VidystReconstructed", targets: ["VidystStudio"])],
    dependencies: [.package(path: "ThirdParty/CompactSlider")],
    targets: [
        .executableTarget(
            name: "VidystStudio",
            dependencies: [.product(name: "CompactSlider", package: "CompactSlider")],
            path: "Sources/VidystStudio",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        // Former standalone validate-* harness executables, now Swift Testing suites under `swift test`.
        .testTarget(
            name: "VidystStudioTests",
            dependencies: ["VidystStudio"],
            path: "Tests",
            swiftSettings: testSettings
        )
    ]
)
