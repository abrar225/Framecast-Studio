import Foundation
import Combine
import Network
import CryptoKit
import Security
import AppKit

// Independent OAuth client. Sources: Google's desktop-app OAuth and YouTube channels.list docs.
// No vendor identity, token, environment variable or original app state is consulted.
private enum GoogleFailure: LocalizedError {
    case invalidConfiguration, storage, random, callback, cancelled, timeout, browser, server, credentials, permission, channel, response, quota
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:return "Choose an original Google OAuth Desktop client JSON file. Web clients and custom authorization endpoints are not supported."
        case .storage:return "Google connection data could not be saved securely on this Mac."
        case .random:return "Secure authorization randomness is unavailable."
        case .callback:return "The local authorization response was invalid. Try connecting again."
        case .cancelled:return "Google connection cancelled."
        case .timeout:return "Google sign-in timed out. Connect again when ready."
        case .browser:return "The system browser could not be opened."
        case .server:return "Google could not complete this request. Try again later."
        case .credentials:return "Google authorization has expired or was revoked. Connect again."
        case .permission:return "Google did not grant the required YouTube permission. Connect again and approve YouTube access."
        case .channel:return "This Google account has no accessible YouTube channel."
        case .response:return "Google returned an unsupported response."
        case .quota:return "The YouTube API quota is exhausted. Try again later."
        }
    }
}

private enum GooglePKCE {
    static func base64URL(_ data:Data)->String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    static func random(_ count:Int=32)throws->String {
        var data=Data(count:count)
        guard data.withUnsafeMutableBytes({SecRandomCopyBytes(kSecRandomDefault,count,$0.baseAddress!)}) == errSecSuccess else {throw GoogleFailure.random}
        return base64URL(data)
    }
    static func challenge(_ verifier:String)->String {base64URL(Data(SHA256.hash(data:Data(verifier.utf8))))}
    static func equal(_ a:String,_ b:String)->Bool {
        let x=Array(a.utf8),y=Array(b.utf8);guard x.count == y.count else {return false}
        var difference:UInt8=0;for i in x.indices {difference |= x[i] ^ y[i]};return difference == 0
    }
    static func form(_ fields:[String:String])->Data {
        let allowed=CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.keys.sorted().map { key in key.addingPercentEncoding(withAllowedCharacters:allowed)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters:allowed)! }.joined(separator:"&").utf8)
    }
}

private struct GoogleClientConfiguration: Codable {
    let clientID:String
    static func parse(_ data:Data)throws->(GoogleClientConfiguration,String?) {
        guard data.count <= 64_000 else {throw GoogleFailure.invalidConfiguration}
        struct Download:Decodable {let installed:Installed?;struct Installed:Decodable {let client_id:String;let client_secret:String?;let auth_uri:String?;let token_uri:String?}}
        guard let download=try? JSONDecoder().decode(Download.self,from:data),let config=download.installed,
              config.client_id.hasSuffix(".apps.googleusercontent.com"),config.client_id.utf8.count < 512,
              config.client_id.unicodeScalars.allSatisfy({CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._").contains($0)}),
              config.auth_uri == nil || config.auth_uri == "https://accounts.google.com/o/oauth2/auth" || config.auth_uri == "https://accounts.google.com/o/oauth2/v2/auth",
              config.token_uri == nil || config.token_uri == "https://oauth2.googleapis.com/token",
              (config.client_secret?.utf8.count ?? 0) < 4096 else {throw GoogleFailure.invalidConfiguration}
        return (GoogleClientConfiguration(clientID:config.client_id),config.client_secret)
    }
    var account:String {GooglePKCE.base64URL(Data(SHA256.hash(data:Data(clientID.utf8))))}
}

private enum GoogleSecureStore {
    static let service="local.vidyst.reconstructed.google.oauth"
    static func get(_ account:String)throws->Data? {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&item)
        if status == errSecItemNotFound {return nil};guard status == errSecSuccess,let data=item as? Data else {throw GoogleFailure.storage};return data
    }
    static func set(_ data:Data?,_ account:String)throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        if let data {
            let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
            if status == errSecItemNotFound {
                var add=query;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else {throw GoogleFailure.storage}
            } else if status != errSecSuccess {throw GoogleFailure.storage}
        } else {
            let status=SecItemDelete(query as CFDictionary);guard status == errSecSuccess || status == errSecItemNotFound else {throw GoogleFailure.storage}
        }
    }
}

/// Strict, bounded parser shared by the real callback listener and offline adversarial tests.
private enum GoogleCallback {
    static func code(_ bytes:Data,port:UInt16,state:String)throws->String {
        guard bytes.count <= 16_384,let text=String(data:bytes,encoding:.utf8),text.hasSuffix("\r\n\r\n") else {throw GoogleFailure.callback}
        let lines=text.components(separatedBy:"\r\n"),request=lines[0].components(separatedBy:" ")
        guard request.count == 3,request[0] == "GET",request[2] == "HTTP/1.1",request[1].hasPrefix("/oauth2/callback?"),
              !request[1].contains("#"),let parts=URLComponents(string:"http://127.0.0.1"+request[1]),parts.percentEncodedPath == "/oauth2/callback" else {throw GoogleFailure.callback}
        let target=Array(request[1].utf8)
        let hexadecimal:Set<UInt8>=Set("0123456789abcdefABCDEF".utf8)
        for i in target.indices where target[i] == 37 {
            guard i+2 < target.count,hexadecimal.contains(target[i+1]),hexadecimal.contains(target[i+2]) else {throw GoogleFailure.callback}
        }
        var headers:[String:String]=[:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon=line.firstIndex(of:":"),!line.hasPrefix(" "),!line.hasPrefix("\t") else {throw GoogleFailure.callback}
            let name=line[..<colon].lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard headers[name] == nil else {throw GoogleFailure.callback};headers[name]=value
        }
        guard headers["host"] == "127.0.0.1:\(port)",headers["transfer-encoding"] == nil,headers["content-length"] == nil || headers["content-length"] == "0" else {throw GoogleFailure.callback}
        var query:[String:String]=[:]
        let allowed:Set<String>=["state","code","error","error_description","error_uri","scope","authuser","prompt","hd","iss"]
        for item in parts.queryItems ?? [] {
            guard allowed.contains(item.name),query[item.name] == nil,let value=item.value,value.utf8.count <= 8192 else {throw GoogleFailure.callback};query[item.name]=value
        }
        guard let actual=query["state"],GooglePKCE.equal(actual,state),query["code"] == nil || query["error"] == nil else {throw GoogleFailure.callback}
        if let issuer=query["iss"],issuer != "https://accounts.google.com" {throw GoogleFailure.callback}
        if query["error"] != nil {throw GoogleFailure.permission}
        guard let code=query["code"],!code.isEmpty,code.utf8.count <= 4096 else {throw GoogleFailure.callback}
        return code
    }
}

@MainActor private final class GoogleLoopback {
    private var listener:NWListener?
    private var continuation:CheckedContinuation<(String,URL),Error>?
    private var deadline:Task<Void,Never>?
    private var connections:[UUID:NWConnection]=[:]
    private var connectionDeadlines:[UUID:Task<Void,Never>]=[:]
    private var redirect:URL?
    private var state=""
    private var totalConnections=0
    private var open:((URL)->Bool)?
    func receive(state:String,timeout:TimeInterval=300,open:@escaping (URL)->Bool)async throws->(String,URL) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                self.continuation=continuation;self.state=state;self.open=open
                do {
                    let parameters=NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
                    let listener=try NWListener(using:parameters);self.listener=listener
                    listener.stateUpdateHandler={ [weak self] status in Task { @MainActor in
                        guard let self,self.continuation != nil else {return}
                        switch status {
                        case .ready:
                            guard self.redirect == nil,let port=self.listener?.port else {return}
                            let uri=URL(string:"http://127.0.0.1:\(port.rawValue)/oauth2/callback")!;self.redirect=uri
                            if self.open?(uri) != true {self.finish(.failure(GoogleFailure.browser))}
                        case .failed:self.finish(.failure(GoogleFailure.server))
                        default:break
                        }
                    }}
                    listener.newConnectionHandler={ [weak self] connection in Task { @MainActor in self?.accept(connection) }}
                    listener.start(queue:.main)
                    deadline=Task { @MainActor [weak self] in
                        do {try await Task.sleep(nanoseconds:UInt64(timeout*1_000_000_000));self?.finish(.failure(GoogleFailure.timeout))} catch {}
                    }
                } catch {self.finish(.failure(GoogleFailure.server))}
            }
        },onCancel:{Task { @MainActor [weak self] in self?.cancel() }})
    }
    func cancel() {finish(.failure(GoogleFailure.cancelled))}
    private func accept(_ connection:NWConnection) {
        guard continuation != nil,connections.count < 4,totalConnections < 32 else {connection.cancel();return}
        totalConnections += 1;let id=UUID();connections[id]=connection
        connectionDeadlines[id]=Task { @MainActor [weak self] in
            do {try await Task.sleep(nanoseconds:5_000_000_000);self?.close(id)} catch {}
        }
        connection.start(queue:.main);read(connection,id:id,buffer:Data())
    }
    private func read(_ connection:NWConnection,id:UUID,buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] data,_,complete,error in Task { @MainActor in
            guard let self,self.connections[id] != nil else {return}
            var bytes=buffer;if let data {bytes.append(data)}
            guard bytes.count <= 16_384,error == nil else {self.close(id);return}
            if bytes.range(of:Data("\r\n\r\n".utf8)) != nil {
                guard let port=self.listener?.port?.rawValue,let redirect=self.redirect else {self.close(id);return}
                let result:Result<(String,URL),Error>
                do {result = .success((try GoogleCallback.code(bytes,port:port,state:self.state),redirect))}
                catch GoogleFailure.permission {result = .failure(GoogleFailure.permission)}
                catch {self.reply(connection,id:id,valid:false,completion:nil);return}
                self.reply(connection,id:id,valid:true,completion:result)
            } else if complete {self.close(id)} else {self.read(connection,id:id,buffer:bytes)}
        }}
    }
    private func reply(_ connection:NWConnection,id:UUID,valid:Bool,completion:Result<(String,URL),Error>?) {
        let body=valid ? "Authorization received. You can close this tab and return to the studio." : "Invalid authorization response. Return to the studio and try again."
        let response="HTTP/1.1 \(valid ? "200 OK":"400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n\(body)"
        connection.send(content:Data(response.utf8),completion:.contentProcessed { [weak self] _ in Task { @MainActor in
            guard let self else {return};self.close(id);if let completion {self.finish(completion)}
        }})
    }
    private func close(_ id:UUID) {connectionDeadlines.removeValue(forKey:id)?.cancel();connections.removeValue(forKey:id)?.cancel()}
    private func finish(_ result:Result<(String,URL),Error>) {
        guard let continuation else {return};self.continuation=nil
        deadline?.cancel();deadline=nil;listener?.stateUpdateHandler=nil;listener?.newConnectionHandler=nil;listener?.cancel();listener=nil
        for id in Array(connections.keys) {close(id)}
        open=nil;state="";redirect=nil
        continuation.resume(with:result)
    }
}

private final class GoogleNoRedirect:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
}
private enum GoogleHTTP {
    static func request(_ request:URLRequest,limit:Int=262_144)async throws->(Data,Int) {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=45
        configuration.httpCookieStorage=nil;configuration.urlCache=nil;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session=URLSession(configuration:configuration,delegate:GoogleNoRedirect(),delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        do {
            let (stream,response)=try await session.bytes(for:request)
            guard let http=response as? HTTPURLResponse,response.expectedContentLength <= Int64(limit) else {throw GoogleFailure.response}
            var data=Data();for try await byte in stream {guard data.count < limit else {throw GoogleFailure.response};data.append(byte)}
            return (data,http.statusCode)
        } catch is CancellationError {throw GoogleFailure.cancelled}
        catch let error as GoogleFailure {throw error}
        catch {throw GoogleFailure.server}
    }
    static func form(_ endpoint:String,_ fields:[String:String])async throws->(Data,Int) {
        var request=URLRequest(url:URL(string:endpoint)!);request.httpMethod="POST"
        request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type");request.httpBody=GooglePKCE.form(fields)
        return try await self.request(request,limit:65_536)
    }
}

@MainActor final class GoogleYouTubeController:ObservableObject {
    enum ConnectionState:String {case notConfigured,disconnected,connecting,connected,refreshing,disconnecting}
    struct Channel:Identifiable,Equatable {let id:String;let title:String;let customURL:String?}
    @Published private(set) var connectionState:ConnectionState = .notConfigured
    @Published private(set) var channel:Channel?
    @Published private(set) var errorMessage:String?
    var clientConfigured:Bool {configuration != nil}
    var isConnected:Bool {connectionState == .connected}
    private var configuration:GoogleClientConfiguration?
    private var operation:Task<Void,Never>?
    private var callback:GoogleLoopback?
    private var epoch=UUID()
    private let configURL:URL
    private struct Token:Codable {let accessToken:String;let refreshToken:String?;let expiresAt:Date;let scope:String?}
    private struct TokenResponse:Decodable {let access_token:String;let refresh_token:String?;let expires_in:Double;let scope:String?;let token_type:String}
    init() {
        configURL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Vidyst Reconstructed/Google/client.json")
        if let data=try? Data(contentsOf:configURL),data.count <= 1024,let config=try? JSONDecoder().decode(GoogleClientConfiguration.self,from:data),config.clientID.hasSuffix(".apps.googleusercontent.com") {
            configuration=config;connectionState = .disconnected
        }
        // A saved authorization is refreshed only when the user asks to connect or refresh.
    }
    func configureClient(from url:URL)throws {
        guard operation == nil else {throw GoogleFailure.invalidConfiguration}
        let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
        let attributes=try? url.resourceValues(forKeys:[.fileSizeKey]);guard (attributes?.fileSize ?? Int.max) <= 64_000 else {throw GoogleFailure.invalidConfiguration}
        let parsed:(GoogleClientConfiguration,String?)
        do {parsed=try GoogleClientConfiguration.parse(Data(contentsOf:url))} catch {throw GoogleFailure.invalidConfiguration}
        do {
            let folder=configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if FileManager.default.fileExists(atPath:configURL.path) {
                let existing=try Data(contentsOf:configURL),next=try JSONEncoder().encode(parsed.0)
                if existing != next {
                    let backup=folder.appendingPathComponent("client-backup-\(UUID().uuidString).json");try existing.write(to:backup,options:.withoutOverwriting)
                }
            }
            try GoogleSecureStore.set(parsed.1.map {Data($0.utf8)},"client-secret-"+parsed.0.account)
            try JSONEncoder().encode(parsed.0).write(to:configURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configURL.path)
            configuration=parsed.0;channel=nil;connectionState = .disconnected;errorMessage=nil
        } catch {throw GoogleFailure.storage}
    }
    func connect() {
        guard let config=configuration else {errorMessage=GoogleFailure.invalidConfiguration.localizedDescription;return}
        guard operation == nil else {return}
        epoch=UUID();let current=epoch;connectionState = .connecting;errorMessage=nil
        operation=Task { [weak self] in
            guard let self else {return}
            do {
                var needsAuthorization=true
                if let stored=try self.storedToken(config),stored.refreshToken != nil {
                    do {_ = try await self.accessToken(config);try self.check(current);needsAuthorization=false}
                    catch GoogleFailure.credentials {try GoogleSecureStore.set(nil,"tokens-"+config.account)}
                }
                if needsAuthorization {
                    let state=try GooglePKCE.random(),verifier=try GooglePKCE.random(),loopback=GoogleLoopback();self.callback=loopback
                    let (code,redirect)=try await loopback.receive(state:state) { redirect in
                        let url=Self.authorizationURL(clientID:config.clientID,redirect:redirect,state:state,verifier:verifier)
                        return NSWorkspace.shared.open(url)
                    }
                    try self.check(current)
                    var fields=["client_id":config.clientID,"code":code,"code_verifier":verifier,"redirect_uri":redirect.absoluteString,"grant_type":"authorization_code"]
                    if let secret=try self.clientSecret(config) {fields["client_secret"]=secret}
                    let (data,status)=try await GoogleHTTP.form("https://oauth2.googleapis.com/token",fields)
                    try self.check(current);try self.saveTokenResponse(data,status:status,config:config,previous:nil)
                }
                let channel=try await self.fetchChannel(config);try self.check(current)
                self.channel=channel;self.connectionState = .connected
            } catch {if self.epoch == current {self.connectionState = .disconnected;self.errorMessage=Self.safe(error)}}
            if self.epoch == current {self.operation=nil;self.callback=nil}
        }
    }
    func cancelConnect() {
        epoch=UUID();operation?.cancel();operation=nil;callback?.cancel();callback=nil
        connectionState=configuration == nil ? .notConfigured:.disconnected;errorMessage=nil
    }
    /// Removes local credentials and revokes this independent client's grant at Google.
    func disconnect() {
        cancelConnect();guard let config=configuration else {return}
        let token:Token?
        do {token=try storedToken(config);try GoogleSecureStore.set(nil,"tokens-"+config.account)}
        catch {errorMessage=GoogleFailure.storage.localizedDescription;return}
        channel=nil;connectionState = .disconnecting;epoch=UUID();let current=epoch
        operation=Task { [weak self] in
            guard let self else {return}
            do {
                if let value=token?.refreshToken ?? token?.accessToken {
                    let (_,status)=try await GoogleHTTP.form("https://oauth2.googleapis.com/revoke",["token":value])
                    try self.check(current);guard status == 200 || status == 400 else {throw GoogleFailure.server}
                }
            } catch {if self.epoch == current {self.errorMessage="Local Google access was removed. Google revocation could not be confirmed; you can remove this app in your Google Account permissions."}}
            if self.epoch == current {self.connectionState = .disconnected;self.operation=nil}
        }
    }
    func refreshChannel() {
        guard let config=configuration,operation == nil else {return};epoch=UUID();let current=epoch
        connectionState = .refreshing;errorMessage=nil
        operation=Task { [weak self] in
            guard let self else {return}
            do {let channel=try await self.fetchChannel(config);try self.check(current);self.channel=channel;self.connectionState = .connected}
            catch {if self.epoch == current {self.connectionState = .disconnected;self.errorMessage=Self.safe(error)}}
            if self.epoch == current {self.operation=nil}
        }
    }
    /// Normal application startup can restore an existing grant without opening
    /// consent. Offline validators and snapshot rendering never invoke this.
    func restoreSavedConnection() {
        guard let config=configuration,operation == nil else{return}
        do {guard try storedToken(config) != nil else{return}}
        catch {errorMessage=GoogleFailure.storage.localizedDescription;return}
        refreshChannel()
    }
    private func check(_ current:UUID)throws {try Task.checkCancellation();guard epoch == current else {throw GoogleFailure.cancelled}}
    private static func safe(_ error:Error)->String {(error as? GoogleFailure)?.localizedDescription ?? GoogleFailure.server.localizedDescription}
    private func clientSecret(_ config:GoogleClientConfiguration)throws->String? {try GoogleSecureStore.get("client-secret-"+config.account).flatMap {String(data:$0,encoding:.utf8)}}
    private func storedToken(_ config:GoogleClientConfiguration)throws->Token? {
        guard let data=try GoogleSecureStore.get("tokens-"+config.account) else {return nil}
        guard let token=try? JSONDecoder().decode(Token.self,from:data) else {throw GoogleFailure.credentials};return token
    }
    private func saveTokenResponse(_ data:Data,status:Int,config:GoogleClientConfiguration,previous:Token?)throws {
        guard status == 200 else {throw status == 400 || status == 401 ? GoogleFailure.credentials:GoogleFailure.server}
        guard let response=try? JSONDecoder().decode(TokenResponse.self,from:data),!response.access_token.isEmpty,response.access_token.utf8.count <= 16_384,
              response.token_type.lowercased() == "bearer",response.expires_in.isFinite,(1...86400).contains(response.expires_in) else {throw GoogleFailure.response}
        if let scope=response.scope,!scope.split(separator:" ").contains(Substring(Self.scope)) {throw GoogleFailure.permission}
        let token=Token(accessToken:response.access_token,refreshToken:response.refresh_token ?? previous?.refreshToken,expiresAt:Date().addingTimeInterval(response.expires_in),scope:response.scope ?? previous?.scope)
        try GoogleSecureStore.set(JSONEncoder().encode(token),"tokens-"+config.account)
    }
    private func accessToken(_ config:GoogleClientConfiguration,forceRefresh:Bool=false)async throws->String {
        guard let stored=try storedToken(config) else {throw GoogleFailure.credentials}
        if !forceRefresh,stored.expiresAt.timeIntervalSinceNow > 60 {return stored.accessToken}
        guard let refresh=stored.refreshToken else {throw GoogleFailure.credentials}
        var fields=["client_id":config.clientID,"refresh_token":refresh,"grant_type":"refresh_token"]
        if let secret=try clientSecret(config) {fields["client_secret"]=secret}
        let current=epoch,(data,status)=try await GoogleHTTP.form("https://oauth2.googleapis.com/token",fields)
        try check(current);try saveTokenResponse(data,status:status,config:config,previous:stored)
        guard let token=try storedToken(config) else {throw GoogleFailure.credentials};return token.accessToken
    }
    /// Supplies this app's bearer token to the independently implemented YouTube REST client.
    /// Callers must never log or persist the returned transport credential.
    func validAccessToken()async throws->String {
        guard let config=configuration else {throw GoogleFailure.invalidConfiguration}
        let current=epoch,token=try await accessToken(config)
        try check(current);return token
    }
    private func fetchChannel(_ config:GoogleClientConfiguration)async throws->Channel {
        var token=try await accessToken(config)
        for attempt in 0...1 {
            var request=URLRequest(url:URL(string:"https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true&maxResults=1")!)
            request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            let (data,status)=try await GoogleHTTP.request(request)
            try Task.checkCancellation()
            if status == 401 && attempt == 0 {token=try await accessToken(config,forceRefresh:true);continue}
            guard status == 200 else {
                if status == 401 {throw GoogleFailure.credentials}
                if status == 403 {
                    struct APIError:Decodable {let error:Detail;struct Detail:Decodable {let errors:[Reason]?};struct Reason:Decodable {let reason:String}}
                    let reasons=(try? JSONDecoder().decode(APIError.self,from:data))?.error.errors?.map(\.reason) ?? []
                    if reasons.contains("quotaExceeded") || reasons.contains("dailyLimitExceeded") {throw GoogleFailure.quota}
                    throw GoogleFailure.permission
                };throw GoogleFailure.server
            }
            return try Self.decodeChannel(data)
        }
        throw GoogleFailure.credentials
    }
    private static func decodeChannel(_ data:Data)throws->Channel {
        struct List:Decodable {let items:[Item];struct Item:Decodable {let id:String;let snippet:Snippet};struct Snippet:Decodable {let title:String;let customUrl:String?}}
        guard let result=try? JSONDecoder().decode(List.self,from:data) else {throw GoogleFailure.response}
        guard let item=result.items.first else {throw GoogleFailure.channel}
        guard !item.id.isEmpty,item.id.count <= 256,item.snippet.title.count <= 1024 else {throw GoogleFailure.response}
        return Channel(id:item.id,title:item.snippet.title,customURL:item.snippet.customUrl)
    }
    static let scope="https://www.googleapis.com/auth/youtube.force-ssl"
    private static func authorizationURL(clientID:String,redirect:URL,state:String,verifier:String)->URL {
        var url=URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems=["client_id":clientID,"redirect_uri":redirect.absoluteString,"response_type":"code","scope":scope,"access_type":"offline","prompt":"consent","state":state,"code_challenge":GooglePKCE.challenge(verifier),"code_challenge_method":"S256"].map {URLQueryItem(name:$0.key,value:$0.value)}
        return url.url!
    }
    /// Pure/offline validation only; no stored credentials are accessed.
    static func runSelfTest()throws {
        func check(_ value:Bool,_ text:String)throws {if !value {throw NSError(domain:"GoogleOfflineSelfTest",code:1,userInfo:[NSLocalizedDescriptionKey:text])}}
        try check(GooglePKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM","RFC7636 S256 vector failed")
        let state="test-state",port:UInt16=45678
        func request(_ target:String,_ host:String="127.0.0.1:45678")->Data {Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)}
        try check(try GoogleCallback.code(request("/oauth2/callback?state=test-state&code=abc%2B123"),port:port,state:state) == "abc+123","Callback decoding failed")
        for invalid in [request("/wrong?state=test-state&code=a"),request("/oauth2/callback?state=wrong&code=a"),request("/oauth2/callback?state=test-state&state=test-state&code=a"),request("/oauth2/callback?state=test-state&code=a&error=denied"),request("/oauth2/callback?state=test-state&code=a","attacker.example"),request("/oauth2/callback?state=test-state&code=%zz"),request("/oauth2/callback?state=test-state&code=a&iss=https%3A%2F%2Fattacker.example"),Data(repeating:65,count:16_385)] {
            do {_ = try GoogleCallback.code(invalid,port:port,state:state);throw GoogleFailure.response} catch GoogleFailure.response {throw GoogleFailure.response} catch {}
        }
        let sample=Data(#"{"installed":{"client_id":"123-test.apps.googleusercontent.com","client_secret":"offline-placeholder","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}"#.utf8)
        let parsed=try GoogleClientConfiguration.parse(sample);try check(parsed.0.clientID == "123-test.apps.googleusercontent.com","Config parse failed")
        let web=Data(#"{"web":{"client_id":"123-test.apps.googleusercontent.com"}}"#.utf8)
        do {_ = try GoogleClientConfiguration.parse(web);throw GoogleFailure.response} catch GoogleFailure.response {throw GoogleFailure.response} catch {}
        try check(try decodeChannel(Data(#"{"items":[{"id":"channel-test","snippet":{"title":"Offline channel","customUrl":"@test"}}]}"#.utf8)).title == "Offline channel","Channel response failed")
    }
    static func runLoopbackSelfTest()async throws {
        let server=GoogleLoopback()
        let result=try await server.receive(state:"offline-state",timeout:3) { uri in
            Task { @MainActor in
                func send(_ state:String)async throws->Int {
                    var url=URLComponents(url:uri,resolvingAgainstBaseURL:false)!
                    url.queryItems=[URLQueryItem(name:"state",value:state),URLQueryItem(name:"code",value:"offline-code")]
                    let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=2
                    let session=URLSession(configuration:config);defer {session.invalidateAndCancel()}
                    let (_,response)=try await session.data(from:url.url!)
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
                do {
                    guard try await send("wrong-state") == 400 else {server.cancel();return}
                    guard try await send("offline-state") == 200 else {server.cancel();return}
                } catch {server.cancel()}
            }
            return true
        }
        guard result.0 == "offline-code",result.1.host == "127.0.0.1",result.1.port != nil else {throw GoogleFailure.response}
        let timed=GoogleLoopback()
        do {_ = try await timed.receive(state:"offline",timeout:0.05,open:{_ in true});throw GoogleFailure.response}
        catch GoogleFailure.timeout {} // Expected: listener and pending continuation both finalized.
        let cancelled=GoogleLoopback()
        let task=Task {try await cancelled.receive(state:"offline",timeout:3,open:{_ in true})}
        await Task.yield();task.cancel()
        do {_ = try await task.value;throw GoogleFailure.response}
        catch GoogleFailure.cancelled {} catch is CancellationError {}
    }

}
