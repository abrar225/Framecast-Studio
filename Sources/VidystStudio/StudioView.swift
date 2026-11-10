import SwiftUI
import AppKit
import UniformTypeIdentifiers

private typealias StoredViewState<Value> = SwiftUI.State<Value>

struct StudioView: View {
    @ObservedObject var model: StudioModel
    var allowAutomaticInputs = true
    @StoredViewState<ChatFilter> private var chatFilter = .all
    var body: some View {
        Group {
        if model.showDestinations {DestinationsView(model:model)} else {
        VStack(spacing: 0) {
            StudioToolbar(model: model)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        VStack(spacing: 9) {
                            canvasHeader
                            CaptureControls(model:model,engine:model.engine)
                            StudioPreview(model: model, engine: model.engine)
                                .frame(height: max(150, min(geometry.size.height - 100, previewHeight(width: geometry.size.width))))
                        }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).padding(.top, 12)
                    }.padding(.horizontal, 12).background(StudioPalette.canvas)
                    Divider()
                    layoutPicker
                }
                Divider()
                sidePanel.frame(width: model.panel == "Recordings" ? 520 : 320)
                Divider()
                rail
            }
        }
        }
        }
        .foregroundStyle(StudioPalette.text).background(StudioPalette.base)
        .tint(StudioPalette.gold).buttonStyle(StudioButtonStyle()).textFieldStyle(StudioTextFieldStyle()).toggleStyle(.switch)
        .frame(minWidth: 960, minHeight: 700)
        .preferredColorScheme(.dark)
        .onAppear { if allowAutomaticInputs { model.engine.prepareMicrophone() } }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .alert("Studio", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
    private func previewHeight(width: CGFloat) -> CGFloat {
        if model.canvasMode == "both" { return max(160, (width - 18) / (16.0 / 9.0 + 9.0 / 16.0) + 28) }
        return model.canvasMode == "vertical" ? 390 : width * 9 / 16 + 28
    }
    private var canvasHeader: some View {
        HStack(spacing: 10) {
            Text(model.selectedLayout).font(.system(size: 13, weight: .bold)).lineLimit(1)
            let (width, height, fps) = model.canvasOutput(vertical: model.vertical)
            StudioBadge(text: "\(width) × \(height) · \(fps) fps", icon: "sparkles", style: .outline)
            Spacer(minLength: 2)
            HStack(spacing: 2) {
                canvasMode("horizontal", title: "Horizontal", icon: "rectangle")
                canvasMode("vertical", title: "Vertical", icon: "rectangle.portrait")
                canvasMode("both", title: "Horizontal + Vertical", icon: "rectangle.on.rectangle")
            }.padding(3).background(StudioPalette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.cardBorder))
        }
    }
    private func canvasMode(_ value: String, title: String, icon: String) -> some View {
        Button {
            model.canvasMode = value
            if value != "both" { model.vertical = value == "vertical" }
            model.refreshComposition()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(model.canvasMode == value ? StudioPalette.gold : StudioPalette.muted)
                Text(title).font(.system(size: 11, weight: .semibold))
            }.padding(.horizontal, 9).padding(.vertical, 7)
                .background(model.canvasMode == value ? StudioPalette.surfaceHover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel("Show " + title)
    }
    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layouts").font(.system(size: 12, weight: .bold))
                Spacer()
                if model.canvasMode=="both" {
                    Toggle("Link layouts",isOn:Binding(get:{model.linkedLayouts},set:{model.linkedLayouts=$0})).toggleStyle(.switch).controlSize(.mini).font(.caption)
                        .help("Change both canvases together. Source framing remains independently editable.")
                }
                Menu {
                    Button("New blank layout", action: model.addScene)
                    Button("Duplicate layout", action: model.duplicateScene)
                    Menu("From template") {
                        ForEach(StudioModel.layouts, id: \.self) { name in
                            Button(name) { model.addTemplate(name) }
                        }
                    }
                    Divider()
                    Button("Import Vidyst collection…", action: model.importVidystCollection)
                    Button("Import studio…", action: model.importProject)
                    Button("Export studio…", action: model.exportProject)
                    Divider()
                    Toggle("Auto-switching", isOn: $model.project.autoSwitch)
                } label: { Text("+ New layout").font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioPalette.gold) }
                    .menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 18) {
                    builtInLayoutSection("SOLO", names: ["Just me", "Framed"])
                    builtInLayoutSection("SCREEN", names: StudioModel.layouts.filter { $0 != "Just me" && $0 != "Framed" })
                    let customScenes = model.project.scenes.filter { $0.templateName == nil }
                    if !customScenes.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            groupHeading("CUSTOM")
                            HStack(spacing: 8) {
                                ForEach(customScenes) { scene in
                                    layoutCard(scene, selected: scene.id == model.scene.id) { model.selectScene(scene.id) }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 7)
            }.frame(height: 112)
        }.padding(.top, 12).padding(.bottom, 3).background(StudioPalette.panel)
    }
    private func builtInLayoutSection(_ title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            groupHeading(title)
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    let existing = model.project.scenes.first(where: { $0.templateName == name })
                    layoutCard(existing ?? StudioModel.templateScene(name), selected: existing?.id == model.scene.id) {
                        model.selectTemplate(name)
                    }
                }
            }
        }
    }
    private func layoutCard(_ scene:StudioScene,selected:Bool,action:@escaping()->Void)->some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:5) {
                LayoutThumbnail(scene:scene,vertical:model.vertical,selected:selected).frame(width:112,height:58)
                Text(scene.name).lineLimit(1).frame(width:112,alignment:.center)
                    .font(.system(size:10,weight:selected ? .semibold:.regular))
            }.frame(width:112)
        }.buttonStyle(.plain).accessibilityLabel("Select layout " + scene.name)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func groupHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(StudioPalette.muted)
    }
    @ViewBuilder private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(model.panel == "Chat" ? "Live chat" : model.panel == "Edit" ? "Edit scene" : model.panel == "Prompter" ? "Teleprompter" : model.panel == "Recordings" ? "Recordings" : model.panel)
                    .font(.system(size: 14, weight: .bold))
                Text(model.panel == "Chat" ? "All destinations" : model.panel == "Edit" ? model.selectedLayout : model.panel == "Prompter" ? "Script editor" : model.panel == "Recordings" ? "\(model.library.items.count) takes" : "")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).frame(height: 50)
            Divider()
            switch model.panel {
            case "Edit": SourceEditor(model: model)
            case "Elements": ElementsView(model: model)
            case "Chat": chatPanel
            case "Audio": AudioPanel(model: model)
            case "Prompter": PrompterView(model: model)
            case "Recordings": RecordingLibraryView(model: model)
            case "Backstage": unavailablePanel(symbol: "bubble.left.and.bubble.right", title: "Backstage", detail: "Private guest conversations require a connected guest service. This build does not yet connect to a guest room.")
            case "Guests": unavailablePanel(symbol: "person.2", title: "Invite guests", detail: "Guest invitations and browser video calls require an independent guest service. This service is not connected in this build.")
            default: EmptyView()
            }
        }.frame(maxHeight: .infinity).background(StudioPalette.panel)
    }
    private var chatPanel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("YouTube & local",systemImage:"bubble.left.and.bubble.right").font(.system(size:11,weight:.medium)).foregroundStyle(StudioPalette.muted)
                    Spacer()
                    Button { model.showDestinations = true } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.plain).foregroundStyle(StudioPalette.muted).help("Manage chat destinations")
                }
                HStack(spacing: 0) {
                    ForEach(ChatFilter.allCases, id: \.self) { filter in
                        Button { chatFilter = filter } label: {
                            Text(filter.rawValue).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9).contentShape(Rectangle())
                                .foregroundStyle(chatFilter == filter ? StudioPalette.gold : StudioPalette.muted)
                                .background(chatFilter == filter ? Color(hex: "#38352E") : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel("Chat filter " + filter.rawValue).accessibilityAddTraits(chatFilter == filter ? [.isSelected]:[])
                    }
                }.padding(2).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioPalette.border))
            }.padding(14)
            Divider()
            ScrollView {
                if visibleChat.isEmpty {
                    Text(chatFilter == .paid ? "No paid messages yet. Super Chats and other paid events appear here." : chatFilter == .messages ? "No regular messages yet. Paid events are hidden in this view." : "Connect a live YouTube broadcast to see chat, or add a local overlay below.")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.muted.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 34)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleChat) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "person.crop.circle.fill").foregroundStyle(StudioPalette.muted)
                                    Text(item.author).font(.system(size: 11, weight: .semibold))
                                    Text(item.platform).font(.system(size: 9)).foregroundStyle(StudioPalette.muted)
                                    Spacer()
                                }
                                Text(item.message).font(.system(size: 12)).textSelection(.enabled)
                                Button(item.onScreen ? "Hide from output" : "Pin to output") { model.showMessage(item.id) }
                                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(StudioPalette.gold)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(12)
                }
            }
            YouTubeChatStatus(api:model.youtube)
            Divider()
            StudioChatComposer(model:model,session:model.youtubeSession)
        }
    }
    private var visibleChat:[ChatMessage] {model.chat.filter(chatFilter.includes)}
    private func unavailablePanel(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(StudioPalette.muted)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(StudioPalette.muted).multilineTextAlignment(.center)
            Spacer()
        }.padding(24)
    }
    private var rail: some View {
        VStack(spacing: 10) {
            ForEach([("Chat", "bubble.left.and.text.bubble.right"), ("Recordings", "film.stack"), ("Backstage", "bubble.left.and.bubble.right"), ("Guests", "person.2"), ("Audio", "waveform"), ("Elements", "sparkles"), ("Prompter", "text.bubble"), ("Edit", "square.3.layers.3d")], id: \.0) { item in
                Button { model.panel = item.0 } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.1).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
                            .foregroundStyle(model.panel == item.0 ? StudioPalette.base : StudioPalette.text.opacity(0.85))
                            .background(model.panel == item.0 ? StudioPalette.gold : StudioPalette.control)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: model.panel == item.0 ? StudioPalette.gold.opacity(0.28) : .clear, radius: 8)
                        Text(item.0).font(.system(size: 10, weight: model.panel == item.0 ? .semibold : .medium)).foregroundStyle(model.panel == item.0 ? StudioPalette.text : StudioPalette.muted)
                    }.frame(width: 68)
                }.buttonStyle(.plain).help(item.0)
            }
            Spacer(minLength: 12)
            Button { model.showSettings = true } label: {
                VStack(spacing: 5) {
                    Image(systemName: "gearshape.fill").font(.system(size: 15))
                    Text("Settings").font(.system(size: 9, weight: .medium))
                }
                .padding(.vertical, 6).frame(width: 58)
                .background(StudioPalette.control.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).foregroundStyle(StudioPalette.muted).padding(.bottom, 12)
        }.padding(.top, 12).frame(width: 72).background(StudioPalette.panel)
    }
}

private struct StudioToolbar: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var google: GoogleYouTubeController
    init(model: StudioModel) { self.model = model; self.google = model.google }
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Scene", selection: Binding(get: { model.scene.id }, set: { model.selectScene($0) })) {
                    ForEach(model.project.scenes) { scene in Text(scene.name).tag(scene.id) }
                }
                Button("New layout", action: model.addScene)
                Button("Duplicate layout", action: model.duplicateScene)
                Button("Remove layout", role: .destructive, action: model.removeScene).disabled(model.project.scenes.count < 2)
                Divider()
                Button("Import Vidyst collection…", action: model.importVidystCollection)
                Button("Import studio…", action: model.importProject)
                Button("Export studio…", action: model.exportProject)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .frame(width: 46, height: 26)
                .foregroundStyle(.white)
                .background(Color(hex: "#7762DA"))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton).fixedSize()

            HStack(spacing: 6) {
                TextField("Studio name", text: $model.project.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioPalette.text)
                    .frame(maxWidth: 220)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(StudioPalette.card.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioPalette.border.opacity(0.5)))

            Spacer(minLength: 10)

            Button { model.showDestinations = true } label: {
                HStack(spacing: 6) {
                    let connected = google.channel != nil || model.project.destinations.contains(where: \.enabled)
                    Circle().fill(connected ? StudioPalette.success : Color.secondary).frame(width: 6, height: 6)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(google.channel?.title ?? (model.project.destinations.isEmpty ? "No channels" : "\(model.project.destinations.filter(\.enabled).count) destinations"))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }.font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioPalette.muted)
                    .padding(.horizontal, 12).frame(height: 33).background(StudioPalette.card)
                    .clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioPalette.border))
            }.buttonStyle(.plain)

            AudioToolbarPill(model: model, levels: model.engine.audioLevels)

            Divider().frame(height: 28)

            RecordingControls(model: model, engine: model.engine)
        }.padding(.horizontal, 12).frame(height: 52).background(StudioPalette.panel)
    }
}
private struct RecordingControls: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button(action: model.toggleRecording) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(StudioPalette.coral)
                            .frame(width: 9, height: 9)
                            .opacity(engine.recording ? (engine.recordingPaused ? 0.35 : 1.0) : 0.8)
                        Text(engine.isFinalizingRecording ? "Saving MP4…" : engine.recording ? duration : "Record")
                            .font(.system(size: 12, weight: .bold, design: engine.recording ? .monospaced : .default))
                    }
                    .frame(width: 128, height: 33)
                }.buttonStyle(.plain).disabled(engine.isFinalizingRecording)
                Divider().frame(height: 20)
                Button(action: model.toggleRecordingPause) {
                    Image(systemName: engine.recordingPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 28, height: 33)
                }
                .buttonStyle(.plain).disabled(!engine.recording).help(engine.recordingPaused ? "Resume recording" : "Pause recording")
            }
            .background(StudioPalette.card).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.recording ? StudioPalette.coral.opacity(0.6) : StudioPalette.border, lineWidth: 1))

            Button(action: model.toggleStreaming) {
                HStack(spacing: 6) {
                    if engine.streaming {
                        Circle().fill(.white).frame(width: 7, height: 7)
                    }
                    Label(engine.streaming ? "End stream" : "Go live", systemImage: engine.streaming ? "stop.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .frame(width: 185, height: 33)
                .background(engine.streaming ? Color(hex: "#C92A2A") : StudioPalette.coral)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).foregroundStyle(.white)
        }
    }
    private var duration: String {
        let seconds = max(0, Int(engine.elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
private struct CaptureControls: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    var body: some View {
        HStack(spacing: 12) {
            Button { if engine.screenActive { engine.stopScreenCapture() } else { enable("screen") } } label: {
                HStack(spacing: 5) {
                    Circle().fill(engine.screenActive ? StudioPalette.success : Color.secondary).frame(width: 6, height: 6)
                    Label(engine.screenActive ? "Stop sharing" : "Share screen", systemImage: "display")
                }
            }
            if engine.screenActive { Button("Change…", action: model.startScreen).help("Choose a display, window, or application") }
            Button { if engine.cameraActive || engine.cameraStarting { engine.stopCamera() } else { enable("camera") } } label: {
                HStack(spacing: 5) {
                    Circle().fill(engine.cameraActive ? StudioPalette.success : engine.cameraStarting ? StudioPalette.gold : Color.secondary).frame(width: 6, height: 6)
                    Label(engine.cameraStarting ? "Cancel camera start" : engine.cameraActive ? "Stop camera" : "Enable camera", systemImage: "video")
                }
            }
            if engine.screenActive {
                StudioBadge(text: "\(Int(engine.screenCaptureSize.width)) × \(Int(engine.screenCaptureSize.height)) px", style: .default)
            } else {
                Text("Screen off").font(.caption).monospacedDigit().lineLimit(1).foregroundStyle(Color.secondary)
            }
            Spacer()
            Button {
                if model.panel == "Recordings" {
                    model.panel = "Edit"
                } else {
                    model.panel = "Recordings"
                }
            } label: { Image(systemName: "film.stack") }.help("In-app recording library")
            Button { model.revealRecordings() } label: { Image(systemName: "folder") }.help("Show recordings in Finder")
            Button { NotificationCenter.default.post(name: Notification.Name("FramecastShowSetup"), object: nil) } label: { Image(systemName: "lock.shield") }.help("Permissions & Setup")
        }.buttonStyle(StudioButtonStyle()).controlSize(.small)
    }
    private func enable(_ kind: String) {
        if let existing = model.selectedSources.first(where: { $0.kind == kind }) {
            model.selectedSourceID = existing.id; model.editSource { $0.visible = true }
            if kind == "screen" { model.startScreen() } else { model.startCamera() }
        } else { model.addSource(kind) }
    }
}
private struct StudioPreview: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: MediaEngine
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 16) {
                if model.canvasMode != "vertical" { canvas(vertical: false, available: geometry.size) }
                if model.canvasMode != "horizontal" { canvas(vertical: true, available: geometry.size) }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .overlay(alignment: .bottomLeading) {
                    if let error = engine.errorMessage {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                            .padding(8).background(StudioPalette.base.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
        }
    }
    private func canvas(vertical: Bool, available: CGSize) -> some View {
        let output=model.canvasSize(vertical:vertical)
        let ratio=output.width/output.height
        let horizontal=model.canvasSize(vertical:false),portrait=model.canvasSize(vertical:true)
        let combined:CGFloat=model.canvasMode=="both" ? horizontal.width/horizontal.height+portrait.width/portrait.height:ratio
        let height = min(max(1, available.height - 26), max(1, available.width - (model.canvasMode == "both" ? 16 : 0)) / combined)
        let width = height * ratio
        let selected = model.vertical == vertical
        let preview = selected ? engine.preview : engine.secondaryPreview
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(vertical ? "Vertical (9:16)" : "Horizontal (16:9)").font(.system(size: 12, weight: .bold))
                if width >= 160 {
                    StudioBadge(text: "\(Int(output.width)) × \(Int(output.height))", style: .default)
                }
                if selected && model.panel == "Edit" {
                    StudioBadge(text: "EDITING", icon: "pencil", style: .accent)
                }
            }.lineLimit(1).frame(width: width, alignment: .leading).contentShape(Rectangle()).onTapGesture {model.vertical=vertical;model.selectedSourceID=nil;model.refreshComposition()}
            ZStack {
                Color.black
                if let preview { Image(nsImage: preview).resizable().interpolation(.high).scaledToFit() }
                CanvasEditor(model:model,vertical:vertical,size:CGSize(width:width,height:height),screenActive:engine.screenActive,cameraActive:engine.cameraActive)
            }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected && model.panel == "Edit" ? StudioPalette.gold : StudioPalette.border, lineWidth: selected && model.panel == "Edit" ? 1.5 : 1))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        }
            .accessibilityElement(children: .contain).accessibilityLabel("\(vertical ? "Vertical" : "Horizontal") canvas\(selected ? ", editing" : "")")
            .help("\(Int(output.width)) × \(Int(output.height)) · Select \(vertical ? "vertical" : "horizontal") canvas for editing")
    }
}
private struct LayoutThumbnail: View {
    let scene: StudioScene
    let vertical: Bool
    let selected: Bool
    private var sources: [StudioSource] { vertical ? (scene.verticalSources ?? scene.sources) : scene.sources }
    var body: some View {
        GeometryReader { geometry in
            let ratio: CGFloat = vertical ? 9.0 / 16.0 : 16.0 / 9.0
            let height = min(geometry.size.height - 2, (geometry.size.width - 2) / ratio)
            let width = height * ratio
            ZStack {
                StudioPalette.base
                ZStack(alignment: .topLeading) {
                    Color(hex: scene.background)
                    ForEach(sources.filter(\.visible)) { source in
                        RoundedRectangle(cornerRadius: min(CGFloat(source.cornerRadius) * width / 1920, min(CGFloat(source.width) * width, CGFloat(source.height) * height) / 2))
                            .fill(layerColor(source))
                            .frame(width: max(0, CGFloat(source.width) * width), height: max(0, CGFloat(source.height) * height))
                            .rotationEffect(.degrees(source.rotation ?? 0))
                            .opacity(source.opacity)
                            .overlay {
                                if source.kind=="camera" || source.kind=="screen" {Image(systemName:source.kind=="camera" ? "person.fill":"display").font(.system(size:10)).foregroundStyle(.white.opacity(0.8))}
                            }
                            .offset(x: CGFloat(source.x) * width, y: CGFloat(source.y) * height)
                    }
                }.frame(width: width, height: height, alignment:.topLeading).clipped()
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? StudioPalette.gold : StudioPalette.border, lineWidth: selected ? 1.5 : 1))
                .shadow(color: selected ? StudioPalette.gold.opacity(0.2) : .clear, radius: 4)
        }.frame(height: 60)
    }
    private func layerColor(_ source: StudioSource) -> Color {
        switch source.kind {
        case "camera": return Color(hex: "#A1947C")
        case "screen": return Color(hex: "#656178")
        case "text": return Color(hex: "#CEC8BA")
        case "color": return Color(hex: source.text)
        default: return Color(hex: "#514C42")
        }
    }
}

private struct SourceEditor: View {
    @ObservedObject var model: StudioModel
    @StoredViewState<Bool> private var cameraStarting = false
    @StoredViewState<String> private var tab = "Transform"
    private func sourceBinding<T>(_ path: WritableKeyPath<StudioSource, T>, default value: T) -> Binding<T> {
        Binding(get: { model.source?[keyPath: path] ?? value }, set: { new in model.editSource { $0[keyPath: path] = new } })
    }
    private func optionalSourceBinding<T>(_ path: WritableKeyPath<StudioSource, T?>, default value: T) -> Binding<T> {
        Binding(get: { model.source?[keyPath: path] ?? value }, set: { new in model.editSource { $0[keyPath: path] = new } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    section("LAYOUT")
                    Text(model.selectedLayout).font(.system(size: 12, weight: .bold))
                    Spacer()
                }
                HStack {
                    section("CANVAS")
                    Spacer()
                    HStack(spacing: 0) {
                        editCanvas("Horizontal", vertical: false)
                        editCanvas("Vertical", vertical: true)
                    }.padding(2).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioPalette.border))
                }
                HStack {
                    section("LAYERS  \(model.selectedSources.count)")
                    Spacer()
                    Menu {
                        Button("Camera") { model.addSource("camera") }
                        Button("Screen capture") { model.addSource("screen") }
                        Button("Image…") { model.addSource("image") }
                        Button("Text") { model.addSource("text") }
                        Button("Color") { model.addSource("color") }
                    } label: { Text("+ Source").font(.system(size: 11, weight: .semibold)) }
                        .menuStyle(.borderlessButton).fixedSize().padding(7).background(Color(hex: "#2B2822")).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                VStack(spacing: 5) {
                    ForEach(model.selectedSources.reversed()) { source in
                        HStack(spacing: 9) {
                            Image(systemName: "circle.grid.2x3.fill").font(.system(size: 8)).foregroundStyle(StudioPalette.muted)
                            Text(source.kind == "camera" ? "CAM" : source.kind == "screen" ? "SCR" : source.kind == "text" ? "TXT" : source.kind == "color" ? "CLR" : "IMG")
                                .font(.system(size: 8, weight: .bold)).padding(4).foregroundStyle(model.selectedSourceID == source.id ? StudioPalette.gold : StudioPalette.muted)
                                .background(Color(hex: "#2D2922")).clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(source.name).lineLimit(1).font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 0)
                            Button {
                                model.selectedSourceID = source.id; model.editSource { $0.visible.toggle() }
                            } label: { Image(systemName: source.visible ? "eye" : "eye.slash").font(.system(size: 11)) }
                                .buttonStyle(.plain).foregroundStyle(StudioPalette.muted).help("Toggle layer visibility")
                        }.padding(.horizontal, 8).frame(height: 36)
                            .background(model.selectedSourceID == source.id ? Color(hex: "#353024") : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.selectedSourceID == source.id ? StudioPalette.gold.opacity(0.5) : .clear))
                            .contentShape(Rectangle()).onTapGesture { model.selectedSourceID = source.id }
                    }
                    if model.selectedSources.isEmpty { Text("Add a source to this layout.").font(.system(size: 12)).foregroundStyle(StudioPalette.muted).padding(.vertical, 16) }
                }
                Divider()
                if let source = model.source {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                        TextField("Source name", text: sourceBinding(\.name, default: "")).font(.system(size: 12, weight: .bold)).textFieldStyle(.plain)
                    }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(StudioPalette.base)
                        .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioPalette.border))
                    SourceFrameTools(model:model)
                    if source.kind == "text" { TextField("Text", text: sourceBinding(\.text, default: ""), axis: .vertical).lineLimit(2...5) }
                    if source.kind == "color" { TextField("Color hex", text: sourceBinding(\.text, default: "#3B5367")) }
                    if source.kind == "image" { Button("Choose image…", action: chooseImage) }
                    if source.kind == "camera" {
                        Button(cameraStarting ? "Starting camera…" : "Enable camera", action: model.startCamera).disabled(cameraStarting)
                            .onReceive(model.engine.$cameraStarting.removeDuplicates()) { cameraStarting = $0 }
                    }
                    if source.kind == "screen" { Button("Enable screen capture", action: model.startScreen) }
                    HStack(spacing: 9) {
                        section("SHAPE")
                        HStack(spacing: 0) {
                            shape("Rectangle", radius: 0, selected: source.cornerRadius == 0)
                            shape("Rounded", radius: 24, selected: source.cornerRadius > 0 && !source.isCircle(canvas:model.canvasSize(vertical:model.vertical)))
                            shape("Circle", radius: 500, selected: source.isCircle(canvas:model.canvasSize(vertical:model.vertical)))
                        }.padding(2).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    HStack(spacing: 0) {
                        ForEach(["Transform", "Filters", "Color"], id: \.self) { name in
                            Button { tab = name } label: {
                                Text(name).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .foregroundStyle(tab == name ? StudioPalette.gold : StudioPalette.muted)
                                    .background(tab == name ? Color(hex: "#35312A") : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }.padding(3).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.border))
                    if tab == "Transform" {
                        section("ALIGN")
                        HStack(spacing: 8) {
                            alignButton("Align left", "align.horizontal.left") { $0.x = 0 }
                            alignButton("Center horizontally", "align.horizontal.center") { $0.x = (1 - $0.width) / 2 }
                            alignButton("Align right", "align.horizontal.right") { $0.x = 1 - $0.width }
                            alignButton("Align top", "align.vertical.top") { $0.y = 0 }
                            alignButton("Center vertically", "align.vertical.center") { $0.y = (1 - $0.height) / 2 }
                            alignButton("Align bottom", "align.vertical.bottom") { $0.y = 1 - $0.height }
                        }
                        HStack {
                            Button("Reset to layout", action: model.resetSelectedLayout).frame(maxWidth: .infinity)
                        }.font(.system(size: 10, weight: .semibold)).buttonStyle(StudioButtonStyle())
                        Divider()
                        section("POSITION & SIZE")
                        HStack { pixelField("X", path: \.x, scale: Double(model.outputWidth)); pixelField("Y", path: \.y, scale: Double(model.outputHeight)) }
                        HStack { pixelField("W", path: \.width, scale: Double(model.outputWidth)); pixelField("H", path: \.height, scale: Double(model.outputHeight)) }
                        StudioSegmentedControl(options: [("Fit","fit"),("Fill","fill"),("Stretch","stretch")], selection: optionalSourceBinding(\.fit, default: source.kind == "screen" ? "fit":"fill"))
                        Divider()
                        HStack { section("TRANSFORM"); Spacer(); Toggle("Mirror", isOn: sourceBinding(\.mirrored, default: false)).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)) }
                        slider("Rotation", value: optionalSourceBinding(\.rotation, default: 0), range: -180...180)
                        slider("Opacity", value: sourceBinding(\.opacity, default: 1), range: 0...1)
                        slider("Corners", value: sourceBinding(\.cornerRadius, default: 0), range: 0...max(500,min(source.width*Double(model.outputWidth),source.height*Double(model.outputHeight))/2)).disabled(source.shape == .circle)
                        Divider()
                        section("CROP")
                        slider("Left", value: optionalSourceBinding(\.cropLeft, default: 0), range: 0...max(0, min(0.9, 0.99 - (source.cropRight ?? 0))))
                        slider("Top", value: optionalSourceBinding(\.cropTop, default: 0), range: 0...max(0, min(0.9, 0.99 - (source.cropBottom ?? 0))))
                        slider("Right", value: optionalSourceBinding(\.cropRight, default: 0), range: 0...max(0, min(0.9, 0.99 - (source.cropLeft ?? 0))))
                        slider("Bottom", value: optionalSourceBinding(\.cropBottom, default: 0), range: 0...max(0, min(0.9, 0.99 - (source.cropTop ?? 0))))
                    } else if tab == "Color" {
                        section("COLOR CORRECTION")
                        slider("Brightness", value: optionalSourceBinding(\.brightness, default: 0), range: -1...1)
                        slider("Contrast", value: optionalSourceBinding(\.contrast, default: 1), range: 0...4)
                        slider("Saturation", value: optionalSourceBinding(\.saturation, default: 1), range: 0...2)
                        Button("Reset color") { model.editSource { $0.brightness = nil; $0.contrast = nil; $0.saturation = nil } }
                    } else {
                        Text("Chroma key, luma key and LUT filters are not implemented in this build. Color correction is available in Color.")
                            .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                    }
                    Divider()
                    HStack {
                        Button { model.moveSource(1) } label: { Image(systemName: "arrow.up") }.help("Move above")
                        Button { model.moveSource(-1) } label: { Image(systemName: "arrow.down") }.help("Move below")
                        Spacer()
                        Button(action: model.duplicateSource) { Image(systemName: "plus.square.on.square") }.help("Duplicate layer")
                        Button(action: model.removeSource) { Image(systemName: "trash") }.help("Remove layer")
                    }
                }
                Divider()
                section("BACKGROUND")
                TextField("Background hex", text: Binding(get: { model.scene.background }, set: { value in model.editScene { $0.background = value } }))
                section("LOWER THIRD")
                TextField("Name or caption", text: $model.project.lowerThird).onChange(of: model.project.lowerThird) { _, _ in model.refreshComposition() }
                Toggle("Show on output", isOn: $model.project.lowerThirdVisible).onChange(of: model.project.lowerThirdVisible) { _, _ in model.refreshComposition() }
            }.textFieldStyle(StudioTextFieldStyle()).padding(16)
        }
    }
    private func section(_ title: String) -> some View { Text(title.localizedLowercase.capitalized).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioPalette.muted) }
    private func editCanvas(_ title: String, vertical: Bool) -> some View {
        Button { model.vertical = vertical; if model.canvasMode != "both" { model.canvasMode = vertical ? "vertical" : "horizontal" }; model.refreshComposition() } label: {
            Text(title).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(model.vertical == vertical ? StudioPalette.gold : StudioPalette.muted)
                .background(model.vertical == vertical ? Color(hex: "#35312A") : .clear).clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
    private func shape(_ title: String, radius: Double, selected: Bool) -> some View {
        Button { model.setSourceShape(title) } label: {
            Text(title).font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(selected ? StudioPalette.gold : StudioPalette.muted).background(selected ? Color(hex: "#35312A") : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
    private func alignButton(_ title: String, _ icon: String, edit: @escaping (inout StudioSource) -> Void) -> some View {
        Button { model.editSource(edit) } label: { Image(systemName: icon).font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 8) }
            .buttonStyle(.plain).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 6)).help(title).accessibilityLabel(title)
    }
    private func pixelField(_ title: String, path: WritableKeyPath<StudioSource, Double>, scale: Double) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(StudioPalette.muted)
            TextField(title, value: Binding(get: { (model.source?[keyPath: path] ?? 0) * scale }, set: { value in
                guard value.isFinite, scale > 0 else { return }
                model.editSource { $0[keyPath: path] = (title == "W" || title == "H") ? max(0.02, min(2, value / scale)) : max(-1, min(1, value / scale)) }
            }), format: .number.precision(.fractionLength(0))).textFieldStyle(.plain).multilineTextAlignment(.trailing)
            Text("px").foregroundStyle(StudioPalette.muted).font(.system(size: 9))
        }.font(.system(size: 11)).padding(9).disabled(model.source?.locked==true).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioPalette.border))
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        StudioValueSlider(title: title, value: value, range: range)
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { model.editSource { $0.path = url.path } }
    }
}

struct AudioPanel: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        ScrollView { AudioMixerPanel(model: model, engine: model.engine).padding(16) }
    }
}

struct CustomDestinationsView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @StoredViewState<UUID?> private var selected: UUID? = nil
    @StoredViewState<String> private var key = ""
    @StoredViewState<String?> private var error: String? = nil
    private var index: Int? { model.project.destinations.firstIndex { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Stream destinations").font(.title2.bold()); Spacer(); Button("Done") { saveKey(); if error == nil { model.save(); dismiss() } }.keyboardShortcut(.defaultAction) }
            Text("Stream simultaneously to all enabled RTMP destinations with zero-redundancy orientation packing. Stream keys are saved securely in macOS Keychain.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.project.destinations) { destination in
                        Button { load(destination.id) } label: {
                            HStack {
                                Image(systemName: destination.enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(destination.enabled ? StudioPalette.gold : StudioPalette.muted)
                                Text(destination.name)
                                Spacer()
                                Text(destination.vertical ? "9:16" : "16:9")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(StudioPalette.muted)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(StudioPalette.control).clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .padding(10).background(selected == destination.id ? Color.white.opacity(0.12) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                    Button("+ Add RTMP destination") {
                        let item = StreamDestination(name: "Custom RTMP", url: "rtmp://", enabled: true, vertical: false)
                        model.project.destinations.append(item); load(item.id)
                    }
                }.frame(width: 200)
                Divider()
                if let i = index {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Destination name", text: $model.project.destinations[i].name)
                        TextField("RTMP server URL", text: $model.project.destinations[i].url)
                        SecureField("Stream key", text: $key)
                        Toggle("Enabled for live streaming", isOn: $model.project.destinations[i].enabled)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("STREAM ORIENTATION").font(.system(size: 10, weight: .bold)).foregroundStyle(StudioPalette.muted)
                            Picker("Stream orientation", selection: Binding(
                                get: { model.project.destinations[i].vertical ? "vertical" : "horizontal" },
                                set: { model.project.destinations[i].vertical = ($0 == "vertical") }
                            )) {
                                Text("Horizontal (16:9)").tag("horizontal")
                                Text("Vertical (9:16)").tag("vertical")
                            }
                            .pickerStyle(.segmented)
                            Text("Destinations sharing an orientation are encoded once and dispatched in parallel with zero extra GPU/CPU load.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        
                        HStack {
                            Button("Save destination") { saveKey(); model.save() }
                            Button("Remove", role: .destructive) {
                                try? CredentialStore.set("", for: model.project.destinations[i].id)
                                model.project.destinations.remove(at: i); selected = nil; key = ""; model.save()
                            }
                        }
                        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }.textFieldStyle(StudioTextFieldStyle()).frame(maxWidth: .infinity)
                } else { Text("Select a destination or add your RTMP server.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(minHeight: 270)
        }.padding(24).frame(width: 700).preferredColorScheme(.dark).interactiveDismissDisabled()
            .onAppear { if let first = model.project.destinations.first { load(first.id) } }
    }
    private func load(_ id: UUID) { if selected != nil { saveKey(); guard error == nil else { return } }; selected = id; key = CredentialStore.get(id); error = nil }
    private func saveKey() {
        guard let selected else { return }
        do { try CredentialStore.set(key, for: selected); error = nil } catch { self.error = "Could not save the stream key: \(error.localizedDescription)" }
    }
}

