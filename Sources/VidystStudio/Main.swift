import AppKit
import SwiftUI
import AVFoundation

@main enum StudioLauncher {
    @MainActor static var delegate: StudioDelegate?
    @MainActor private static func finishProbe(report: [String: Any]?, error: Error?) -> Never {
        let result: [String: Any] = ["verdict": error == nil ? "PASS" : "FAIL", "report": report ?? [:], "error": error?.localizedDescription ?? ""]
        if let index = CommandLine.arguments.firstIndex(of: "--diagnostic-result"), CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            do {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw NSError(domain: "FramecastDiagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Diagnostic result path already exists."]) }
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .withoutOverwriting)
            } catch { fputs("VERDICT: FAIL -- Diagnostic report: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let error { fputs("VERDICT: FAIL -- \(error.localizedDescription)\n", stderr); exit(1) }
        print("VERDICT: PASS"); exit(0)
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--screen-probe") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    let report = try await ScreenCaptureSession.probePermittedDisplay(includeAudio: CommandLine.arguments.contains("--screen-probe-audio"))
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self)); finishProbe(report: report, error: nil)
                } catch { finishProbe(report: nil, error: error) }
            }
            app.run(); return
        }
        if CommandLine.arguments.contains("--camera-probe") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vidyst Reconstructed/studio.json")
                    let project = try ProjectDocument.decode(Data(contentsOf: path))
                    let report = try await MediaEngine.probePermittedCamera(deviceID: project.cameraDeviceID.isEmpty ? nil : project.cameraDeviceID)
                    finishProbe(report: report, error: nil)
                } catch { finishProbe(report: nil, error: error) }
            }
            app.run(); return
        }
        if CommandLine.arguments.contains("--audio-probe") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vidyst Reconstructed/studio.json")
                    let project = try ProjectDocument.decode(Data(contentsOf: path))
                    let report = try await MediaEngine.probePermittedMicrophone(deviceID: project.microphoneDeviceID.isEmpty ? nil : project.microphoneDeviceID)
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self)); finishProbe(report: report, error: nil)
                } catch { finishProbe(report: nil, error: error) }
            }
            app.run(); return
        }
        if CommandLine.arguments.contains("--self-test") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    try await StudioSelfTest.run()
                    print("VERDICT: PASS")
                    exit(0)
                } catch {
                    fputs("VERDICT: FAIL -- \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            app.run()
            return
        }
        app.setActivationPolicy(.regular)
        let owner = StudioDelegate(); delegate = owner; app.delegate = owner; app.run()
    }
}

@MainActor final class StudioDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var model: StudioModel!
    var pendingQuit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i=CommandLine.arguments.firstIndex(of:"--project"),CommandLine.arguments.indices.contains(i+1) {model=StudioModel(projectURL:URL(fileURLWithPath:CommandLine.arguments[i+1]))} else {model=StudioModel()}
        if let i=CommandLine.arguments.firstIndex(of:"--canvas-mode"),CommandLine.arguments.indices.contains(i+1),["horizontal","vertical","both"].contains(CommandLine.arguments[i+1]) {model.canvasMode=CommandLine.arguments[i+1];if model.canvasMode != "both" {model.vertical=model.canvasMode=="vertical"};model.refreshComposition()}
        if let i=CommandLine.arguments.firstIndex(of:"--panel"),CommandLine.arguments.indices.contains(i+1) {model.panel=CommandLine.arguments[i+1]}
        if CommandLine.arguments.contains("--snapshot"),CommandLine.arguments.contains("--snapshot-select-source"),let source=model.selectedSources.first(where:{$0.kind=="camera" && $0.visible}) ?? model.selectedSources.first(where:{$0.visible}) {model.selectSource(source.id,onVerticalCanvas:model.vertical)}
        let view: AnyView
        if CommandLine.arguments.contains("--snapshot"), let index = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), CommandLine.arguments.indices.contains(index + 1) {
            model.settingsTab = CommandLine.arguments[index + 1]
            view = AnyView(SettingsView(model: model, viewport: CommandLine.arguments.contains("--snapshot-square") ? CGSize(width: 960, height: 960) : nil).preferredColorScheme(.dark))
        } else { view = AnyView(LaunchExperience(model: model, bypassSetup: CommandLine.arguments.contains("--snapshot")).preferredColorScheme(.dark)) }
        let host = NSHostingView(rootView: view)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Framecast Studio"
        window.minSize = NSSize(width:960,height:700)
        window.backgroundColor = NSColor(red:0.118,green:0.106,blue:0.098,alpha:1)
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.delegate = self
        if CommandLine.arguments.contains("--snapshot-square") {window.setContentSize(NSSize(width:960,height:960))}
        window.center()
        if !CommandLine.arguments.contains("--snapshot") { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
        installMenus()
        if !CommandLine.arguments.contains("--snapshot") {model.google.restoreSavedConnection()}
        if let index=CommandLine.arguments.firstIndex(of:"--snapshot"),CommandLine.arguments.indices.contains(index+1) {
            let path=CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { fputs("Snapshot failed\n",stderr);NSApp.terminate(nil);return }
                host.cacheDisplay(in:host.bounds,to:bitmap)
                if let data=bitmap.representation(using:.png,properties:[:]) { do { try data.write(to:URL(fileURLWithPath:path));print("Saved own-window render: \(path)") } catch { fputs("\(error)\n",stderr) } }
                NSApp.terminate(nil)
            }
        }
    }
    private func installMenus() {
        let menu=NSMenu()
        let appItem=NSMenuItem();let appMenu=NSMenu();appItem.submenu=appMenu
        appMenu.addItem(withTitle:"About Framecast Studio",action:#selector(about),keyEquivalent:"").target=self
        appMenu.addItem(withTitle:"Settings…",action:#selector(settings),keyEquivalent:",").target=self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Hide Framecast Studio",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(withTitle:"Quit Framecast Studio",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        menu.addItem(appItem)
        let file=NSMenuItem();let fm=NSMenu(title:"File");file.submenu=fm
        fm.addItem(withTitle:"Import Studio…",action:#selector(importStudio),keyEquivalent:"o").target=self
        fm.addItem(withTitle:"Export Studio…",action:#selector(exportStudio),keyEquivalent:"s").target=self
        fm.addItem(withTitle:"Show Recordings",action:#selector(showRecordings),keyEquivalent:"").target=self
        menu.addItem(file)
        let edit=NSMenuItem();let em=NSMenu(title:"Edit");edit.submenu=em
        em.addItem(withTitle:"Undo",action:Selector(("undo:")),keyEquivalent:"z")
        em.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        em.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        em.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        em.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        menu.addItem(edit)
        let studio=NSMenuItem();let sm=NSMenu(title:"Studio");studio.submenu=sm
        sm.addItem(withTitle:"Permissions & Setup…",action:#selector(permissions),keyEquivalent:"").target=self
        sm.addItem(withTitle:"Start / Stop Recording",action:#selector(record),keyEquivalent:"r").target=self
        sm.addItem(withTitle:"Pause / Resume Recording",action:#selector(pauseRecording),keyEquivalent:"p").target=self
        sm.addItem(withTitle:"Mute / Unmute Microphone",action:#selector(mute),keyEquivalent:"m").target=self
        for (i,layout) in StudioModel.layouts.enumerated() {let item=NSMenuItem(title:layout,action:#selector(layout(_:)),keyEquivalent:String(i+1));item.tag=i;item.target=self;sm.addItem(item)}
        menu.addItem(studio)
        let windowItem=NSMenuItem();let wm=NSMenu(title:"Window");windowItem.submenu=wm
        wm.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"")
        wm.addItem(withTitle:"Zoom",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"")
        menu.addItem(windowItem);NSApp.windowsMenu=wm
        NSApp.mainMenu=menu
    }
    @objc func permissions(){NotificationCenter.default.post(name:Notification.Name("FramecastShowSetup"),object:nil)}
    @objc func settings(){model.showSettings=true}
    @objc func importStudio(){model.importProject()}
    @objc func exportStudio(){model.exportProject()}
    @objc func showRecordings(){model.revealRecordings()}
    @objc func record(){model.toggleRecording()}
    @objc func pauseRecording(){model.toggleRecordingPause()}
    @objc func mute(){model.project.microphoneMuted.toggle();model.engine.microphoneEnabled = !model.project.microphoneMuted;model.save()}
    @objc func layout(_ sender:NSMenuItem){model.applyLayout(StudioModel.layouts[sender.tag])}
    @objc func about(){let alert=NSAlert();alert.messageText=ProductInfo.name;alert.informativeText="Version \(ProductInfo.version) (\(ProductInfo.build))\n\n"+ProductInfo.capabilities+"\n\n"+ProductInfo.limits;alert.runModal()}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard model != nil else {return .terminateNow}
        if pendingQuit {return .terminateLater}
        if model.engine.recording || model.engine.streaming || model.youtubeSession.ownsBroadcast {
            let alert=NSAlert();alert.messageText="Stop outputs and quit?";alert.informativeText="The current recording will finish saving before the app quits.";alert.addButton(withTitle:"Stop and Quit");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else{return .terminateCancel}
        }
        if model.youtubeSession.ownsInput || model.youtubeSession.ownsBroadcast {
            pendingQuit=true
            Task { @MainActor in
                if let error=await model.youtubeSession.finishForQuit() {
                    let alert=NSAlert();alert.messageText="YouTube completion is unconfirmed";alert.informativeText=error
                    alert.addButton(withTitle:"Keep studio open");alert.addButton(withTitle:"Quit")
                    if alert.runModal() == .alertFirstButtonReturn {pendingQuit=false;NSApp.reply(toApplicationShouldTerminate:false);return}
                }
                model.shutdown()
                while model.engine.isFinalizingRecording || model.engine.screenCaptureBusy {try? await Task.sleep(nanoseconds:100_000_000)}
                NSApp.reply(toApplicationShouldTerminate:true)
            }
            return .terminateLater
        }
        model.shutdown()
        if model.engine.isFinalizingRecording || model.engine.screenCaptureBusy {
            Task { @MainActor in
                while model.engine.isFinalizingRecording || model.engine.screenCaptureBusy {try? await Task.sleep(nanoseconds:100_000_000)}
                NSApp.reply(toApplicationShouldTerminate:true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func windowWillReturnUndoManager(_ window:NSWindow)->UndoManager? {model?.editUndoManager}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}

struct TestFailure: LocalizedError {
    var message:String
    var errorDescription:String? {message}
}
@MainActor enum StudioSelfTest {
    static func require(_ value: @autoclosure ()->Bool,_ message:String) throws {if !value(){throw TestFailure(message:message)}}
    static func layoutChecks(root:URL) throws {
        // A stored v1 preset: distinguish an untouched default from user edits.
        var old=StudioScene(name:"My screen layout",sources:[StudioSource(name:"Screen",kind:"screen"),StudioSource(name:"Camera",kind:"camera",x:0.74,y:0.67,width:0.22,height:0.28,cornerRadius:500)],templateName:"Screen + cam")
        old.verticalSources=old.sources
        var interim=StudioLayouts.scene("Screen + cam");interim.sources[1].cornerRadius=154
        try require(StudioLayouts.upgradedLegacy(interim)?.sources[1].cornerRadius==500,"Early preview circle mask did not upgrade")
        interim.sources[1].x=0.6
        try require(StudioLayouts.upgradedLegacy(interim)==nil,"Early preview migration changed custom framing")
        var custom=old;custom.id=UUID();custom.name="My custom framing";custom.sources[1].x=0.6
        try require(StudioLayouts.upgradedLegacy(custom)==nil,"Customized legacy layout was overwritten")
        var project=StudioProject();project.scenes=[old,custom];project.selectedSceneID=old.id;project.selectedVerticalSceneID=old.id;project.microphoneMuted=true
        let path=root.appendingPathComponent("legacy-layouts.json")
        let original=try JSONEncoder().encode(project);try original.write(to:path)
        let m=StudioModel(projectURL:path);defer{m.shutdown()}
        let upgraded=m.project.scenes[0]
        try require(upgraded.id==old.id && upgraded.sources.map(\.id)==old.sources.map(\.id) && upgraded.verticalSources!.map(\.id)==old.verticalSources!.map(\.id),"Layout upgrade changed identities")
        try require(upgraded.name==old.name && m.project.scenes[1]==custom,"Layout upgrade lost user data")
        try require(upgraded.sources[0].fit=="fit" && upgraded.verticalSources![0].height<0.4,"Legacy template did not upgrade")
        try require(StudioLayouts.upgradedLegacy(upgraded)==nil,"Layout migration was not idempotent")
        let backups=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("legacy-layouts.before-layout-upgrade-")}
        try require(backups.count==1,"Layout upgrade did not make one backup")
        let backupData=try Data(contentsOf:backups[0]);try require(backupData==original,"Layout upgrade backup changed")
        m.canvasMode="both";m.linkedLayouts=false;m.vertical=true;m.selectScene(custom.id)
        try require(m.project.selectedSceneID==old.id && m.project.selectedVerticalSceneID==custom.id,"Unlinked selection changed other canvas")
        m.linkedLayouts=true
        try require(m.project.selectedSceneID==custom.id && m.project.selectedVerticalSceneID==custom.id,"Enabling linked selection did not align canvases")
        m.applyLayout("Side by side")
        try require(m.scene.sources[0].width>0.6 && m.scene.verticalSources![0].height==0.30,"Linked menu layout did not adapt both canvases")
        m.vertical=false;m.selectedSourceID=m.scene.sources[1].id
        m.setSourceShape("Circle")
        let circle=m.source!;let portrait=m.scene.verticalSources!
        try require(abs(circle.width*Double(m.outputWidth)-circle.height*Double(m.outputHeight))<0.01,"Circle conversion distorted frame")
        _ = m.canvasInteraction.begin(sourceID:circle.id,vertical:false,action:"Resize source")
        let frame=CanvasGeometry.resized(CanvasFrame(circle),handle:.bottomRight,dx:0.05*Double(m.outputWidth),dy:0,canvas:m.canvasSize(vertical:false),aspectLocked:true)
        m.canvasInteraction.update(frame);m.canvasInteraction.commit()
        let resized=m.source!
        try require(resized.width>circle.width && abs(resized.width*Double(m.outputWidth)-resized.height*Double(m.outputHeight))<0.01,"Resizing distorted circle")
        try require(m.scene.verticalSources==portrait,"Horizontal resizing changed portrait geometry")
        let before=m.scene
        m.setSourceFrame(resized.id,onVerticalCanvas:false,x:.nan,y:0,width:1,height:1)
        m.setSourceFrame(UUID(),onVerticalCanvas:false,x:0,y:0,width:1,height:1)
        try require(m.scene==before,"Invalid frame edit mutated scene")
        m.setSourceShape("Rectangle")
        m.setSourceFrame(resized.id,onVerticalCanvas:false,x:-10,y:10,width:0,height:9)
        try require(m.source?.x == -0.95 && m.source?.y==0.98 && m.source?.width==0.02 && m.source?.height==2,"Interactive frame bounds failed")
        m.save()
        let reopened=StudioModel(projectURL:path);defer{reopened.shutdown()}
        try require(reopened.project.scenes==m.project.scenes,"Edited layouts failed persistence round trip")
        let afterBackups=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("legacy-layouts.before-layout-upgrade-")}
        try require(afterBackups.count==1,"Reopen repeated layout migration")
        let messages=[ChatMessage(author:"A",message:"Regular",paid:false),ChatMessage(author:"B",message:"Paid",paid:true),ChatMessage(author:"C",message:"Local")]
        try require(messages.filter(ChatFilter.all.includes).count==3 && messages.filter(ChatFilter.paid.includes).map(\.message)==["Paid"] && messages.filter(ChatFilter.messages.includes).map(\.message)==["Regular","Local"],"Chat category filters misclassified messages")
        print("PASS legacy layout backup, custom preservation and idempotence; linked/unlinked canvas selection, circle conversion/resizing, isolated frame edits and persistence; chat filters")
    }
    static func run() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vidyst-reconstructed-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try layoutChecks(root:root)
        let m=StudioModel(projectURL:root.appendingPathComponent("studio.json"))
        m.engine.microphoneEnabled=false
        m.project.width=640;m.project.height=360
        try PrompterController.runSelfTest()
        print("PASS prompter parsing, markers, countdown/pause/resume/end")
        try GoogleYouTubeController.runSelfTest()
        try await GoogleYouTubeController.runLoopbackSelfTest()
        print("PASS Google desktop config, PKCE and actual loopback callback/cancel/timeout (offline)")
        for name in StudioModel.layouts {
            let template=StudioModel.templateScene(name)
            try require(template.sources.contains(where:{$0.kind=="screen"}) && template.sources.contains(where:{$0.kind=="camera"}),"Template sources missing")
            try require(template.verticalSources?.count==template.sources.count,"Vertical template missing")
        }
        try require(StudioModel.templateScene("Screen focus").sources.first(where:{$0.kind=="camera"})?.visible==false,"Screen template camera should be hidden")
        print("PASS all nine templates have independent usable canvas sources")
        let circle=StudioModel.templateScene("Screen + cam").sources.first{$0.kind=="camera"}!
        try require(abs(circle.width*1920-circle.height*1080)<0.01,"Camera circle is distorted")
        try require(circle.cornerRadius>=circle.width*3840/2,"Template circle mask fails at 4K output")
        let portrait=StudioModel.templateScene("Screen + cam").verticalSources!.first{$0.kind=="screen"}!
        try require(portrait.fit=="fit" && portrait.height<0.4,"Portrait screen should preserve entire desktop")
        let savedSelection=m.scene.id
        m.canvasMode="both"
        m.selectTemplate("Screen focus")
        try require(m.project.selectedSceneID==m.project.selectedVerticalSceneID,"Linked layout did not update both canvases")
        let templateID=m.scene.id
        let count=m.project.scenes.count
        m.selectTemplate("Screen focus")
        try require(m.scene.id==templateID && m.project.scenes.count==count,"Selecting a built-in template duplicated it")
        m.project.scenes.removeAll{$0.id==templateID};m.selectScene(savedSelection);m.canvasMode="horizontal"
        print("PASS built-in selection reuses editable layout without duplication")
        let first=m.scene.id
        m.addScene();try require(m.project.scenes.count==2,"Adding scene failed")
        m.addSource("text");m.editSource{$0.text="Integration test";$0.x=0.1;$0.y=0.2}
        let sourceID=m.selectedSourceID
        try require(m.scene.verticalSources?.isEmpty==true,"Adding a horizontal layer changed the vertical canvas")
        // Exercise migration of a legacy shared composition in both directions.
        m.project.scenes[m.sceneIndex].verticalSources=nil
        m.editSource{$0.x=0.15}
        try require(m.scene.verticalSources?.first?.x==0.1,"First horizontal edit changed legacy vertical geometry")
        let horizontalX=m.source!.x
        m.vertical=true;m.selectScene(m.project.selectedSceneID!);m.selectedSourceID=sourceID;m.editSource{$0.x=0.8}
        try require(m.source?.x==0.8 && m.scene.sources.first?.x==horizontalX,"Canvas edits leaked across geometry")
        m.vertical=false;m.refreshComposition()
        print("PASS independent horizontal/vertical geometry")
        m.duplicateScene();try require(m.project.scenes.count==3,"Duplicating scene failed")
        try require(m.scene.sources.first?.id != sourceID,"Duplicate source retained original identity")
        m.applyLayout("Side by side inverted");m.save()
        let data=try Data(contentsOf:m.projectURL);let loaded=try JSONDecoder().decode(StudioProject.self,from:data)
        try require(loaded.scenes.count==3 && loaded.scenes.last?.layout=="Side by side inverted","Persistence round trip failed")
        try require(!String(decoding:data,as:UTF8.self).contains("streamKey"),"Stream credential serialized in project")
        m.selectScene(first);m.removeScene();try require(m.project.scenes.count==2,"Removing scene failed")
        m.sendChat("Hello studio");m.showMessage(m.chat[0].id);try require(m.chat[0].onScreen,"Chat overlay toggle failed")
        print("PASS scene/source identity, scene lifecycle, layouts, chat overlay, persistence")
        var invalid=m.project;invalid.width=Int.max
        do { _=try ProjectDocument.decode(JSONEncoder().encode(invalid));throw TestFailure(message:"Invalid dimensions accepted") }
        catch is TestFailure { throw TestFailure(message:"Invalid dimensions accepted") } catch { }
        let brokenURL=root.appendingPathComponent("broken.json")
        let malformed=Data("{broken".utf8);try malformed.write(to:brokenURL)
        let recovered=StudioModel(projectURL:brokenURL);recovered.engine.microphoneEnabled=false
        let backups=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("broken.unreadable-")}
        try require(backups.count==1,"Unreadable studio not backed up")
        let preserved=try Data(contentsOf:backups[0])
        try require(preserved == malformed,"Unreadable original changed during recovery")
        recovered.shutdown()
        print("PASS invalid document rejection and unreadable document preservation")
        try require(m.elements.count==6,"Default elements missing")
        let overlay=m.elements[0].id
        m.editElement(overlay){$0.autoHideAfter=0.1}
        m.toggleElement(overlay)
        try require(m.elements[0].visible,"Element did not become visible")
        try await Task.sleep(nanoseconds:400_000_000)
        try require(!m.elements[0].visible,"Element auto-hide did not fire")
        m.addElement("qr");try require(m.elements.last?.kind=="qr","QR element creation failed")
        m.toggleElement(m.elements.last!.id);m.clearElements()
        try require(!m.elements.contains(where:{$0.visible}),"Clearing elements failed")
        print("PASS element creation, visibility, auto-hide, QR configuration, clear-all")


        m.refreshComposition()
        m.engine.startRecording(directory:root,width:640,height:360,fps:30)
        try require(m.engine.recording,"Recording did not start: \(m.engine.errorMessage ?? "unknown")")
        try await Task.sleep(nanoseconds:1_500_000_000)
        m.engine.stopRecording()
        let deadline=Date().addingTimeInterval(10)
        while m.engine.isFinalizingRecording && Date()<deadline {try await Task.sleep(nanoseconds:50_000_000)}
        try require(!m.engine.isFinalizingRecording,"Recording finalization timed out")
        guard let url=m.engine.recordingURL else{throw TestFailure(message:"No recorded file URL")}
        let asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.video)
        let duration=try await asset.load(.duration)
        try require(!tracks.isEmpty && duration.seconds>0.5,"Recorded asset has no usable video")
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
        let (image,_)=try await generator.image(at:CMTime(seconds:0.4,preferredTimescale:600))
        try require(image.width==640 && image.height==360,"Encoded dimensions incorrect")
        print("PASS H264 MP4 finalization, video track, duration=\(duration.seconds), decoded frame=\(image.width)x\(image.height)")
        m.startRemote();try require(m.remoteActive,"Remote listener did not start")
        let readyDeadline=Date().addingTimeInterval(5)
        while !m.remoteAddress.hasPrefix("http://") && Date()<readyDeadline { try await Task.sleep(nanoseconds:50_000_000) }
        guard let url=URL(string:m.remoteAddress) else{throw TestFailure(message:"Invalid remote address")}
        let (_,response)=try await URLSession.shared.data(from:url)
        try require((response as? HTTPURLResponse)?.statusCode==200,"Remote dashboard request failed")
        print("PASS actual loopback HTTP dashboard")
        m.shutdown()
        print("Test artifacts: \(root.path)")
    }
}
