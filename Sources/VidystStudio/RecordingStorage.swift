import Foundation

enum RecordingStorage {
    struct Status {
        let writable: Bool
        let availableBytes: Int64?
    }

    /// One capacity interpretation serves both the preflight and the settings
    /// estimate. Some volumes cannot report capacity; nil remains unknown.
    static func status(directory: URL, availableBytes: Int64? = nil) throws -> Status {
        let writable = FileManager.default.isWritableFile(atPath: directory.path)
        guard writable else { return Status(writable: false, availableBytes: nil) }
        if let availableBytes { return Status(writable: true, availableBytes: availableBytes) }
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return Status(writable: true, availableBytes: values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init))
    }

    /// Reserve space for ten seconds of the configured outputs plus a64MiB
    /// finalization margin. Unknown capacity remains unknown; writer errors still
    /// govern network volumes that do not report free space.
    static func preflight(directory: URL, bitRate: Int, availableBytes: Int64? = nil) throws {
        let inspection = try status(directory: directory, availableBytes: availableBytes)
        guard inspection.writable else {
            throw MediaFailure(code: .storagePermission, operation: "Recording", message: "The recording folder is not writable.", recovery: "Choose another folder or check drive permissions.")
        }
        let capacity = inspection.availableBytes
        if let capacity, capacity < 64 * 1024 * 1024 + Int64(bitRate) * 10 / 8 {
            throw MediaFailure(code: .storageFull, operation: "Recording", message: "Not enough free space to start safely.", recovery: "Free space or choose another recording folder. Allow room for the recording and finalization.")
        }
    }
}
