import Foundation
import AVFoundation

struct MediaFailure: LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable {
        case inputPermission, inputUnavailable, unsupportedSettings, storageFull, storagePermission
        case encoderUnavailable, encoderFailed, transportFailed, frameAllocation, captureFailed, unknown
    }
    let code: Code
    let operation: String
    let message: String
    let recovery: String
    var errorDescription: String? { "\(operation): \(message) \(recovery)" }
    static func classify(_ error: Error, operation: String, fallback: Code = .encoderFailed) -> MediaFailure {
        if let error = error as? MediaFailure { return error }
        var current = error as NSError
        for _ in 0..<4 {
            if current.domain == AVFoundationErrorDomain {
                if current.code == AVError.Code.diskFull.rawValue { return MediaFailure(code: .storageFull, operation: operation, message: "The recording drive is full.", recovery: "Free space or choose another recording folder, then start a new recording.") }
                if [AVError.Code.encoderNotFound.rawValue, AVError.Code.encoderTemporarilyUnavailable.rawValue].contains(current.code) { return MediaFailure(code: .encoderUnavailable, operation: operation, message: "The selected encoder is unavailable.", recovery: "Reduce output load, choose another codec or encoder, then retry.") }
            }
            if current.domain == NSCocoaErrorDomain {
                if current.code == NSFileWriteOutOfSpaceError { return MediaFailure(code: .storageFull, operation: operation, message: "The recording drive is full.", recovery: "Free space or choose another recording folder, then start a new recording.") }
                if [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError, NSFileReadNoPermissionError].contains(current.code) {
                    return MediaFailure(code: .storagePermission, operation: operation, message: "The recording folder is not writable.", recovery: "Choose a writable folder and check drive permissions.")
                }
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { current = underlying } else { break }
        }
        return MediaFailure(code: fallback, operation: operation, message: "The media operation could not finish (\(current.domain), \(current.code)).", recovery: "Check the selected input, encoder and destination, then retry. Finished recordings remain available.")
    }
    static func invalid(_ message: String) -> MediaFailure { MediaFailure(code: .unsupportedSettings, operation: "Media settings", message: message, recovery: "Choose supported even dimensions, frame rate, codec and bitrate.") }
}
