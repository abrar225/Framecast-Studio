// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "VidystReconstructed", platforms: [.macOS(.v14)], products: [.executable(name: "VidystReconstructed", targets: ["VidystStudio"])], dependencies: [.package(path: "ThirdParty/CompactSlider")], targets: [.executableTarget(name: "VidystStudio", dependencies: [.product(name: "CompactSlider", package: "CompactSlider")], path: "Sources/VidystStudio")])
