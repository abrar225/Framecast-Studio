import Foundation

/// Display metadata comes from the installed bundle, owned by the packaging step.
enum ProductInfo {
    static var name:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "Framecast Studio"}
    static var version:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "Development"}
    static var build:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "local"}
    static let capabilities="Compose editable horizontal and vertical scenes, record high-fidelity H.264/HEVC MP4 or MOV movies with 32-bit float audio, multi-stream to YouTube, Twitch, Kick, and custom RTMP endpoints, manage takes in the in-app library, and control your broadcast via the private remote companion deck."
    static let limits="Guest conferencing and virtual camera extension are planned for future major releases. This build includes full local broadcast and recording capabilities."
}
