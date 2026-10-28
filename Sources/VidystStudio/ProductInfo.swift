import Foundation

/// Display metadata comes from the installed bundle, owned by the packaging step.
enum ProductInfo {
    static var name:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "Framecast Studio"}
    static var version:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "Development"}
    static var build:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "local"}
    static let capabilities="Compose editable horizontal and vertical scenes, record H.264/HEVC MP4 or MOV movies, stream to a custom RTMP destination, or connect your own Google account for private YouTube broadcasts and chat."
    static let limits="Guest conferencing, audio monitoring/DSP, Twitch/Kick, virtual camera and full original-product parity are unfinished. This is an independent early release."
}
