import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
private typealias SetupState<Value> = SwiftUI.State<Value>
struct LaunchExperience:View {
    @ObservedObject var model:StudioModel
    let bypassSetup:Bool
    @SetupState private var finished=UserDefaults.standard.bool(forKey:"framecast.setup.v1") || (CGPreflightScreenCaptureAccess() && AVCaptureDevice.authorizationStatus(for:.video) == .authorized && AVCaptureDevice.authorizationStatus(for:.audio) == .authorized)
    @SetupState private var requested=false
    var body:some View {
        Group {
            if (!finished || requested) && !bypassSetup {
                PermissionSetupView(engine: model.engine) {UserDefaults.standard.set(true,forKey:"framecast.setup.v1");finished=true;requested=false}
            } else {StudioView(model:model,allowAutomaticInputs:!bypassSetup)}
        }.onReceive(NotificationCenter.default.publisher(for:Notification.Name("FramecastShowSetup"))){_ in requested=true}
    }
}
private struct PermissionSetupView:View {
    let engine: MediaEngine
    let done:()->Void
    @SetupState private var sessionScreen = false
    @SetupState private var screen=CGPreflightScreenCaptureAccess()
    @SetupState private var camera=AVCaptureDevice.authorizationStatus(for:.video)
    @SetupState private var microphone=AVCaptureDevice.authorizationStatus(for:.audio)
    @SetupState private var busy=false
    func refresh(){
        screen=CGPreflightScreenCaptureAccess()
        camera=AVCaptureDevice.authorizationStatus(for:.video)
        microphone=AVCaptureDevice.authorizationStatus(for:.audio)
    }
    var body:some View {
        HStack(spacing:48) {
            VStack(alignment:.leading,spacing:22) {
                Image(systemName:"rectangle.inset.filled.and.person.filled").font(.system(size:64)).foregroundStyle(StudioPalette.gold)
                Text("Framecast Studio").font(.system(size:32,weight:.bold))
                Text("Your screen.\nYour studio.").font(.system(size:40,weight:.semibold))
                Text("Record a walkthrough, build your scene, or stream privately to YouTube. Set up access before you begin.").foregroundStyle(.secondary)
                Text("Camera and screen capture start when enabled. With microphone access, input meters start when you enter the studio; no recording is saved. Return here from Studio → Permissions & Setup.").font(.callout).foregroundStyle(.secondary)
            }.frame(width:310)
            VStack(alignment:.leading,spacing:20) {
                Text("Set up your permissions").font(.title2.bold())
                row("Screen recording",icon:"display",detail:"Capture your display for recordings and streams.",allowed:screen || sessionScreen,status:screen ? "Allowed":sessionScreen ? "Allowed for current selection":"Not enabled") {refresh();if !screen {if !CGRequestScreenCaptureAccess(){settings("ScreenCapture")}};refresh()}
                row("Microphone",icon:"mic",detail:"Include your voice. Optional for silent recordings.",allowed:microphone == .authorized,status:status(microphone)){request(.audio)}
                row("Camera",icon:"video",detail:"Add your camera to a layout. Optional.",allowed:camera == .authorized,status:status(camera)){request(.video)}
                Text("Permissions belong to Framecast Studio separately from Vidyst. If you already enabled this app in Settings, quit and reopen it so macOS can apply the change.").font(.caption).foregroundStyle(.secondary)
                HStack {Button("Check again",action:refresh);Spacer();Button((screen || sessionScreen) ? "Open studio":"Continue to studio",action:done).buttonStyle(StudioButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)}
            }.frame(maxWidth:460)
        }.padding(48).frame(maxWidth:.infinity,maxHeight:.infinity).background(StudioPalette.base).tint(StudioPalette.gold)
        .onReceive(engine.$screenActive) { sessionScreen = $0 }
        .onAppear(perform:refresh)
        .onReceive(Timer.publish(every:1,on:.main,in:.common).autoconnect()){_ in refresh()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in refresh()}
    }
    func status(_ value:AVAuthorizationStatus)->String {switch value {case .authorized:return "Allowed";case .denied:return "Disabled in Settings";case .restricted:return "Restricted";default:return "Not requested"}}
    func settings(_ pane:String){if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_"+pane){NSWorkspace.shared.open(url)}}
    func request(_ media:AVMediaType){let value=AVCaptureDevice.authorizationStatus(for:media);if value == .authorized {refresh();return};if value == .denied || value == .restricted {settings(media == .video ? "Camera":"Microphone");return};busy=true;Task{_=await AVCaptureDevice.requestAccess(for:media);refresh();busy=false}}
    func row(_ title:String,icon:String,detail:String,allowed:Bool,status:String,action:@escaping()->Void)->some View {
        HStack(alignment:.top,spacing:14){
            Image(systemName:icon).font(.title2).frame(width:30).foregroundStyle(StudioPalette.gold)
            VStack(alignment:.leading,spacing:6){
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    StudioBadge(text: status, icon: allowed ? "checkmark.circle.fill" : "circle", style: allowed ? .success : .default)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            if !allowed {
                Button("Enable", action: action).disabled(busy)
            }
        }
        .padding(18)
        .background(StudioPalette.card)
        .clipShape(RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.cardBorder, lineWidth: 1))
    }
}
