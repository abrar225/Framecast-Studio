import Foundation
import AVFoundation
import AppKit

struct RecordingItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let fileName: String
    let creationDate: Date
    let fileSize: Int64
    let duration: Double?
    let resolution: CGSize?
    let codecName: String?
    let isVertical: Bool

    var formattedDuration: String {
        guard let duration, duration.isFinite, duration > 0 else { return "00:00" }
        let total = Int(duration)
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: creationDate, relativeTo: Date())
    }

    var formattedResolution: String {
        guard let resolution else { return "Video" }
        let w = Int(resolution.width), h = Int(resolution.height)
        if (w == 3840 && h == 2160) || (w == 2160 && h == 3840) { return "4K" }
        if (w == 1920 && h == 1080) || (w == 1080 && h == 1920) { return "1080p" }
        if (w == 1280 && h == 720) || (w == 720 && h == 1280) { return "720p" }
        return "\(w)×\(h)"
    }
}

@MainActor final class RecordingLibraryManager: ObservableObject {
    @Published var items: [RecordingItem] = []
    var recordings: [RecordingItem] { items }
    @Published var selectedItem: RecordingItem?
    @Published var isScanning = false
    @Published var thumbnails: [URL: NSImage] = [:]
    @Published var errorMessage: String?

    private var currentFolder: URL?

    func scan(folder: URL) {
        currentFolder = folder
        isScanning = true
        Task.detached(priority: .utility) {
            let found = await Self.scanFolder(folder)
            await MainActor.run {
                self.items = found
                if self.selectedItem == nil || !found.contains(where: { $0.url == self.selectedItem?.url }) {
                    self.selectedItem = found.first
                }
                self.isScanning = false
            }
            // Generate thumbnails asynchronously without blocking main thread
            for item in found {
                let hasThumb = await MainActor.run(body: { self.thumbnails[item.url] != nil })
                if hasThumb { continue }
                let thumb = await Self.generateThumbnail(for: item.url)
                if let thumb {
                    await MainActor.run {
                        self.thumbnails[item.url] = thumb
                    }
                }
            }
        }
    }

    nonisolated private static func scanFolder(_ folder: URL) async -> [RecordingItem] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var fileList: [(url: URL, date: Date, size: Int64)] = []
        for fileURL in urls {
            let ext = fileURL.pathExtension.lowercased()
            guard ["mp4", "mov", "m4v"].contains(ext) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            fileList.append((fileURL, values.contentModificationDate ?? Date(), Int64(values.fileSize ?? 0)))
        }

        var results: [RecordingItem] = []
        for file in fileList {
            let asset = AVURLAsset(url: file.url)
            var duration: Double? = nil
            if let d = try? await asset.load(.duration), d.seconds.isFinite {
                duration = d.seconds
            }
            var res: CGSize? = nil
            var isVert = false
            var codec: String? = nil
            if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
                if let naturalSize = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let size = naturalSize.applying(transform)
                    let w = abs(size.width), h = abs(size.height)
                    res = CGSize(width: w, height: h)
                    isVert = h > w
                }
                if let descriptions = try? await track.load(.formatDescriptions) {
                    for desc in descriptions {
                        let sub = CMFormatDescriptionGetMediaSubType(desc)
                        codec = sub == kCMVideoCodecType_HEVC ? "HEVC" : (sub == kCMVideoCodecType_H264 ? "H.264" : nil)
                    }
                }
            }
            results.append(RecordingItem(id: UUID(), url: file.url, fileName: file.url.lastPathComponent, creationDate: file.date, fileSize: file.size, duration: duration, resolution: res, codecName: codec, isVertical: isVert))
        }
        results.sort { $0.creationDate > $1.creationDate }
        return results
    }

    nonisolated private static func generateThumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let dur = (try? await asset.load(.duration))?.seconds ?? 10.0
        let time = CMTime(seconds: min(1.0, max(0.1, dur * 0.1)), preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    func delete(item: RecordingItem) {
        let alert = NSAlert()
        alert.messageText = "Delete Take?"
        alert.informativeText = "Are you sure you want to permanently delete \"\(item.fileName)\"? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.removeItem(at: item.url)
            items.removeAll { $0.id == item.id }
            thumbnails.removeValue(forKey: item.url)
            if selectedItem?.id == item.id {
                selectedItem = items.first
            }
        }
    }

    func reveal(item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(item: RecordingItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }

    func openWithDefaultApp(item: RecordingItem) {
        NSWorkspace.shared.open(item.url)
    }
}
