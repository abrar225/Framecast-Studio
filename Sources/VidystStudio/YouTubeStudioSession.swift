import Foundation
import Combine

/// Owns the relationship between an explicitly selected private broadcast and
/// this studio's encoder. Provider lifecycle is distinct from local encoder state.
@MainActor final class YouTubeStudioSession:ObservableObject {
    @Published private(set) var selected:YouTubeLiveBroadcast?
    @Published private(set) var busy=false
    @Published private(set) var activity=""
    @Published private(set) var errorMessage:String?
    @Published private(set) var ownsInput=false
    @Published private(set) var ownsBroadcast=false
    private weak var model:StudioModel?
    private let api:YouTubeLiveController
    private var stream:YouTubeLiveStream?
    private var operation:Task<Void,Never>?
    private var generation=UUID()
    init(model:StudioModel,api:YouTubeLiveController) {self.model=model;self.api=api}
    var privateSelection:Bool {selected?.status.privacyStatus == "private"}
    var canChat:Bool {privateSelection && selected?.snippet.liveChatId != nil && selected?.status.lifeCycleStatus == "live"}
    func refreshBroadcasts() {run("Loading broadcasts") { _ = try await self.api.listOwnedBroadcasts() }}
    func loadMoreBroadcasts() {
        guard let cursor=api.broadcastNextPageToken else{return}
        run("Loading more broadcasts") {_ = try await self.api.listOwnedBroadcasts(pageToken:cursor)}
    }
    func select(_ id:String) {
        guard !ownsInput && !ownsBroadcast else{errorMessage="End this studio's YouTube stream before selecting another broadcast.";return}
        run("Loading broadcast") {
            let broadcast=try await self.api.broadcast(id:id)
            self.api.clearChat();self.selected=broadcast;self.stream=nil
            if let streamID=broadcast.contentDetails?.boundStreamId {self.stream=try await self.api.stream(id:streamID)}
        }
    }
    func createPrivate(title:String,madeForKids:Bool) {
        guard !ownsInput && !ownsBroadcast else{return}
        run("Creating private broadcast") {
            let broadcast=try await self.api.createPrivateBroadcast(title:title,scheduledStart:Date().addingTimeInterval(60),madeForKids:madeForKids)
            // Retain the new resource immediately, even if a later stage fails.
            self.api.clearChat();self.selected=broadcast;self.stream=nil
            let stream=try await self.api.createStream(title:title,resolution:.variable,frameRate:.variable)
            self.stream=stream
            self.selected=try await self.api.bind(broadcastID:broadcast.id,streamID:stream.id)
            _ = try await self.api.listOwnedBroadcasts()
        }
    }
    func startInput() {
        guard !busy,let model,privateSelection,let selected,selected.status.lifeCycleStatus != "complete" else{return}
        guard !model.engine.streaming else{errorMessage="An encoder is already running. Stop that output first.";return}
        guard let info=stream?.cdn?.ingestionInfo,let address=info.rtmpsIngestionAddress ?? info.ingestionAddress,let key=info.streamName,!key.isEmpty else {errorMessage="This private broadcast has no bound RTMP input. Create a new private test broadcast.";return}
        model.syncAudio()
        model.engine.startStreaming(url:address,key:key,width:model.outputWidth,height:model.outputHeight,fps:model.outputFrameRate,configuration:model.renderConfiguration(onVerticalCanvas:model.vertical),settings:(model.project.mediaPreferences ?? MediaPreferences()).streaming)
        ownsInput=model.engine.streaming
        if ownsInput {activity="Encoder started. Refresh status until YouTube detects input.";errorMessage=nil}
        else {errorMessage=model.engine.errorMessage ?? "The local encoder did not start."}
    }
    func refreshStatus() {
        guard let id=selected?.id else{return}
        run("Checking YouTube input") {
            let value=try await self.api.broadcast(id:id);self.selected=value
            if let input=value.contentDetails?.boundStreamId {self.stream=try await self.api.stream(id:input)}
            self.activity="Broadcast: \(value.status.lifeCycleStatus ?? "unknown") · Input: \(self.stream?.status?.streamStatus ?? "unknown")"
        }
    }
    func goLivePrivately() {
        guard ownsInput,privateSelection,let id=selected?.id else{return}
        run("Starting private broadcast") {
            // A request may reach Google even if its response is lost. Retain
            // broadcast ownership until completion or a fresh inactive status.
            self.ownsBroadcast=true
            self.selected=try await self.api.transition(broadcastID:id,to:.live)
            if let chatID=self.selected?.snippet.liveChatId {try self.api.startChat(liveChatID:chatID)}
        }
    }
    func endPrivateStream() {
        guard privateSelection,let id=selected?.id else{return}
        run("Ending private broadcast") {
            defer {if self.ownsInput {self.model?.engine.stopStreaming();self.ownsInput=false};self.api.stopChat()}
            self.selected=try await self.api.transition(broadcastID:id,to:.complete)
            self.ownsBroadcast=false
            self.activity="Private broadcast ended. Local recording continues if enabled."
        }
    }
    func finishForQuit()async->String? {
        cancel()
        defer {if ownsInput {model?.engine.stopStreaming();ownsInput=false}}
        guard ownsBroadcast,privateSelection,let id=selected?.id else{return nil}
        do {
            let current=try await api.broadcast(id:id);selected=current
            if ["created","ready","complete","revoked"].contains(current.status.lifeCycleStatus ?? "") {ownsBroadcast=false;return nil}
            selected=try await api.transition(broadcastID:id,to:.complete);ownsBroadcast=false;return nil
        } catch {
            errorMessage="The encoder has stopped, but YouTube broadcast completion could not be confirmed. Refresh its status and end it in YouTube if needed."
            return errorMessage
        }
    }
    func startChat() {
        guard canChat,let id=selected?.snippet.liveChatId else{return}
        do {try api.startChat(liveChatID:id);errorMessage=nil} catch {errorMessage=safe(error)}
    }
    func sendChat(_ text:String,onSuccess:@escaping ()->Void) {
        guard canChat,let id=selected?.snippet.liveChatId else {errorMessage="Select a private broadcast with an available live chat.";return}
        run("Sending YouTube message") {_ = try await self.api.sendText(liveChatID:id,text:text);onSuccess()}
    }
    func cancel() {generation=UUID();operation?.cancel();operation=nil;busy=false;api.stopChat()}
    private func run(_ label:String,_ work:@escaping @MainActor ()async throws->Void) {
        guard !busy else{return};busy=true;errorMessage=nil;activity=label
        let current=UUID();generation=current
        operation=Task { [weak self] in
            guard let self else{return}
            do {try await work();if self.generation==current && self.activity==label {self.activity=""}}
            catch is CancellationError {}
            catch {if self.generation==current {self.errorMessage=self.safe(error)}}
            if self.generation==current {self.busy=false;self.operation=nil}
        }
    }
    private func safe(_ error:Error)->String {
        (error as? YouTubeLiveAPIError)?.localizedDescription ?? "YouTube request could not be completed. Reconnect the account or try again."
    }
}
