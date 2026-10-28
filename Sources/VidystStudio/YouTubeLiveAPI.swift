import Foundation
import Combine

// Official contracts: https://developers.google.com/youtube/data/live/reference/rest
// No requests run at initialization. Credentials and ingestion information are memory-only.
struct YouTubeLiveBroadcast: Decodable, Identifiable {
    struct Snippet: Decodable { let title: String; let scheduledStartTime: String?; let liveChatId: String?; let channelId: String? }
    struct Status: Decodable { let lifeCycleStatus: String?; let privacyStatus: String?; let selfDeclaredMadeForKids: Bool? }
    struct ContentDetails: Decodable {
        struct MonitorStream: Decodable { let enableMonitorStream: Bool? }
        let boundStreamId: String?; let monitorStream: MonitorStream?
    }
    let id: String; let snippet: Snippet; let status: Status; let contentDetails: ContentDetails?
}
struct YouTubeLivePage<Item: Decodable>: Decodable { let items: [Item]; let nextPageToken: String? }
struct YouTubeLiveStream: Decodable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    struct CDN: Decodable {
        struct Ingestion: Decodable, CustomStringConvertible, CustomDebugStringConvertible {
            let ingestionAddress: String?; let rtmpsIngestionAddress: String?; let streamName: String?
            var description: String { "YouTube ingestion details [redacted]" }
            var debugDescription: String { description }
        }
        let ingestionInfo: Ingestion?; let resolution: String?; let frameRate: String?; let ingestionType: String?
    }
    struct Status: Decodable { let streamStatus: String? }
    let id: String; let cdn: CDN?; let status: Status?
    var description: String { "YouTubeLiveStream [ingestion redacted]" }
    var debugDescription: String { description }
}
// Preserve additional event metadata, including unknown future paid-event fields.
indirect enum YouTubeLiveJSON: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: YouTubeLiveJSON]), array([YouTubeLiveJSON]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
}
struct YouTubeLiveChatMessage: Decodable, Identifiable {
    struct Snippet: Decodable {
        let type: String; let liveChatId: String?; let authorChannelId: String?; let publishedAt: String?; let displayMessage: String?
        let eventDetails: [String: YouTubeLiveJSON]
        enum Keys: String, CodingKey { case type, liveChatId, authorChannelId, publishedAt, displayMessage }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try c.decode(String.self, forKey: .type)
            liveChatId = try c.decodeIfPresent(String.self, forKey: .liveChatId)
            authorChannelId = try c.decodeIfPresent(String.self, forKey: .authorChannelId)
            publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
            displayMessage = try c.decodeIfPresent(String.self, forKey: .displayMessage)
            eventDetails = try [String: YouTubeLiveJSON](from: decoder)
        }
    }
    struct Author: Decodable { let channelId: String?; let displayName: String?; let profileImageUrl: String?; let isChatOwner: Bool?; let isChatModerator: Bool?; let isChatSponsor: Bool? }
    let id: String; let snippet: Snippet; let authorDetails: Author?
    var isPaid: Bool { ["superChatEvent", "superStickerEvent", "membershipGiftingEvent", "giftMembershipReceivedEvent", "newSponsorEvent", "memberMilestoneChatEvent","giftEvent","fanFundingEvent"].contains(snippet.type) }
}
struct YouTubeLiveChatPage: Decodable {
    let items: [YouTubeLiveChatMessage]; let nextPageToken: String?; let pollingIntervalMillis: Int; let offlineAt: String?
}
enum YouTubeBroadcastFilter { case all, upcoming, active, completed
    func includes(_ broadcast: YouTubeLiveBroadcast) -> Bool {
        switch self {
        case .all: return true
        case .upcoming: return ["created", "ready", "testStarting", "testing"].contains(broadcast.status.lifeCycleStatus ?? "")
        case .active: return ["liveStarting", "live"].contains(broadcast.status.lifeCycleStatus ?? "")
        case .completed: return broadcast.status.lifeCycleStatus == "complete"
        }
    }
}
enum YouTubeBroadcastTransition: String { case testing, live, complete }
enum YouTubeStreamResolution: String { case p1080 = "1080p", variable }
enum YouTubeStreamFrameRate: String { case fps30 = "30fps", fps60 = "60fps", variable }
enum YouTubeLiveAPIError: Error, LocalizedError {
    case invalidInput(String), authentication, transport, invalidResponse, responseTooLarge
    case provider(status: Int, reason: String?, retryAfter: TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .invalidInput(let explanation): return explanation
        case .authentication: return "YouTube authentication is unavailable. Reconnect the Google account."
        case .transport: return "YouTube request failed before a response was received."
        case .invalidResponse: return "YouTube returned an invalid or incomplete response."
        case .responseTooLarge: return "YouTube response exceeded the 2 MiB resource limit."
        case let .provider(status, reason, _): return "YouTube API HTTP \(status)" + (reason.map { ": \($0)" } ?? "")
        }
    }
    var retryable: Bool {
        switch self {
        case .transport: return true
        case let .provider(status, reason, _): return status == 429 || (500...599).contains(status) || (status == 403 && ["rateLimitExceeded", "userRequestsExceedRateLimit"].contains(reason ?? ""))
        default: return false
        }
    }
    var retryAfter: TimeInterval { if case .provider(_, _, let delay) = self { return delay ?? 0 }; return 0 }
}
private final class YouTubeNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private struct YouTubeErrorEnvelope: Decodable {
    struct Detail: Decodable {struct Entry: Decodable {let reason:String?};let errors:[Entry]?}
    let error:Detail?
}

@MainActor
final class YouTubeLiveController: ObservableObject {
    @Published private(set) var broadcasts: [YouTubeLiveBroadcast] = []
    @Published private(set) var broadcastNextPageToken: String?
    @Published private(set) var messages: [YouTubeLiveChatMessage] = []
    @Published private(set) var chatState = "Stopped"
    @Published private(set) var chatError: String?
    @Published private(set) var pollingIntervalMillis: Int?
    private let tokenProvider: @MainActor () async throws -> String
    private let session: URLSession
    private let ownsSession:Bool
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration = UUID()
    private var chatID: String?
    private var pageToken: String?
    private var seenIDs: Set<String> = []
    private var seenOrder: [String] = []
    private static let parts = "id,snippet,status,contentDetails"
    init(tokenProvider: @escaping @MainActor () async throws -> String, session: URLSession? = nil,
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }) {
        self.tokenProvider=tokenProvider;self.sleep=sleep;ownsSession=session == nil
        if let session {self.session=session}
        else {
            let configuration=URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=45
            configuration.httpCookieStorage=nil;configuration.urlCache=nil
            self.session=URLSession(configuration:configuration)
        }
    }
    deinit {pollingTask?.cancel();if ownsSession {session.invalidateAndCancel()}}

    // 'mine' and 'broadcastStatus' are exclusive filters. Filter owned results locally;
    // callers retain the server cursor and can explicitly fetch further pages.
    @discardableResult
    func listOwnedBroadcasts(filter: YouTubeBroadcastFilter = .all, pageToken: String? = nil) async throws -> YouTubeLivePage<YouTubeLiveBroadcast> {
        var query = ["part": Self.parts, "mine": "true", "broadcastType": "all", "maxResults": "50"]
        if let pageToken { try validateID(pageToken); query["pageToken"] = pageToken }
        let page: YouTubeLivePage<YouTubeLiveBroadcast> = try await request("liveBroadcasts", query: query)
        let filtered = page.items.filter(filter.includes)
        broadcasts = filtered; broadcastNextPageToken = page.nextPageToken
        return YouTubeLivePage(items: filtered, nextPageToken: page.nextPageToken)
    }
    func broadcast(id: String) async throws -> YouTubeLiveBroadcast {
        try validateID(id)
        let page: YouTubeLivePage<YouTubeLiveBroadcast> = try await request("liveBroadcasts", query: ["part": Self.parts, "id": id])
        guard let value = page.items.first(where: { $0.id == id }) else { throw YouTubeLiveAPIError.invalidResponse }; return remember(value)
    }
    func createPrivateBroadcast(title: String, scheduledStart: Date, madeForKids: Bool) async throws -> YouTubeLiveBroadcast {
        try validateTitle(title)
        guard scheduledStart.timeIntervalSince1970.isFinite else { throw YouTubeLiveAPIError.invalidInput("Choose a valid start time.") }
        let body: [String: Any] = ["snippet": ["title": title, "scheduledStartTime": ISO8601DateFormatter().string(from: scheduledStart)],
            "status": ["privacyStatus": "private", "selfDeclaredMadeForKids": madeForKids],
            "contentDetails": ["enableAutoStart": false, "enableAutoStop": false, "monitorStream": ["enableMonitorStream": true, "broadcastStreamDelayMs": 0]]]
        let value: YouTubeLiveBroadcast = try await request("liveBroadcasts", method: "POST", query: ["part": Self.parts], body: body)
        guard value.status.privacyStatus == "private" else { throw YouTubeLiveAPIError.invalidResponse }
        return value
    }
    func createStream(title: String, resolution: YouTubeStreamResolution = .p1080, frameRate: YouTubeStreamFrameRate = .fps30) async throws -> YouTubeLiveStream {
        try validateTitle(title)
        guard (resolution == .variable) == (frameRate == .variable) else { throw YouTubeLiveAPIError.invalidInput("Variable resolution and frame rate must be selected together.") }
        return try await request("liveStreams", method: "POST", query: ["part": "id,snippet,cdn,status,contentDetails"], body: ["snippet": ["title": title], "cdn": ["resolution": resolution.rawValue, "frameRate": frameRate.rawValue, "ingestionType": "rtmp"], "contentDetails": ["isReusable": false]])
    }
    func stream(id: String) async throws -> YouTubeLiveStream {
        try validateID(id)
        let page: YouTubeLivePage<YouTubeLiveStream> = try await request("liveStreams", query: ["part": "id,cdn,status", "id": id])
        guard let value = page.items.first(where: { $0.id == id }) else { throw YouTubeLiveAPIError.invalidResponse }; return value
    }
    func bind(broadcastID: String, streamID: String) async throws -> YouTubeLiveBroadcast {
        try validateID(broadcastID); try validateID(streamID)
        return try await request("liveBroadcasts/bind", method: "POST", query: ["part": Self.parts, "id": broadcastID, "streamId": streamID])
    }
    // Limited to private broadcasts; this controller cannot expose an existing public event.
    func transition(broadcastID: String, to state: YouTubeBroadcastTransition) async throws -> YouTubeLiveBroadcast {
        var current = try await broadcast(id: broadcastID)
        guard current.status.privacyStatus == "private" else { throw YouTubeLiveAPIError.invalidInput("This build transitions private test broadcasts only.") }
        if current.status.lifeCycleStatus == state.rawValue {return current}
        // With monitorStream enabled Google requires testing before live.
        // The intermediate states are asynchronous and must finish before another
        // transition is requested. Keep this protocol interpretation at this owner.
        if state == .live && current.contentDetails?.monitorStream?.enableMonitorStream == true {
            if current.status.lifeCycleStatus == "ready" {
                current=try await requestTransition(current,to:.testing)
            }
            if current.status.lifeCycleStatus == "testStarting" {
                current=try await waitForTransition(current,to:.testing)
            }
            guard ["testing","liveStarting","live"].contains(current.status.lifeCycleStatus ?? "") else {
                throw YouTubeLiveAPIError.invalidInput("YouTube must finish preparing the monitor stream before going live. Refresh its status.")
            }
        }
        if current.status.lifeCycleStatus == state.rawValue {return current}
        let pending=state == .testing ? "testStarting":"liveStarting"
        if state == .complete || current.status.lifeCycleStatus != pending {current=try await requestTransition(current,to:state)}
        return try await waitForTransition(current,to:state)
    }
    private func requestTransition(_ current:YouTubeLiveBroadcast,to state:YouTubeBroadcastTransition)async throws->YouTubeLiveBroadcast {
        guard current.status.privacyStatus == "private" else {throw YouTubeLiveAPIError.invalidInput("This build transitions private test broadcasts only.")}
        if state != .complete {
            guard let streamID = current.contentDetails?.boundStreamId else { throw YouTubeLiveAPIError.invalidInput("Bind a stream before starting the broadcast.") }
            let input = try await stream(id: streamID)
            guard input.status?.streamStatus == "active" else { throw YouTubeLiveAPIError.invalidInput("YouTube has not detected an active incoming stream yet.") }
            if state == .testing && current.contentDetails?.monitorStream?.enableMonitorStream != true { throw YouTubeLiveAPIError.invalidInput("Testing requires the YouTube monitor stream to be enabled.") }
        }
        let updated:YouTubeLiveBroadcast=try await request("liveBroadcasts/transition", method: "POST", query: ["part": Self.parts, "id": current.id, "broadcastStatus": state.rawValue])
        return remember(updated)
    }
    private func remember(_ value:YouTubeLiveBroadcast)->YouTubeLiveBroadcast {
        if let index=broadcasts.firstIndex(where:{$0.id==value.id}) {broadcasts[index]=value}
        return value
    }
    private func waitForTransition(_ initial:YouTubeLiveBroadcast,to state:YouTubeBroadcastTransition)async throws->YouTubeLiveBroadcast {
        var current=initial
        for _ in 0..<30 {
            try Task.checkCancellation()
            if current.status.lifeCycleStatus == state.rawValue {return current}
            let pending=state == .testing ? "testStarting":"liveStarting"
            guard state != .complete,current.status.lifeCycleStatus == pending else{throw YouTubeLiveAPIError.invalidResponse}
            try await sleep(2)
            current=try await broadcast(id:current.id)
            guard current.status.privacyStatus == "private" else{throw YouTubeLiveAPIError.invalidInput("The broadcast visibility changed. Its transition was stopped.")}
        }
        if current.status.lifeCycleStatus == state.rawValue {return current}
        throw YouTubeLiveAPIError.invalidInput("YouTube is still processing this broadcast. Refresh its status before trying another action.")
    }
    func listChat(liveChatID: String, pageToken: String? = nil) async throws -> YouTubeLiveChatPage {
        try validateID(liveChatID)
        var query = ["part": "id,snippet,authorDetails", "liveChatId": liveChatID, "maxResults": "500"]
        if let pageToken { try validateID(pageToken); query["pageToken"] = pageToken }
        let page: YouTubeLiveChatPage = try await request("liveChat/messages", query: query)
        guard page.pollingIntervalMillis >= 0, page.pollingIntervalMillis <= 86_400_000 else { throw YouTubeLiveAPIError.invalidResponse }
        return page
    }
    func sendText(liveChatID: String, text: String) async throws -> YouTubeLiveChatMessage {
        try validateID(liveChatID)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 4096 else { throw YouTubeLiveAPIError.invalidInput("Enter a chat message within the 4096-byte request bound.") }
        return try await request("liveChat/messages", method: "POST", query: ["part": "snippet"], body: ["snippet": ["liveChatId": liveChatID, "type": "textMessageEvent", "textMessageDetails": ["messageText": text]]])
    }
    func startChat(liveChatID: String) throws {
        try validateID(liveChatID)
        stopChat()
        if chatID != liveChatID { messages = []; seenIDs = []; seenOrder = []; pageToken = nil }
        chatID = liveChatID; chatError = nil; chatState = "Connecting"
        let generation = UUID(); pollingGeneration = generation
        pollingTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.pollingGeneration == generation else { return }
                do {
                    let page = try await self.listChat(liveChatID: liveChatID, pageToken: self.pageToken)
                    try Task.checkCancellation()
                    guard self.pollingGeneration == generation else { return }
                    self.receive(page.items); self.pageToken = page.nextPageToken
                    self.pollingIntervalMillis = page.pollingIntervalMillis; failures = 0; self.chatError = nil
                    if page.offlineAt != nil { self.chatState = "Ended"; return }
                    self.chatState = "Connected"
                    try await self.sleep(max(1, Double(page.pollingIntervalMillis) / 1000))
                } catch is CancellationError { return }
                catch {
                    guard self.pollingGeneration == generation, !Task.isCancelled else { return }
                    let failure = (error as? YouTubeLiveAPIError) ?? .transport
                    self.chatError = failure.localizedDescription
                    failures += 1
                    guard failure.retryable, failures <= 5 else { self.chatState = "Stopped after error"; return }
                    self.chatState = "Reconnecting"
                    let delay = max(max(1, Double(self.pollingIntervalMillis ?? 0) / 1000), max(failure.retryAfter, min(60, pow(2, Double(failures)))))
                    do { try await self.sleep(delay) } catch { return }
                }
            }
        }
    }
    // Preserves cursor/history for explicit reconnect to the same chat. No automatic restart.
    func stopChat() { pollingGeneration = UUID(); pollingTask?.cancel(); pollingTask = nil; chatState = "Stopped" }
    func clearChat() { stopChat(); chatID = nil; pageToken = nil; messages = []; seenIDs = []; seenOrder = []; chatError = nil; pollingIntervalMillis = nil }
    private func receive(_ items: [YouTubeLiveChatMessage]) {
        var indices=Dictionary(uniqueKeysWithValues:messages.enumerated().map{($0.element.id,$0.offset)})
        for item in items {
            // Google reuses gift-event IDs when its combo count changes.
            if let index=indices[item.id] {messages[index]=item}
            else if seenIDs.insert(item.id).inserted {indices[item.id]=messages.count;messages.append(item);seenOrder.append(item.id)}
        }
        if messages.count > 500 { messages.removeFirst(messages.count - 500) }
        // IDs cover the retained history and one full provider page, without unlimited growth.
        if seenOrder.count > 1000 { let count = seenOrder.count - 1000; for id in seenOrder.prefix(count) { seenIDs.remove(id) }; seenOrder.removeFirst(count) }
    }
    private func validateID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw YouTubeLiveAPIError.invalidInput("A valid YouTube resource ID or page cursor is required.") }
    }
    private func validateTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 100 else { throw YouTubeLiveAPIError.invalidInput("Enter a broadcast title of 1 to 100 characters.") }
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", query: [String: String], body: [String: Any]? = nil) async throws -> T {
        try Task.checkCancellation()
        let token: String
        do { token = try await tokenProvider() } catch is CancellationError { throw CancellationError() } catch { throw YouTubeLiveAPIError.authentication }
        guard !token.isEmpty, token.utf8.count < 16384, !token.contains("\r"), !token.contains("\n") else { throw YouTubeLiveAPIError.authentication }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/" + path)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard request.httpBody!.count <= 16384 else { throw YouTubeLiveAPIError.invalidInput("YouTube request exceeded the 16 KiB body limit.") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: YouTubeNoRedirect())
            guard let response = response as? HTTPURLResponse else { throw YouTubeLiveAPIError.invalidResponse }
            guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw YouTubeLiveAPIError.responseTooLarge }
            var data = Data(); data.reserveCapacity(min(65536, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < 2 * 1024 * 1024 else { throw YouTubeLiveAPIError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard (200...299).contains(response.statusCode) else {
                let rawReason = (try? JSONDecoder().decode(YouTubeErrorEnvelope.self, from: data))?.error?.errors?.first?.reason
                let reason = rawReason.flatMap { raw -> String? in
                    guard raw.count <= 80, raw.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }), !raw.contains(token) else { return nil }; return raw
                }
                let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? min(86400, $0) : nil }
                throw YouTubeLiveAPIError.provider(status: response.statusCode, reason: reason, retryAfter: delay)
            }
            do { return try JSONDecoder().decode(T.self, from: data) } catch { throw YouTubeLiveAPIError.invalidResponse }
        } catch is CancellationError { throw CancellationError() }
        catch let error as YouTubeLiveAPIError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw YouTubeLiveAPIError.transport }
    }
}
