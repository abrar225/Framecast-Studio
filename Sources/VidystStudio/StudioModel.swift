import SwiftUI
import AppKit
import AVFoundation
import Security
import Combine

struct StudioSource: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: String
    var text = ""
    var path = ""
    var x = 0.0, y = 0.0, width = 1.0, height = 1.0
    var opacity = 1.0
    var visible = true, mirrored = false
    var cornerRadius = 0.0
    var rotation: Double?
    var cropLeft: Double?, cropTop: Double?, cropRight: Double?, cropBottom: Double?
    var fit: String?
    var brightness: Double?, contrast: Double?, saturation: Double?
    var shape:SourceShape?
    var locked:Bool?
    var aspectLocked:Bool?
    var symbol: String { switch kind { case "camera": return "video"; case "screen": return "display"; case "image": return "photo"; case "text": return "textformat"; case "color": return "paintpalette"; default: return "square.stack" } }
}
struct StudioScene: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var sources: [StudioSource] = []
    var background = "#151312"
    var layout = "Screen + cam"
    var verticalSources: [StudioSource]?
    var verticalLayout: String?
    var templateName: String?
}
struct StreamDestination: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
    var vertical = false
}
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var author: String
    var message: String
    var platform = "Local"
    var pinned = false
    var onScreen = false
    var providerMessageID: String?
    var paid: Bool?
    var publishedAt: String?
}
enum ChatFilter:String,CaseIterable {
    case all="All",paid="Paid",messages="Messages"
    func includes(_ message:ChatMessage)->Bool {
        switch self {case .all:return true;case .paid:return message.paid ?? false;case .messages:return !(message.paid ?? false)}
    }
}
struct StudioElement: Identifiable, Codable {
    var id = UUID()
    var name: String
    var title: String
    var subtitle = ""
    var kind = "text"
    var background = "#302A25"
    var visible = false
    var autoHideAfter = 0.0
    static var presets: [StudioElement] { [
        StudioElement(name:"Host lower third",title:"Your name",subtitle:"What you’re making today",kind:"lower"),
        StudioElement(name:"Guest intro",title:"Guest name",subtitle:"What they do",kind:"lower",autoHideAfter:10),
        StudioElement(name:"Be right back",title:"Back in 5 minutes",subtitle:"Grab a coffee, we’ll be right here"),
        StudioElement(name:"Q&A",title:"Ask me anything in chat"),
        StudioElement(name:"Thanks for watching",title:"Thanks for watching",subtitle:"See you next stream",kind:"thanks"),
        StudioElement(name:"Link",title:"Scan for the link",subtitle:"https://example.com",kind:"qr",autoHideAfter:30)
    ] }
}

struct StudioProject: Codable {
    var version = 1
    var name = "Untitled studio"
    var scenes = [StudioScene(name: "Main", sources: [StudioSource(name: "Title", kind: "text", text: "Your show starts here", x: 0.045, y: 0.8, width: 0.65, height: 0.12)])]
    var selectedSceneID: UUID?
    var selectedVerticalSceneID: UUID?
    var destinations: [StreamDestination] = []
    var width = 1920, height = 1080, fps = 30
    var verticalWidth: Int?, verticalHeight: Int?
    var verticalFPS: Int?
    var mediaPreferences: MediaPreferences?
    var recordingFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Vidyst Reconstructed").path
    var microphoneVolume = 1.0
    var microphoneMuted = false
    var captureSystemAudio: Bool?
    var capturedAudioVolume: Double?
    var lowerThird = "", lowerThirdVisible = false
    var autoSwitch = false
    var canvasVisibility: String?
    var editingVertical: Bool?
    var linkedLayouts: Bool?
    var elements: [StudioElement]?
    var cameraDeviceID = ""
    var microphoneDeviceID = ""
}

enum ProjectDocument {
    private static func validVerticalDimensions(_ project:StudioProject)->Bool {
        guard let width=project.verticalWidth,let height=project.verticalHeight else{return project.verticalWidth==nil && project.verticalHeight==nil}
        return (64...3840).contains(width) && (64...3840).contains(height) && width%2==0 && height%2==0 && width*height<=3840*2160
    }
    static func decode(_ data: Data) throws -> StudioProject {
        let project = try JSONDecoder().decode(StudioProject.self, from: data)
        guard project.version == 1, !project.scenes.isEmpty,
              project.canvasVisibility == nil || ["horizontal","vertical","both"].contains(project.canvasVisibility!),
              (320...3840).contains(project.width), (240...3840).contains(project.height),
              project.width * project.height <= 3840 * 2160,
              project.width % 2 == 0, project.height % 2 == 0,
              validVerticalDimensions(project),
              project.verticalFPS == nil || MediaPreferences.frameRates.contains(project.verticalFPS!),
              project.mediaPreferences?.isValid ?? true,
              MediaPreferences.frameRates.contains(project.fps),
              project.microphoneVolume.isFinite, (0...4).contains(project.microphoneVolume),
              (project.capturedAudioVolume ?? 1).isFinite, (0...4).contains(project.capturedAudioVolume ?? 1),
              Set(project.scenes.map(\.id)).count == project.scenes.count,
              Set(project.destinations.map(\.id)).count == project.destinations.count,
              Set((project.elements ?? []).map(\.id)).count == (project.elements ?? []).count,
              (project.elements ?? []).allSatisfy({$0.autoHideAfter.isFinite && (0...120).contains($0.autoHideAfter)}),
              project.scenes.allSatisfy({ scene in
                  [scene.sources,scene.verticalSources ?? []].allSatisfy { sources in
                  Set(sources.map(\.id)).count == sources.count && sources.allSatisfy { source in
                      [source.x,source.y,source.width,source.height,source.opacity,source.cornerRadius,source.rotation ?? 0,source.cropLeft ?? 0,source.cropTop ?? 0,source.cropRight ?? 0,source.cropBottom ?? 0,source.brightness ?? 0,source.contrast ?? 1,source.saturation ?? 1].allSatisfy(\.isFinite) && source.width > 0 && source.height > 0 && (0...1).contains(source.opacity) &&
                      [source.cropLeft ?? 0,source.cropTop ?? 0,source.cropRight ?? 0,source.cropBottom ?? 0].allSatisfy({(0...0.99).contains($0)}) &&
                      (source.cropLeft ?? 0)+(source.cropRight ?? 0)<1 && (source.cropTop ?? 0)+(source.cropBottom ?? 0)<1 &&
                      (-1...1).contains(source.brightness ?? 0) && (0...4).contains(source.contrast ?? 1) && (0...2).contains(source.saturation ?? 1) &&
                      ["fit","fill","stretch"].contains(source.fit ?? "fill")
                  }
              }}) else { throw NSError(domain:"StudioDocument",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid or unsupported studio document. The original file has been preserved."]) }
        return project
    }
}

enum CredentialStore {
    static let service = "local.vidyst.reconstructed.streams"
    static func set(_ value: String, for id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data
            let added = SecItemAdd(entry as CFDictionary, nil)
            if added != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func get(_ id: UUID) -> String {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:id.uuidString, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data:data, encoding:.utf8) ?? ""
    }
}

@MainActor final class StudioModel: ObservableObject {
    @Published var project:StudioProject {didSet {needsSave=true}}
    private var needsSave=true
    @Published var selectedSourceID: UUID?
    @Published var panel = "Chat"
    @Published var vertical = false
    @Published var canvasMode = "horizontal"
    let prompter = PrompterController()
    let google = GoogleYouTubeController()
    lazy var youtube = YouTubeLiveController(tokenProvider: { [weak self] in
        guard let self else {throw YouTubeLiveAPIError.authentication}
        return try await self.google.validAccessToken()
    })
    lazy var youtubeSession = YouTubeStudioSession(model:self,api:youtube)
    private var youtubeChatSubscription:AnyCancellable?
    @Published var showSettings = false
    @Published var showAddSource = false
    @Published var showDestinations = false
    @Published var chat: [ChatMessage] = []
    @Published var notice: String?
    var cameraActive: Bool { engine.cameraActive }
    var screenActive: Bool { engine.screenActive }
    @Published var settingsTab = "General"
    @Published var remoteActive = false
    @Published var remoteAddress = ""
    @Published var lastSaved: Date?
    let engine = MediaEngine()
    lazy var canvasInteraction=CanvasInteraction(model:self)
    let editUndoManager=UndoManager()
    private let lowerThirdLayerID=UUID()
    let projectURL: URL
    private var saveAllowed = true
    private var autosave: Timer?
    private var autoLayoutTimer: Timer?
    private var elementTimer: Timer?
    private var layoutSnapshots: [UUID:StudioScene] = [:]
    private var elementDeadlines: [UUID:Date] = [:]
    private var remote: RemoteServer?
    static let layouts = StudioLayouts.names

    init(projectURL: URL? = nil) {
        self.projectURL = projectURL ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Vidyst Reconstructed/studio.json")
        editUndoManager.groupsByEvent=false
        editUndoManager.levelsOfUndo=100
        var recoveryMessage: String?
        var canSave = true
        if FileManager.default.fileExists(atPath:self.projectURL.path) {
            do { project = try ProjectDocument.decode(Data(contentsOf:self.projectURL)) }
            catch {
                project = StudioProject()
                let backup = self.projectURL.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
                do { try FileManager.default.copyItem(at:self.projectURL,to:backup); recoveryMessage="Could not read studio. The original was copied to \(backup.path)." }
                catch { canSave=false; recoveryMessage="Could not read or back up studio: \(error.localizedDescription). Automatic saving is disabled." }
            }
        } else { project = StudioProject() }
        let upgraded=project.scenes.map {StudioLayouts.upgradedLegacy($0) ?? $0}
        if upgraded != project.scenes && canSave {
            do {
                if FileManager.default.fileExists(atPath:self.projectURL.path) {
                    try FileManager.default.copyItem(at:self.projectURL,to:self.projectURL.deletingPathExtension().appendingPathExtension("before-layout-upgrade-\(UUID().uuidString).json"))
                }
                project.scenes=upgraded
            } catch {recoveryMessage="Could not back up layouts for upgrade. Your saved layouts were preserved."}
        }
        if project.elements == nil { project.elements = StudioElement.presets }
        if !project.scenes.contains(where: {$0.id == project.selectedSceneID}) { project.selectedSceneID = project.scenes.first?.id }
        if !project.scenes.contains(where:{$0.id==project.selectedVerticalSceneID}) {project.selectedVerticalSceneID=project.selectedSceneID}
        layoutSnapshots=Dictionary(uniqueKeysWithValues:project.scenes.map{($0.id,$0)})
        notice = recoveryMessage
        saveAllowed = canSave
        autosave = Timer.scheduledTimer(withTimeInterval:2, repeats:true) { [weak self] _ in Task { @MainActor in self?.save() } }
        autoLayoutTimer = Timer.scheduledTimer(withTimeInterval:8, repeats:true) { [weak self] _ in Task { @MainActor in guard let self, self.project.autoSwitch else { return }; let index = Self.layouts.firstIndex(of:self.selectedLayout) ?? 0; self.applyLayout(Self.layouts[(index+1)%Self.layouts.count]) } }
        elementTimer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in Task { @MainActor in self?.expireElements() } }
        restoreCanvasSelection()
        syncAudio()
        refreshComposition()
        youtubeChatSubscription=youtube.$messages.sink { [weak self] messages in self?.receiveYouTubeChat(messages) }
    }
    func restoreCanvasSelection() {
        if !project.scenes.contains(where:{$0.id==project.selectedSceneID}){project.selectedSceneID=project.scenes.first?.id}
        if !project.scenes.contains(where:{$0.id==project.selectedVerticalSceneID}){project.selectedVerticalSceneID=project.selectedSceneID}
        canvasMode=["horizontal","vertical","both"].contains(project.canvasVisibility ?? "") ? project.canvasVisibility! : "horizontal"
        vertical=project.editingVertical ?? (canvasMode == "vertical")
    }
    func syncAudio() { engine.capturedAudioEnabled = project.captureSystemAudio ?? false; engine.capturedAudioGain = project.capturedAudioVolume ?? 1; engine.microphoneEnabled = !project.microphoneMuted; engine.microphoneGain = project.microphoneVolume; engine.selectedMicrophone = project.microphoneDeviceID.isEmpty ? nil : project.microphoneDeviceID }
    var sceneIndex: Int { project.scenes.firstIndex(where: {$0.id == (vertical ? project.selectedVerticalSceneID : project.selectedSceneID)}) ?? 0 }
    var scene: StudioScene { project.scenes[sceneIndex] }
    var selectedSources: [StudioSource] { vertical ? (scene.verticalSources ?? scene.sources) : scene.sources }
    var selectedLayout: String { vertical ? (scene.verticalLayout ?? scene.layout) : scene.layout }
    var source: StudioSource? { selectedSources.first(where: {$0.id == selectedSourceID}) }
    func canvasOutput(vertical: Bool) -> (width: Int, height: Int, fps: Int) {
        if vertical {
            return (project.verticalWidth ?? min(project.width, project.height),
                    project.verticalHeight ?? max(project.width, project.height),
                    project.verticalFPS ?? project.fps)
        }
        return (max(project.width, project.height), min(project.width, project.height), project.fps)
    }
    var outputWidth: Int { canvasOutput(vertical: vertical).width }
    var outputHeight: Int { canvasOutput(vertical: vertical).height }
    func editScene(action:String="Edit layout",_ edit:(inout StudioScene)->Void) {
        editCanvasScene(at:sceneIndex,onVerticalCanvas:vertical,action:action,edit)
    }
    private func editCanvasScene(at index:Int,onVerticalCanvas:Bool,action:String="Edit layout",_ edit:(inout StudioScene)->Void) {
        let original=project.scenes[index]
        var next=original
        if onVerticalCanvas {
            var canvas=original;canvas.sources=original.verticalSources ?? original.sources;canvas.layout=original.verticalLayout ?? original.layout
            edit(&canvas)
            next.verticalSources=canvas.sources;next.verticalLayout=canvas.layout
            next.name=canvas.name;next.background=canvas.background
        } else {
            if next.verticalSources==nil {next.verticalSources=original.sources}
            if next.verticalLayout==nil {next.verticalLayout=original.layout}
            edit(&next)
        }
        guard next != original else{return}
        project.scenes[index]=next
        refreshComposition()
        registerEditUndo(action){target in target.restoreCanvasRevision(original,vertical:onVerticalCanvas,action:action);target.save()}
    }
    private func restoreCanvasRevision(_ old:StudioScene,vertical:Bool,action:String) {
        guard let index=project.scenes.firstIndex(where:{$0.id==old.id}) else{return}
        canvasInteraction.cancel()
        editCanvasScene(at:index,onVerticalCanvas:vertical,action:action){canvas in
            canvas.sources=vertical ? (old.verticalSources ?? old.sources):old.sources
            canvas.layout=vertical ? (old.verticalLayout ?? old.layout):old.layout
            canvas.name=old.name;canvas.background=old.background
        }
        if let selectedSourceID,!selectedSources.contains(where:{$0.id==selectedSourceID}) {self.selectedSourceID=nil}
    }
    func editSource(_ edit:(inout StudioSource)->Void) {
        guard let original=source else{return}
        var next=original;edit(&next)
        guard let accepted=next.acceptingEdit(from:original,canvas:canvasSize(vertical:vertical)),accepted != original else{return}
        applySourceRevision(sceneID:scene.id,onVerticalCanvas:vertical,source:accepted,action:"Edit source")
    }
    private func applySourceRevision(sceneID:UUID,onVerticalCanvas:Bool,source next:StudioSource,action:String) {
        guard let index=project.scenes.firstIndex(where:{$0.id==sceneID}) else{return}
        let sources=onVerticalCanvas ? (project.scenes[index].verticalSources ?? project.scenes[index].sources):project.scenes[index].sources
        guard let slot=sources.firstIndex(where:{$0.id==next.id}),sources[slot] != next else{return}
        editCanvasScene(at:index,onVerticalCanvas:onVerticalCanvas,action:action){$0.sources[slot]=next}
    }
    private func registerEditUndo(_ action:String,_ edit:@escaping(StudioModel)->Void) {
        let group=editUndoManager.groupingLevel==0 && !editUndoManager.isUndoing && !editUndoManager.isRedoing
        if group {editUndoManager.beginUndoGrouping()}
        editUndoManager.registerUndo(withTarget:self,handler:edit)
        editUndoManager.setActionName(action)
        if group {editUndoManager.endUndoGrouping()}
    }
    private func replaceCanvasSources(_ next:[StudioSource],sceneID:UUID,vertical:Bool,action:String) {
        guard let index=project.scenes.firstIndex(where:{$0.id==sceneID}) else{return}
        let before=vertical ? (project.scenes[index].verticalSources ?? project.scenes[index].sources):project.scenes[index].sources
        guard before != next else{return}
        canvasInteraction.cancel()
        editCanvasScene(at:index,onVerticalCanvas:vertical,action:action){$0.sources=next}
        if let selectedSourceID,!next.contains(where:{$0.id==selectedSourceID}) {self.selectedSourceID=nil}
    }
    func previewSourceTransform(_ source:StudioSource,sceneID:UUID,vertical:Bool) {
        let selected=vertical ? project.selectedVerticalSceneID:project.selectedSceneID
        guard selected==sceneID else{return}
        engine.updateSourceTransform(source.id,vertical:vertical,x:source.x,y:source.y,width:source.width,height:source.height,cornerRadius:source.cornerRadius,shape:source.shape?.rawValue)
    }
    func commitSourceInteraction(_ session:CanvasInteraction.Session) {
        guard let scene=project.scenes.first(where:{$0.id==session.sceneID}) else{return}
        let sources=session.vertical ? (scene.verticalSources ?? scene.sources):scene.sources
        guard var latest=sources.first(where:{$0.id==session.source.id}),latest.locked != true else {refreshComposition();return}
        // Merge only geometry, preserving any independent visibility/style changes.
        latest.x=session.source.x;latest.y=session.source.y;latest.width=session.source.width;latest.height=session.source.height
        if latest.shape==session.original.shape {latest.shape=session.source.shape;latest.aspectLocked=session.source.aspectLocked}
        applySourceRevision(sceneID:session.sceneID,onVerticalCanvas:session.vertical,source:latest,action:session.action)
        save()
    }
    func renderConfiguration(onVerticalCanvas isVertical:Bool)->RenderConfiguration {
        let canvasScene=project.scenes.first(where:{$0.id == (isVertical ? project.selectedVerticalSceneID:project.selectedSceneID)}) ?? scene
        let sources=isVertical ? (canvasScene.verticalSources ?? canvasScene.sources):canvasScene.sources
        var layers = sources.map { s in RenderLayer(id:s.id,kind:s.kind,text:s.text,path:s.path,x:s.x,y:s.y,width:s.width,height:s.height,opacity:s.opacity,visible:s.visible,mirrored:s.mirrored,cornerRadius:s.cornerRadius,rotation:s.rotation ?? 0,cropLeft:s.cropLeft ?? 0,cropTop:s.cropTop ?? 0,cropRight:s.cropRight ?? 0,cropBottom:s.cropBottom ?? 0,fit:s.fit ?? (s.kind == "screen" ? "fit":"fill"),brightness:s.brightness ?? 0,contrast:s.contrast ?? 1,saturation:s.saturation ?? 1,shape:s.shape?.rawValue) }
        if project.lowerThirdVisible && !project.lowerThird.isEmpty { layers.append(RenderLayer(id:lowerThirdLayerID,kind:"text",text:project.lowerThird,path:"",x:0.04,y:0.86,width:0.85,height:0.1,opacity:1,visible:true,mirrored:false,cornerRadius:0)) }
        if let message=chat.first(where:{$0.onScreen}) { layers.append(RenderLayer(id:message.id,kind:"text",text:"\(message.author): \(message.message)",path:"",x:0.04,y:0.72,width:0.9,height:0.12,opacity:1,visible:true,mirrored:false,cornerRadius:0)) }
        layers += elementLayers()
        return RenderConfiguration(backgroundHex:canvasScene.background,title:canvasScene.name,layers:layers,width:isVertical ? (project.verticalWidth ?? min(project.width,project.height)):max(project.width,project.height),height:isVertical ? (project.verticalHeight ?? max(project.width,project.height)):min(project.width,project.height),vertical:isVertical)
    }
    var outputFrameRate: Int { canvasOutput(vertical: vertical).fps }
    func setCanvasResolution(width: Int, height: Int, vertical: Bool) {
        guard MediaLimits.supports(width: width, height: height, fps: canvasOutput(vertical: vertical).fps),
              !engine.recording, !engine.streaming, !engine.isFinalizingRecording else { return }
        if vertical { project.verticalWidth = width; project.verticalHeight = height }
        else { project.width = width; project.height = height }
        refreshComposition(); save()
    }
    func setCanvasFrameRate(_ fps: Int, vertical: Bool) {
        guard MediaPreferences.frameRates.contains(fps), !engine.recording, !engine.streaming, !engine.isFinalizingRecording else { return }
        if vertical { project.verticalFPS = fps } else { project.fps = fps }
        refreshComposition(); save()
    }
    func setOutputFrameRate(_ fps: Int) {
        setCanvasFrameRate(fps, vertical: vertical)
    }
    func refreshComposition() {
        engine.setCaptureFrameRate(canvasMode == "both" ? max(project.fps, project.verticalFPS ?? project.fps) : outputFrameRate)
        if project.canvasVisibility != canvasMode {project.canvasVisibility=canvasMode}
        if project.editingVertical != vertical {project.editingVertical=vertical}
        engine.setCompositions(renderConfiguration(onVerticalCanvas:vertical),secondary:canvasMode == "both" ? renderConfiguration(onVerticalCanvas:!vertical):nil)
        if let pinned=engine.streamingVertical {engine.updateStreamingComposition(renderConfiguration(onVerticalCanvas:pinned))}
    }
    func save() {
        guard saveAllowed,needsSave else{return}
        do {
            try FileManager.default.createDirectory(at:projectURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            let data=try encoder.encode(project)
            if (try? Data(contentsOf:projectURL)) != data {try data.write(to:projectURL,options:.atomic);lastSaved=Date()}
            needsSave=false
        } catch { notice="Could not save studio: \(error.localizedDescription)" }
    }
    func addScene() { let new=StudioScene(name:"Scene \(project.scenes.count+1)"); project.scenes.append(new); selectScene(new.id) }
    func duplicateScene() { var copy=scene; copy.id=UUID(); copy.name += " copy";copy.templateName=nil; let ids=Dictionary(uniqueKeysWithValues:Set((copy.sources+(copy.verticalSources ?? [])).map(\.id)).map{($0,UUID())});copy.sources=copy.sources.map {var s=$0;s.id=ids[s.id]!;return s};copy.verticalSources=copy.verticalSources?.map {var s=$0;s.id=ids[s.id]!;return s}; project.scenes.append(copy); selectScene(copy.id) }
    func removeScene() { guard project.scenes.count>1 else { notice="Keep at least one scene in your studio.";return };canvasInteraction.cancel();editUndoManager.removeAllActions();let removed=scene.id;project.scenes.remove(at:sceneIndex);if project.selectedSceneID==removed {project.selectedSceneID=project.scenes[0].id};if project.selectedVerticalSceneID==removed {project.selectedVerticalSceneID=project.scenes[0].id};selectedSourceID=nil;refreshComposition();save() }
    var linkedLayouts:Bool {
        get {project.linkedLayouts ?? true}
        set {
            project.linkedLayouts=newValue
            if newValue && canvasMode=="both" {selectScene(scene.id)} else {save()}
        }
    }
    func selectScene(_ id:UUID) {
        guard project.scenes.contains(where:{$0.id==id}) else{return}
        canvasInteraction.cancel()
        if canvasMode=="both" && linkedLayouts {project.selectedSceneID=id;project.selectedVerticalSceneID=id}
        else if vertical {project.selectedVerticalSceneID=id} else {project.selectedSceneID=id}
        selectedSourceID=nil;refreshComposition();save()
    }
    func selectSource(_ id:UUID,onVerticalCanvas:Bool) {
        guard sources(onVerticalCanvas:onVerticalCanvas).contains(where:{$0.id==id}) else{return}
        let changed=vertical != onVerticalCanvas
        if changed {vertical=onVerticalCanvas}
        if selectedSourceID != id {selectedSourceID=id}
        if panel != "Edit" {panel="Edit"}
        if changed {refreshComposition()}
    }
    func sources(onVerticalCanvas:Bool)->[StudioSource] {
        guard let scene=project.scenes.first(where:{$0.id == (onVerticalCanvas ? project.selectedVerticalSceneID:project.selectedSceneID)}) else{return []}
        return onVerticalCanvas ? (scene.verticalSources ?? scene.sources):scene.sources
    }
    func setSourceFrame(_ id:UUID,onVerticalCanvas:Bool,x:Double,y:Double,width:Double,height:Double) {
        guard [x,y,width,height].allSatisfy(\.isFinite) else{return}
        guard sources(onVerticalCanvas:onVerticalCanvas).contains(where:{$0.id==id && $0.locked != true}) else{return}
        selectSource(id,onVerticalCanvas:onVerticalCanvas)
        editSource {$0.x=max(-0.95,min(0.98,x));$0.y=max(-0.95,min(0.98,y));$0.width=max(0.02,min(2,width));$0.height=max(0.02,min(2,height))}
    }
    func setSourceShape(_ shape:String) {
        guard let source,source.locked != true else{return}
        let width=Double(outputWidth),height=Double(outputHeight)
        editSource {layer in
            if shape=="Circle" {
                let side=min(source.width*width,source.height*height)
                layer.width=side/width;layer.height=side/height;layer.cornerRadius=side/2;layer.shape = .circle;layer.aspectLocked=true
            } else {layer.cornerRadius=shape=="Rounded" ? 24:0;layer.shape = shape=="Rounded" ? .rounded:.rectangle}
        }
    }
    func canvasSize(vertical:Bool)->CGSize {
        CGSize(width:vertical ? (project.verticalWidth ?? min(project.width,project.height)):max(project.width,project.height),height:vertical ? (project.verticalHeight ?? max(project.width,project.height)):min(project.width,project.height))
    }
    func sizeSelectedSource(_ fraction:Double) {
        guard let source,source.locked != true else{return}
        let frame=CanvasGeometry.sized(source,fraction:fraction,canvas:canvasSize(vertical:vertical))
        setSourceFrame(source.id,onVerticalCanvas:vertical,x:frame.x,y:frame.y,width:frame.width,height:frame.height);save()
    }
    func centerSelectedSource() {guard source?.locked != true else{return};editSource{$0.x=(1-$0.width)/2;$0.y=(1-$0.height)/2};save()}
    func nudgeSelectedSource(dx:Double,dy:Double) {
        guard let source,source.locked != true else{return}
        let size=canvasSize(vertical:vertical)
        setSourceFrame(source.id,onVerticalCanvas:vertical,x:source.x+dx/size.width,y:source.y+dy/size.height,width:source.width,height:source.height);save()
    }
    /// Source identities may be shared by both canvases; visibility belongs to
    /// the requested canvas. Materialize a legacy vertical fallback before editing.
    func toggleSourceVisibility(sceneID: UUID, sourceID: UUID, onVerticalCanvas: Bool) -> Bool {
        guard let index=project.scenes.firstIndex(where:{$0.id==sceneID}) else{return false}
        let sources=onVerticalCanvas ? (project.scenes[index].verticalSources ?? project.scenes[index].sources):project.scenes[index].sources
        guard let sourceIndex=sources.firstIndex(where:{$0.id==sourceID}) else{return false}
        var next=sources[sourceIndex];next.visible.toggle()
        applySourceRevision(sceneID:sceneID,onVerticalCanvas:onVerticalCanvas,source:next,action:"Toggle source visibility")
        save();return true
    }
    func addSource(_ kind: String) {
        var source=StudioSource(name:["camera":"Camera","screen":"Screen","image":"Image","text":"Text","color":"Color" ][kind] ?? kind.capitalized,kind:kind)
        if kind=="text" { source.text="Your text";source.x=0.06;source.y=0.8;source.width=0.8;source.height=0.12 }
        if kind=="color" { source.text="#3B5367" }
        if kind=="screen" {source.fit="fit"}
        if kind=="image" {
            let picker=NSOpenPanel();picker.allowedContentTypes=[.image];picker.canChooseDirectories=false
            guard picker.runModal() == .OK, let url=picker.url else { return };source.path=url.path;source.name=url.deletingPathExtension().lastPathComponent
        }
        replaceCanvasSources(selectedSources+[source],sceneID:scene.id,vertical:vertical,action:"Add source");selectedSourceID=source.id;save()
        if kind=="camera" { startCamera() }
        if kind=="screen" { startScreen() }
    }
    func removeSource() {guard let id=selectedSourceID else{return};replaceCanvasSources(selectedSources.filter{$0.id != id},sceneID:scene.id,vertical:vertical,action:"Remove source");selectedSourceID=nil;save()}
    func duplicateSource() {guard var s=source else{return};s.id=UUID();s.name += " copy";replaceCanvasSources(selectedSources+[s],sceneID:scene.id,vertical:vertical,action:"Duplicate source");selectedSourceID=s.id;save()}
    func moveSource(_ delta:Int) {guard let i=selectedSources.firstIndex(where:{$0.id==selectedSourceID}) else{return};let j=i+delta;guard selectedSources.indices.contains(j) else{return};var next=selectedSources;next.swapAt(i,j);replaceCanvasSources(next,sceneID:scene.id,vertical:vertical,action:"Reorder source");save()}
    func startCamera() { engine.startCamera(deviceID:project.cameraDeviceID.isEmpty ? nil : project.cameraDeviceID) }
    func startScreen() { engine.chooseScreenCapture() }
    func applyLayout(_ layout:String) {
        guard Self.layouts.contains(layout) else{return}
        let group=editUndoManager.groupingLevel==0
        if group {editUndoManager.beginUndoGrouping()}
        defer {editUndoManager.setActionName("Apply layout");if group {editUndoManager.endUndoGrouping()}}
        if canvasMode=="both" && linkedLayouts {
            let horizontal=project.scenes.firstIndex{$0.id==project.selectedSceneID} ?? sceneIndex
            let portrait=project.scenes.firstIndex{$0.id==project.selectedVerticalSceneID} ?? sceneIndex
            editCanvasScene(at:horizontal,onVerticalCanvas:false){StudioLayouts.apply(layout,to:&$0,vertical:false)}
            editCanvasScene(at:portrait,onVerticalCanvas:true){StudioLayouts.apply(layout,to:&$0,vertical:true)}
        } else {
            let isVertical=vertical
            editScene {StudioLayouts.apply(layout,to:&$0,vertical:isVertical)}
        }
        save()
    }
    func toggleRecording() {
        syncAudio()
        if engine.recording { engine.stopRecording() }
        else { engine.startRecording(directory:URL(fileURLWithPath:project.recordingFolder),width:outputWidth,height:outputHeight,fps:outputFrameRate,secondaryFPS:vertical ? project.fps : (project.verticalFPS ?? project.fps),preferences:project.mediaPreferences ?? MediaPreferences()) }
    }
    func toggleRecordingPause() {engine.toggleRecordingPause()}
    func toggleStreaming() {
        if youtubeSession.ownsInput || youtubeSession.ownsBroadcast {youtubeSession.endPrivateStream();return}
        syncAudio()
        if engine.streaming { engine.stopStreaming(); return }
        let destinations=project.destinations.filter{$0.enabled}
        guard let d=destinations.first else { showDestinations=true;return }
        if destinations.count>1 { notice="This build supports one active RTMP destination. Disable the others before starting.";return }
        let key=CredentialStore.get(d.id)
        let target=renderConfiguration(onVerticalCanvas:d.vertical)
        engine.startStreaming(url:d.url,key:key,width:target.width,height:target.height,fps:d.vertical ? (project.verticalFPS ?? project.fps) : project.fps,configuration:target,settings:(project.mediaPreferences ?? MediaPreferences()).streaming)
    }
    func chooseRecordingFolder() { let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.canCreateDirectories=true;if p.runModal() == .OK,let u=p.url { project.recordingFolder=u.path;save() } }
    func exportRecordingReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Framecast-recording-report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(engine.recordingStatistics).write(to: url, options: .atomic)
        } catch { notice = "Recording report could not be saved: \(error.localizedDescription)" }
    }
    func revealRecordings() { let u=URL(fileURLWithPath:project.recordingFolder);try? FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);NSWorkspace.shared.open(u) }
    func exportProject() {
        let p=NSSavePanel();p.nameFieldStringValue="\(project.name).vidyststudio";p.allowedContentTypes=[.json];if p.runModal() == .OK, let u=p.url { do { let e=JSONEncoder();e.outputFormatting=[.prettyPrinted];try e.encode(project).write(to:u,options:.atomic) }catch{notice=error.localizedDescription} }
    }
    func importProject() {
        let p=NSOpenPanel();p.allowedContentTypes=[.json,.data];if p.runModal() == .OK,let u=p.url { do { let loaded=try ProjectDocument.decode(Data(contentsOf:u));canvasInteraction.cancel();editUndoManager.removeAllActions();project=loaded;saveAllowed=true;if !loaded.scenes.contains(where:{$0.id==loaded.selectedSceneID}){project.selectedSceneID=loaded.scenes[0].id};selectedSourceID=nil;restoreCanvasSelection();layoutSnapshots=Dictionary(uniqueKeysWithValues:project.scenes.map{($0.id,$0)});syncAudio();refreshComposition();save() }catch{notice="Could not import studio: \(error.localizedDescription)"} }
    }
    func sendChat(_ text:String) { guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return};chat.append(ChatMessage(author:"You",message:text));if chat.count>500{chat.removeFirst(chat.count-500)} }
    private func receiveYouTubeChat(_ messages:[YouTubeLiveChatMessage]) {
        var updateOutput=false
        var indices=Dictionary(uniqueKeysWithValues:chat.enumerated().compactMap { index,item in item.providerMessageID.map{($0,index)} })
        for message in messages {
            if let index=indices[message.id] {
                if chat[index].onScreen && chat[index].message != (message.snippet.displayMessage ?? message.snippet.type) {updateOutput=true}
                chat[index].message=message.snippet.displayMessage ?? message.snippet.type
                chat[index].paid=message.isPaid
            } else {
                indices[message.id]=chat.count
                chat.append(ChatMessage(author:message.authorDetails?.displayName ?? "YouTube",message:message.snippet.displayMessage ?? message.snippet.type,platform:"YouTube",providerMessageID:message.id,paid:message.isPaid,publishedAt:message.snippet.publishedAt))
            }
        }
        if chat.count>500 {updateOutput = updateOutput || chat.prefix(chat.count-500).contains(where:{$0.onScreen});chat.removeFirst(chat.count-500)}
        if updateOutput {refreshComposition()}
    }
    func showMessage(_ id:UUID) { let wasOn=chat.first(where:{$0.id==id})?.onScreen ?? false;for i in chat.indices{chat[i].onScreen=chat[i].id==id && !wasOn};refreshComposition() }
    func startRemote() { do { let server=RemoteServer(model:self);try server.start();remote=server;remoteActive=true;remoteAddress=server.address } catch { notice=error.localizedDescription } }
    func stopRemote() { remote?.stop();remote=nil;remoteActive=false;remoteAddress="" }
    func shutdown() { canvasInteraction.cancel();autosave?.invalidate();autoLayoutTimer?.invalidate();elementTimer?.invalidate();youtubeSession.cancel();google.cancelConnect();save();stopRemote();engine.stopAll() }
}

extension Color {
    init(hex:String) { let clean=hex.trimmingCharacters(in:CharacterSet.alphanumerics.inverted);let value=UInt64(clean,radix:16) ?? 0x1E1B19;self.init(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255) }
}

@MainActor extension StudioModel {
    var elements: [StudioElement] { project.elements ?? [] }
    func editElement(_ id:UUID,_ edit:(inout StudioElement)->Void) {
        guard let index=project.elements?.firstIndex(where:{$0.id==id}) else{return}
        edit(&project.elements![index]);refreshComposition();save()
    }
    func toggleElement(_ id:UUID) {
        guard let element=elements.first(where:{$0.id==id}) else{return}
        editElement(id){$0.visible.toggle()}
        if !element.visible && element.autoHideAfter>0 { elementDeadlines[id]=Date().addingTimeInterval(element.autoHideAfter) }
        else { elementDeadlines.removeValue(forKey:id) }
    }
    func clearElements() { for e in elements where e.visible {editElement(e.id){$0.visible=false}};elementDeadlines.removeAll() }
    func addElement(_ kind:String) {
        let e=StudioElement(name:kind == "qr" ? "New QR code":"New text",title:kind == "qr" ? "Scan for the link":"Your message",subtitle:kind == "qr" ? "https://example.com":"",kind:kind)
        if project.elements==nil{project.elements=[]};project.elements!.append(e);save()
    }
    func removeElement(_ id:UUID) {project.elements?.removeAll{$0.id==id};elementDeadlines.removeValue(forKey:id);refreshComposition();save()}
    private func expireElements() {let expired=elementDeadlines.filter{$0.value<=Date()}.map(\.key);for id in expired{editElement(id){$0.visible=false};elementDeadlines.removeValue(forKey:id)}}
    private func elementLayers()->[RenderLayer] {
        var layers:[RenderLayer]=[]
        for e in elements where e.visible {
            let id=e.id
            if e.kind == "qr" {
                layers.append(RenderLayer(id:id,kind:"color",text:"#FFFFFF",x:0.76,y:0.07,width:0.2,height:0.38))
                layers.append(RenderLayer(id:id,kind:"qr",text:e.subtitle,x:0.78,y:0.09,width:0.16,height:0.29))
                layers.append(RenderLayer(id:id,kind:"text",text:e.title,x:0.52,y:0.39,width:0.44,height:0.08))
            } else if e.kind == "thanks" {
                layers.append(RenderLayer(id:id,kind:"color",text:e.background,x:0.08,y:0.2,width:0.84,height:0.58,cornerRadius:22))
                layers.append(RenderLayer(id:id,kind:"text",text:e.title,x:0.14,y:0.3,width:0.72,height:0.2))
                layers.append(RenderLayer(id:id,kind:"text",text:e.subtitle,x:0.14,y:0.53,width:0.72,height:0.12))
            } else {
                let y=e.kind == "lower" ? 0.79:0.38
                layers.append(RenderLayer(id:id,kind:"color",text:e.background,x:0.035,y:y,width:0.75,height:0.16,cornerRadius:10))
                layers.append(RenderLayer(id:id,kind:"text",text:e.title,x:0.05,y:y+0.008,width:0.71,height:e.subtitle.isEmpty ? 0.14:0.085))
                if !e.subtitle.isEmpty{layers.append(RenderLayer(id:id,kind:"text",text:e.subtitle,x:0.05,y:y+0.087,width:0.71,height:0.065))}
            }
        }
        return layers
    }
}

@MainActor extension StudioModel {
    func resetSelectedLayout() {
        if let name=scene.templateName {let isVertical=vertical;editScene(action:"Reset layout"){StudioLayouts.apply(name,to:&$0,vertical:isVertical)};save();return}
        guard let original=layoutSnapshots[scene.id] else {notice="Reopen this studio to restore its last saved frame.";return}
        let isVertical=vertical
        editScene(action:"Reset layout") {canvas in canvas.sources=isVertical ? (original.verticalSources ?? original.sources):original.sources;canvas.layout=isVertical ? (original.verticalLayout ?? original.layout):original.layout}
        save()
    }
    static func templateScene(_ name:String) -> StudioScene {StudioLayouts.scene(name)}
    func selectTemplate(_ name:String) {
        guard Self.layouts.contains(name) else {return}
        if let existing=project.scenes.first(where:{$0.templateName==name}) {selectScene(existing.id)}
        else {addTemplate(name)}
    }
    func addTemplate(_ name:String) {
        guard Self.layouts.contains(name) else {return}
        let new=Self.templateScene(name)
        project.scenes.append(new)
        selectScene(new.id)
        panel="Edit"
    }
    func importVidystCollection() {
        let p=NSOpenPanel();p.allowedContentTypes=[.json];p.message="Select an exported Vidyst scene collection. Sources remain disabled until you enable capture."
        guard p.runModal() == .OK,let url=p.url else{return}
        do {
            let mapped=try VidystCollectionImport.load(Data(contentsOf:url))
            save()
            if FileManager.default.fileExists(atPath:projectURL.path) {try FileManager.default.copyItem(at:projectURL,to:projectURL.deletingPathExtension().appendingPathExtension("before-import-\(UUID().uuidString).json"))}
            canvasInteraction.cancel();editUndoManager.removeAllActions();project=mapped.project;restoreCanvasSelection();layoutSnapshots=Dictionary(uniqueKeysWithValues:project.scenes.map{($0.id,$0)});selectedSourceID=nil;syncAudio();refreshComposition();save()
            if !mapped.limitations.isEmpty{notice=mapped.limitations.joined(separator:"\n")}
        }catch{notice="Could not import Vidyst collection: \(error.localizedDescription)"}
    }
}
