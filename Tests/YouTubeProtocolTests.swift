import Foundation

struct CheckFailure:Error,LocalizedError {let errorDescription:String?;init(_ text:String){errorDescription=text}}
func require(_ condition:@autoclosure ()->Bool,_ text:String)throws {if !condition(){throw CheckFailure(text)}}
final class ProviderFixture:URLProtocol {
    struct Step {
        let path:String;let method:String;let validate:(URLRequest,[String:String])throws->Void
        let body:String;var status=200;var headers:[String:String]=[:]
    }
    static let lock=NSLock()
    static var steps:[Step]=[]
    static var failure:Error?
    static func enqueue(_ step:Step){lock.lock();steps.append(step);lock.unlock()}
    static func empty()throws {lock.lock();defer{lock.unlock()};if let failure {throw failure};try require(steps.isEmpty,"Expected provider requests were not made")}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            Self.lock.lock();let step=Self.steps.isEmpty ? nil:Self.steps.removeFirst();Self.lock.unlock()
            guard let step else{throw CheckFailure("Unexpected provider request")}
            try require(request.url?.host == "www.googleapis.com","Credential-bearing request left Google host")
            try require(request.url?.path == "/youtube/v3/"+step.path && request.httpMethod==step.method,"Wrong provider resource/method")
            try require(request.value(forHTTPHeaderField:"Authorization")=="Bearer offline-token","Missing bearer header")
            let pairs=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems ?? []
            let query=Dictionary(uniqueKeysWithValues:pairs.map{($0.name,$0.value ?? "")})
            try step.validate(request,query)
            let response=HTTPURLResponse(url:request.url!,statusCode:step.status,httpVersion:"HTTP/1.1",headerFields:step.headers)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:Data(step.body.utf8));client?.urlProtocolDidFinishLoading(self)
        } catch {
            Self.lock.lock();Self.failure=error;Self.lock.unlock()
            client?.urlProtocol(self,didFailWithError:error)
        }
    }
    override func stopLoading() {}
}
func body(_ request:URLRequest)throws->[String:Any] {
    var data=request.httpBody ?? Data()
    if data.isEmpty,let stream=request.httpBodyStream {
        stream.open();defer{stream.close()};var bytes=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {let count=stream.read(&bytes,maxLength:bytes.count);guard count>=0 else{throw CheckFailure("Body stream failed")};if count==0 {break};data.append(contentsOf:bytes.prefix(count))}
    }
    return try JSONSerialization.jsonObject(with:data) as! [String:Any]
}
func broadcast(_ id:String="private-test",privacy:String="private",status:String="ready")->String {
    "{\"id\":\"\(id)\",\"snippet\":{\"title\":\"Test\",\"liveChatId\":\"chat-test\"},\"status\":{\"privacyStatus\":\"\(privacy)\",\"lifeCycleStatus\":\"\(status)\"},\"contentDetails\":{\"boundStreamId\":\"stream-test\",\"monitorStream\":{\"enableMonitorStream\":true}}}"
}
let input = #"{"id":"stream-test","cdn":{"ingestionInfo":{"rtmpsIngestionAddress":"rtmps://a.rtmps.youtube.com/live2","streamName":"offline-key"}},"status":{"streamStatus":"active"}}"#
func message(_ id:String,paid:Bool=false,display:String="Hello")->String {
    "{\"id\":\"\(id)\",\"snippet\":{\"type\":\"\(paid ? "superChatEvent":"textMessageEvent")\",\"liveChatId\":\"chat-test\",\"displayMessage\":\"\(display)\",\"superChatDetails\":{\"amountMicros\":\"1000000\"}},\"authorDetails\":{\"displayName\":\"Fixture\"}}"
}
@main struct ProtocolTests {
    @MainActor static func main()async {
        do {
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ProviderFixture.self]
            let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
            let api=YouTubeLiveController(tokenProvider:{"offline-token"},session:session,sleep:{_ in await Task.yield()})
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,q in
                try require(q["mine"]=="true" && q["broadcastStatus"]==nil,"Incompatible broadcast filters")
            },body:"{\"items\":[\(broadcast()),\(broadcast("ended",status:"complete"))],\"nextPageToken\":\"next-fixture\"}"))
            let page=try await api.listOwnedBroadcasts(filter:.upcoming)
            try require(page.items.count==1 && api.broadcastNextPageToken=="next-fixture","Owned broadcast pagination/filter lost")
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"POST",validate:{r,_ in
                let payload=try body(r);let status=payload["status"] as! [String:Any]
                try require(status["privacyStatus"] as? String=="private" && status["selfDeclaredMadeForKids"] as? Bool==false,"Private creation/audience declaration lost")
            },body:broadcast()))
            _ = try await api.createPrivateBroadcast(title:"Private fixture",scheduledStart:Date(timeIntervalSince1970:2_000_000_000),madeForKids:false)
            ProviderFixture.enqueue(.init(path:"liveStreams",method:"POST",validate:{r,_ in
                let cdn=try body(r)["cdn"] as! [String:String];try require(cdn["resolution"]=="variable" && cdn["frameRate"]=="variable","Variable stream pair lost")
            },body:input))
            let stream=try await api.createStream(title:"Private fixture",resolution:.variable,frameRate:.variable)
            try require(!String(describing:stream).contains("offline-key"),"Ingestion key escaped redacted display")
            ProviderFixture.enqueue(.init(path:"liveBroadcasts/bind",method:"POST",validate:{_,q in
                try require(q["id"]=="private-test" && q["streamId"]=="stream-test","Binding IDs lost")
            },body:broadcast()))
            _ = try await api.bind(broadcastID:"private-test",streamID:"stream-test")
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,_ in},body:"{\"items\":[\(broadcast())]}"))
            ProviderFixture.enqueue(.init(path:"liveStreams",method:"GET",validate:{_,_ in},body:"{\"items\":[\(input)]}"))
            ProviderFixture.enqueue(.init(path:"liveBroadcasts/transition",method:"POST",validate:{_,q in try require(q["broadcastStatus"]=="testing","Monitor stream did not enter testing first")},body:broadcast(status:"testStarting")))
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,_ in},body:"{\"items\":[\(broadcast(status:"testing"))]}"))
            ProviderFixture.enqueue(.init(path:"liveStreams",method:"GET",validate:{_,_ in},body:"{\"items\":[\(input)]}"))
            ProviderFixture.enqueue(.init(path:"liveBroadcasts/transition",method:"POST",validate:{_,q in try require(q["broadcastStatus"]=="live","Missing live transition")},body:broadcast(status:"liveStarting")))
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,_ in},body:"{\"items\":[\(broadcast(status:"live"))]}"))
            _ = try await api.transition(broadcastID:"private-test",to:.live)
            try require(api.broadcasts.first?.status.lifeCycleStatus=="live","Visible broadcast list retained stale lifecycle state")
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,_ in},body:"{\"items\":[\(broadcast("boundary",status:"testing"))]}"))
            ProviderFixture.enqueue(.init(path:"liveStreams",method:"GET",validate:{_,_ in},body:"{\"items\":[\(input)]}"))
            ProviderFixture.enqueue(.init(path:"liveBroadcasts/transition",method:"POST",validate:{_,_ in},body:broadcast("boundary",status:"liveStarting")))
            for index in 0..<30 {
                ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,_ in},body:"{\"items\":[\(broadcast("boundary",status:index==29 ? "live":"liveStarting"))]}"))
            }
            let boundary=try await api.transition(broadcastID:"boundary",to:.live)
            try require(boundary.status.lifeCycleStatus=="live","Last allowed transition observation was lost")
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,_ in},body:"{\"items\":[\(broadcast("public-test",privacy:"public"))]}"))
            do {_ = try await api.transition(broadcastID:"public-test",to:.live);throw CheckFailure("Public transition accepted")}
            catch is CheckFailure {throw CheckFailure("Public transition accepted")} catch YouTubeLiveAPIError.invalidInput {} 
            ProviderFixture.enqueue(.init(path:"liveChat/messages",method:"POST",validate:{r,q in
                let snippet=try body(r)["snippet"] as! [String:Any]
                try require(snippet["liveChatId"] as? String=="chat-test","Chat ID lost")
                try require((snippet["textMessageDetails"] as? [String:String])?["messageText"]=="Hello","Message text lost")
            },body:message("sent")))
            _ = try await api.sendText(liveChatID:"chat-test",text:"Hello")
            var delays:[Double]=[];var poller:YouTubeLiveController!
            poller=YouTubeLiveController(tokenProvider:{"offline-token"},session:session,sleep:{delay in
                delays.append(delay);if delays.count==2 {poller.stopChat()};await Task.yield()
            })
            ProviderFixture.enqueue(.init(path:"liveChat/messages",method:"GET",validate:{_,q in try require(q["pageToken"]==nil,"Unexpected initial cursor")},body:"{\"items\":[\(message("one"))],\"nextPageToken\":\"cursor-two\",\"pollingIntervalMillis\":1500}"))
            ProviderFixture.enqueue(.init(path:"liveChat/messages",method:"GET",validate:{_,q in try require(q["pageToken"]=="cursor-two","Chat cursor lost")},body:"{\"items\":[\(message("one",display:"Updated event")),\(message("paid",paid:true))],\"nextPageToken\":\"cursor-three\",\"pollingIntervalMillis\":2100}"))
            try poller.startChat(liveChatID:"chat-test")
            let deadline=Date().addingTimeInterval(3)
            while delays.count<2 && Date()<deadline {try await Task.sleep(nanoseconds:5_000_000)}
            try require(delays == [1.5,2.1] && poller.messages.count==2 && poller.messages.last?.isPaid==true,"Provider interval/dedup/paid metadata failed")
            try require(poller.messages.first?.snippet.displayMessage=="Updated event","Existing event ID update was discarded")
            try require(poller.messages.last?.snippet.eventDetails["superChatDetails"] != nil,"Paid details discarded")
            poller.clearChat();try require(poller.messages.isEmpty && poller.chatState=="Stopped","Chat cleanup failed")
            ProviderFixture.enqueue(.init(path:"liveBroadcasts",method:"GET",validate:{_,_ in},body:#"{"error":{"message":"never display a raw provider message","errors":[{"reason":"quotaExceeded"}]}}"#,status:403))
            do {_ = try await api.listOwnedBroadcasts();throw CheckFailure("Provider error accepted")}
            catch is CheckFailure {throw CheckFailure("Provider error accepted")}
            catch let error as YouTubeLiveAPIError {try require(error.localizedDescription.contains("quotaExceeded") && !error.localizedDescription.contains("raw provider"),"Provider error boundary lost reason/redaction")}
            try ProviderFixture.empty()
            print("PASS production HTTP request encoding, private audience declaration, owned pagination, input binding, lifecycle preflight/public rejection, chat send/cursors/provider interval/dedup/paid details/cancel, redacted ingestion and provider errors")
            print("Fixture transport only; no Google credentials or live provider delivery tested.")
            print("VERDICT: PASS")
        } catch {print("VERDICT: FAIL -- \(error.localizedDescription)");exit(1)}
    }
}
