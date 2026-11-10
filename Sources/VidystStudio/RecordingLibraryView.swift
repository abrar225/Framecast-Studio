import SwiftUI
import AVKit
import AppKit

private typealias LibraryViewState<Value> = SwiftUI.State<Value>

struct NativeVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        let player = AVPlayer(url: url)
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let currentItem = nsView.player?.currentItem as? AVPlayerItem,
           let asset = currentItem.asset as? AVURLAsset, asset.url == url {
            return
        }
        let player = AVPlayer(url: url)
        nsView.player = player
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

struct RecordingLibraryView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var library: RecordingLibraryManager
    @LibraryViewState<String> private var searchText = ""

    init(model: StudioModel) {
        self.model = model
        self.library = model.library
    }

    private var filteredItems: [RecordingItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return library.items
        }
        return library.items.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                Label("Recording Library", systemImage: "film.stack")
                    .font(.system(size: 15, weight: .bold))
                StudioBadge(text: "\(library.items.count) \(library.items.count == 1 ? "take" : "takes")", style: .default)
                let totalBytes = library.items.reduce(0) { $0 + $1.fileSize }
                StudioBadge(text: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file), style: .default)
                Spacer()
                Button {
                    library.scan(folder: URL(fileURLWithPath: model.project.recordingFolder))
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(StudioButtonStyle())
                .help("Refresh recording library")

                Button {
                    model.revealRecordings()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(StudioButtonStyle())
                .help("Open recordings folder in Finder")
            }
            .padding(.horizontal, 16).frame(height: 50)
            .background(StudioPalette.panel)

            Divider()

            if library.items.isEmpty && !library.isScanning {
                emptyState
            } else {
                HSplitView {
                    takeList.frame(minWidth: 300, idealWidth: 350, maxWidth: 450)
                    detailPane.frame(minWidth: 400)
                }
            }
        }
        .background(StudioPalette.base)
        .onAppear {
            library.scan(folder: URL(fileURLWithPath: model.project.recordingFolder))
        }
    }

    private var takeList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.muted)
                TextField("Search takes…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioPalette.muted)
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(StudioPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioPalette.cardBorder, lineWidth: 1))
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredItems) { item in
                        takeRow(item)
                    }
                }
                .padding(12)
            }
        }
        .background(StudioPalette.panel)
    }

    private func takeRow(_ item: RecordingItem) -> some View {
        let isSelected = library.selectedItem?.id == item.id
        return Button {
            library.selectedItem = item
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Video thumbnail
                ZStack(alignment: .bottomTrailing) {
                    if let image = library.thumbnails[item.url] {
                        Image(nsImage: image)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 88, height: 50)
                            .clipped()
                    } else {
                        Rectangle().fill(StudioPalette.control)
                            .frame(width: 88, height: 50)
                            .overlay {
                                Image(systemName: "film")
                                    .font(.system(size: 16))
                                    .foregroundStyle(StudioPalette.muted)
                            }
                    }
                    Text(item.formattedDuration)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? StudioPalette.gold : StudioPalette.text)

                    HStack(spacing: 4) {
                        StudioBadge(text: item.formattedResolution, style: .default)
                        if let codec = item.codecName {
                            StudioBadge(text: codec, style: .default)
                        }
                        if item.isVertical {
                            StudioBadge(text: "9:16", style: .default)
                        }
                    }

                    HStack {
                        Text(item.relativeDate)
                            .font(.system(size: 9))
                            .foregroundStyle(StudioPalette.muted)
                        Spacer()
                        Text(item.formattedFileSize)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(StudioPalette.muted)
                    }
                }
            }
            .padding(8)
            .background(isSelected ? StudioPalette.surfaceHover : StudioPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? StudioPalette.gold.opacity(0.7) : StudioPalette.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected = library.selectedItem {
            VStack(spacing: 0) {
                // Video player
                NativeVideoPlayer(url: selected.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                Divider()

                // Metadata & Actions
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selected.fileName)
                                .font(.system(size: 14, weight: .bold))
                            Text(selected.url.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(StudioPalette.muted)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button {
                                library.copyPath(item: selected)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(StudioButtonStyle())
                            .help("Copy absolute file path")

                            Button {
                                library.reveal(item: selected)
                            } label: {
                                Label("Reveal", systemImage: "folder")
                            }
                            .buttonStyle(StudioButtonStyle())
                            .help("Reveal file in Finder")

                            Button {
                                library.openWithDefaultApp(item: selected)
                            } label: {
                                Label("Open", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(StudioButtonStyle())
                            .help("Open with QuickTime Player")

                            Button(role: .destructive) {
                                library.delete(item: selected)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(StudioButtonStyle())
                            .help("Delete recording take")
                        }
                    }

                    HStack(spacing: 16) {
                        metric(label: "DURATION", value: selected.formattedDuration)
                        metric(label: "FILE SIZE", value: selected.formattedFileSize)
                        metric(label: "RESOLUTION", value: selected.resolution.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Unknown")
                        metric(label: "CODEC", value: selected.codecName ?? "H.264")
                        metric(label: "RECORDED", value: selected.relativeDate)
                    }
                }
                .padding(16)
                .background(StudioPalette.panel)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "play.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(StudioPalette.muted)
                Text("Select a take to preview")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioPalette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(StudioPalette.muted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioPalette.text)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(StudioPalette.gold)
            Text("No recordings yet")
                .font(.system(size: 18, weight: .bold))
            Text("Your finished video takes will automatically appear here.\nStart a recording using the Record button in the top bar.")
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.muted)
                .multilineTextAlignment(.center)
            Button("Open recordings folder in Finder") {
                model.revealRecordings()
            }
            .buttonStyle(StudioButtonStyle())
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
