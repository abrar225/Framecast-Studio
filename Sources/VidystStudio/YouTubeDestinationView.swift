import SwiftUI
import AppKit
import UniformTypeIdentifiers
private typealias YouTubeViewState<Value> = SwiftUI.State<Value>

struct DestinationsView:View {
    @ObservedObject var model:StudioModel
    @YouTubeViewState<Bool> private var showCustom=false
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Image(systemName:"rectangle.inset.filled.and.person.filled").frame(width:66,height:24).background(Color(hex:"#7762DA")).clipShape(Capsule())
                Button {model.showDestinations=false} label:{Label("Studio",systemImage:"chevron.left").font(.system(size:12,weight:.semibold))}
                    .buttonStyle(StudioButtonStyle()).tint(Color(hex:"#F5C849"))
                Spacer()
            }.padding(.horizontal,16).frame(height:54).background(Color(hex:"#1C1B18"))
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Destinations").font(.system(size:28,weight:.bold))
                        Text("Where your stream goes when you start streaming.").font(.system(size:14)).foregroundStyle(Color(hex:"#938E84"))
                    }.padding(.bottom,2)
                    YouTubeDestinationView(model:model,google:model.google,api:model.youtube,session:model.youtubeSession)
                        .padding(24).background(Color(hex:"#211F1B")).clipShape(RoundedRectangle(cornerRadius:16))
                        .overlay(RoundedRectangle(cornerRadius:16).stroke(Color(hex:"#34312B")))
                    HStack(spacing:16) {
                        Text("RTMP").font(.system(size:10,weight:.bold)).frame(width:44,height:44).background(Color(hex:"#34312B")).clipShape(RoundedRectangle(cornerRadius:12))
                        VStack(alignment:.leading,spacing:4) {
                            Text("Custom RTMP").font(.system(size:16,weight:.semibold))
                            Text("Stream to a service with a server URL and stream key.").font(.system(size:12)).foregroundStyle(Color(hex:"#938E84"))
                        }
                        Spacer()
                        Button("Add server") {showCustom=true}.buttonStyle(StudioButtonStyle())
                    }.padding(18).background(Color(hex:"#211F1B")).clipShape(RoundedRectangle(cornerRadius:16))
                        .overlay(RoundedRectangle(cornerRadius:16).stroke(Color(hex:"#34312B")))
                    Text("Google and YouTube integrations are the current implementation scope.").font(.caption).foregroundStyle(Color(hex:"#938E84")).frame(maxWidth:.infinity)
                }.frame(maxWidth:760).padding(.horizontal,32).padding(.vertical,54).frame(maxWidth:.infinity)
            }
        }.background(Color(hex:"#181714")).foregroundStyle(Color(hex:"#EEECE7")).tint(Color(hex:"#F5C849"))
        .sheet(isPresented:$showCustom){CustomDestinationsView(model:model)}
    }
}

struct YouTubeDestinationView:View {
    @ObservedObject var model:StudioModel
    @ObservedObject var google:GoogleYouTubeController
    @ObservedObject var api:YouTubeLiveController
    @ObservedObject var session:YouTubeStudioSession
    @YouTubeViewState<String> private var title="Private studio test"
    @YouTubeViewState<Bool> private var madeForKids=false
    @YouTubeViewState<String?> private var importError=nil
    @YouTubeViewState<Bool> private var confirmLive=false
    @YouTubeViewState<Bool> private var confirmEnd=false
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if !google.isConnected && google.connectionState != .refreshing {
                    VStack(spacing:18) {
                        Image(systemName:"play.fill").font(.system(size:26)).foregroundStyle(.white).frame(width:64,height:64).background(Color(hex:"#FF2537")).clipShape(RoundedRectangle(cornerRadius:18))
                        Text("Connect your YouTube channel").font(.system(size:24,weight:.bold))
                        Text("Sign in with Google to go live and see your chat here.\nYour password stays with Google.").font(.system(size:14)).foregroundStyle(Color(hex:"#A9A296")).multilineTextAlignment(.center)
                        if google.connectionState == .connecting {
                            ProgressView("Waiting for Google sign-in…").controlSize(.small)
                            Button("Cancel",action:google.cancelConnect)
                        } else {
                            Button(action:google.clientConfigured ? google.connect:importClient) {
                                Text(google.clientConfigured ? "Connect YouTube":"Set up Google client").font(.system(size:15,weight:.bold)).foregroundStyle(Color(hex:"#141310")).frame(width:190,height:46).background(Color(hex:"#F5C849")).clipShape(RoundedRectangle(cornerRadius:13))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical,24).frame(maxWidth:.infinity)
                } else {
                HStack(alignment:.top) {
                    Image(systemName:"play.rectangle.fill").font(.system(size:26)).foregroundStyle(.red)
                    VStack(alignment:.leading,spacing:5) {
                        Text(google.channel?.title ?? "YouTube").font(.headline)
                        Text(google.channel?.customURL ?? connectionLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if google.connectionState == .connecting || google.connectionState == .refreshing {
                        ProgressView().controlSize(.small)
                        Button("Cancel",action:google.cancelConnect)
                    } else if google.isConnected {
                        Button("Refresh channel",action:google.refreshChannel)
                        Button("Disconnect") {session.cancel();api.clearChat();google.disconnect()}.disabled(session.ownsInput || session.ownsBroadcast)
                    } else {Button("Connect YouTube",action:google.connect).disabled(!google.clientConfigured)}
                }
                }
                DisclosureGroup("Developer configuration") {
                    VStack(alignment:.leading,spacing:8) {
                        Text(google.clientConfigured ? "Desktop OAuth client configured on this Mac." : "Import the Desktop OAuth client JSON downloaded from your Google Cloud project.").font(.caption).foregroundStyle(.secondary)
                        Button("Import Google client JSON…",action:importClient).disabled(google.connectionState == .connecting || session.ownsInput || session.ownsBroadcast)
                    }.padding(.top,8)
                }.font(.caption)
                if let error=google.errorMessage ?? importError {Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
                Divider()
                if google.isConnected {
                    HStack {
                        Text("Your broadcasts").font(.headline)
                        Spacer()
                        Button("Refresh",action:session.refreshBroadcasts).disabled(session.busy)
                    }
                    if api.broadcasts.isEmpty {Text("Refresh to load broadcasts from your channel.").font(.caption).foregroundStyle(.secondary)}
                    ForEach(api.broadcasts) {broadcast in
                        Button {session.select(broadcast.id)} label: {
                            HStack {
                                Image(systemName:session.selected?.id == broadcast.id ? "checkmark.circle.fill":"circle")
                                VStack(alignment:.leading,spacing:3) {
                                    Text(broadcast.snippet.title).lineLimit(1)
                                    Text("\(broadcast.status.privacyStatus ?? "unknown") · \(broadcast.status.lifeCycleStatus ?? "unknown")").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(9).background(Color.white.opacity(session.selected?.id == broadcast.id ? 0.08:0.025)).clipShape(RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(.plain).disabled(session.busy || session.ownsInput || session.ownsBroadcast)
                    }
                    if api.broadcastNextPageToken != nil {Button("More broadcasts…",action:session.loadMoreBroadcasts).disabled(session.busy)}
                    DisclosureGroup("Create a private test broadcast") {
                        VStack(alignment:.leading,spacing:10) {
                            TextField("Broadcast title",text:$title).textFieldStyle(StudioTextFieldStyle())
                            Toggle("This broadcast is made for kids",isOn:$madeForKids)
                            Text("Private visibility. YouTube disables chat for content made for kids.").font(.caption).foregroundStyle(.secondary)
                            Button("Create private broadcast") {session.createPrivate(title:title,madeForKids:madeForKids)}
                                .disabled(session.busy || session.ownsInput || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        }.padding(.top,8)
                    }
                    if let selected=session.selected {
                        Divider()
                        HStack {
                            VStack(alignment:.leading,spacing:5) {
                                Text(selected.snippet.title).font(.headline)
                                Text("\(selected.status.privacyStatus ?? "unknown") · \(selected.status.lifeCycleStatus ?? "unknown")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url=URL(string:"https://www.youtube.com/watch?v=\(selected.id)") {Link("Open on YouTube",destination:url).font(.caption)}
                        }
                        if session.privateSelection {
                            HStack {
                                Button("Start encoder",action:session.startInput).disabled(session.busy || session.ownsInput || model.engine.streaming || selected.status.lifeCycleStatus == "complete")
                                Button("Refresh status",action:session.refreshStatus).disabled(session.busy)
                                Button("Go live privately") {confirmLive=true}.disabled(session.busy || !session.ownsInput || selected.status.lifeCycleStatus == "live")
                                Button("End broadcast") {confirmEnd=true}.disabled(session.busy || selected.status.lifeCycleStatus == "complete")
                            }
                            HStack {
                                Button("Connect live chat",action:session.startChat).disabled(!session.canChat)
                                Button("Stop chat",action:api.stopChat)
                                Text(api.chatState).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {Text("This pass supports private tests. Select a private broadcast to start output or chat.").font(.caption).foregroundStyle(.secondary)}
                    }
                }
                if session.busy {ProgressView(session.activity).controlSize(.small)}
                else if !session.activity.isEmpty {Text(session.activity).font(.caption).foregroundStyle(.secondary)}
                if let error=session.errorMessage ?? api.chatError {Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
            }.padding(.vertical,4)
        }.frame(minHeight:google.isConnected ? 400:325,maxHeight:google.isConnected ? 560:390)
        .confirmationDialog("Start this private YouTube broadcast?",isPresented:$confirmLive) {
            Button("Go live privately",action:session.goLivePrivately)
        } message:{Text("The selected canvas and enabled audio will be sent to the selected private YouTube broadcast.")}
        .confirmationDialog("End this private YouTube broadcast?",isPresented:$confirmEnd) {
            Button("End broadcast",role:.destructive,action:session.endPrivateStream)
        } message:{Text("This ends the broadcast and stops its encoder. Local recording continues if enabled.")}
    }
    private var connectionLabel:String {
        switch google.connectionState {
        case .notConfigured:return "Client setup required"
        case .disconnected:return "Not connected"
        case .connecting:return "Waiting for Google sign-in"
        case .connected:return "Connected"
        case .refreshing:return "Checking channel"
        case .disconnecting:return "Disconnecting"
        }
    }
    private func importClient() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try google.configureClient(from:url);importError=nil}
        catch {importError="Could not import a Google Desktop OAuth client. Choose the original downloaded JSON file."}
    }
}

struct StudioChatComposer:View {
    @ObservedObject var model:StudioModel
    @ObservedObject var session:YouTubeStudioSession
    @YouTubeViewState<String> private var destination="Local"
    @YouTubeViewState<String> private var message=""
    var body:some View {
        VStack(spacing:8) {
            Picker("Send as",selection:$destination) {
                Text("Local overlay").tag("Local")
                Text("YouTube channel").tag("YouTube")
            }.pickerStyle(.menu).font(.caption)
            HStack(spacing:8) {
                TextField(destination == "YouTube" ? "Send to selected YouTube chat…":"Add a local message to pin…",text:$message)
                    .textFieldStyle(StudioTextFieldStyle()).font(.system(size:12)).onSubmit(send)
                Button(action:send) {Image(systemName:"arrow.up").font(.system(size:15,weight:.bold)).frame(width:30,height:30)}
                    .disabled(message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (destination == "YouTube" && (!session.canChat || session.busy)))
                    .help(destination == "YouTube" ? "Send message to YouTube":"Add local overlay message")
            }
        }.padding(12)
    }
    private func send() {
        guard !message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        if destination == "YouTube" {session.sendChat(message){message=""}}
        else {model.sendChat(message);message=""}
    }
}
struct YouTubeChatStatus:View {
    @ObservedObject var api:YouTubeLiveController
    var body:some View {
        Text(api.chatError ?? "YouTube chat · \(api.chatState)").font(.system(size:9)).foregroundStyle(api.chatError == nil ? Color.secondary:Color.orange).padding(.bottom,8)
    }
}
