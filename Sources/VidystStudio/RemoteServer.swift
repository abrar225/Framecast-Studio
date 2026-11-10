import Foundation
import Network
import CryptoKit
import AppKit

/// Independent local control bridge. It never reads Vidyst's discovery files or tokens.
@MainActor final class RemoteServer {
    private weak var model: StudioModel?
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var timer: Timer?
    private let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private let discoveryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vidyst Reconstructed/control.json")
    private var discoveryOwned = false
    private(set) var address = "Starting local control…"
    private let maximum = 65_536

    @MainActor private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var websocket = false
        var authenticated = false
        var sending = false
        var pendingBytes = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }
    init(model: StudioModel) { self.model = model }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    self.address = "http://127.0.0.1:\(port.rawValue)/?token=\(self.token)"
                    self.model?.remoteAddress = self.address
                    do {
                        try FileManager.default.createDirectory(at: self.discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.discoveryURL.deletingLastPathComponent().path)
                        let data = try JSONSerialization.data(withJSONObject: ["port": Int(port.rawValue), "token": self.token, "pid": ProcessInfo.processInfo.processIdentifier, "protocol": ["major":1,"minor":0]])
                        try data.write(to: self.discoveryURL, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.discoveryURL.path)
                        self.discoveryOwned = true
                    } catch { self.model?.notice = "Control works, but discovery could not be saved: \(error.localizedDescription)" }
                case .failed(let error):
                    self.model?.notice = "Local control failed: \(error.localizedDescription)"
                    self.stop()
                    self.model?.remoteActive = false
                    self.model?.remoteAddress = ""
                default: break
                }
            }
        }
        listener.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.broadcast() }
        }
    }
    func stop() {
        listener?.cancel(); listener = nil
        timer?.invalidate(); timer = nil
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll()
        // Only delete a discovery document still bearing this server's token.
        if discoveryOwned, let data = try? Data(contentsOf: discoveryURL), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["token"] as? String == token {
            do { try FileManager.default.removeItem(at: discoveryURL); discoveryOwned = false }
            catch { model?.notice = "Could not remove local control discovery: \(error.localizedDescription)" }
        }
        address = ""
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, peers.count < 8 else { connection.cancel(); return }
        let peer = Peer(connection); peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            Task { @MainActor in
                guard let self, let peer else { return }
                if case .failed = state { self.close(peer) }
                if case .cancelled = state { self.peers.removeValue(forKey: peer.id) }
            }
        }
        connection.start(queue: .main)
        receive(peer)
        // Idle unauthenticated sockets must not consume all slots indefinitely.
        Task { @MainActor [weak self, weak peer] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let peer, !peer.authenticated else { return }; self.close(peer)
        }
    }
    private func close(_ peer: Peer) { peers.removeValue(forKey: peer.id); peer.connection.cancel() }
    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [weak self, weak peer] data, _, complete, error in
            Task { @MainActor in
                guard let self, let peer, self.peers[peer.id] != nil else { return }
                if let data { peer.buffer.append(data) }
                guard peer.buffer.count <= self.maximum + 14 else { self.close(peer); return }
                if peer.websocket { self.frames(peer) } else { self.http(peer) }
                if complete || error != nil { self.close(peer) }
                else if self.peers[peer.id] != nil { self.receive(peer) }
            }
        }
    }
    private func http(_ peer: Peer) {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let end = peer.buffer.range(of: delimiter) else { return }
        guard let header = String(data: peer.buffer[..<end.lowerBound], encoding: .utf8) else { close(peer); return }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { close(peer); return }
        let parts = first.split(separator: " ")
        guard parts.count == 3, let components = URLComponents(string: String(parts[1])), String(parts[1]).hasPrefix("/") else { close(peer); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { close(peer); return }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { close(peer); return }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { close(peer); return }
        let length: Int
        if let raw = headers["content-length"] { guard let n = Int(raw), n >= 0, n <= maximum else { close(peer); return }; length = n } else { length = 0 }
        guard end.upperBound + length <= maximum else { close(peer); return }
        guard peer.buffer.count >= end.upperBound + length else { return }
        let queryToken = components.queryItems?.first(where: { $0.name == "token" })?.value
        let authorized = queryToken == token || headers["authorization"] == "Bearer \(token)"
        if headers["upgrade"]?.lowercased() == "websocket" {
            guard parts[0] == "GET", headers["sec-websocket-version"] == "13", let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else { response(peer, status: "400 Bad Request", body: "Invalid WebSocket handshake"); return }
            // Browser connections require a private URL token. A non-browser plugin may authenticate in hello.
            guard headers["origin"] == nil || authorized else { response(peer, status: "403 Forbidden", body: "Token required"); return }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            peer.websocket = true; peer.authenticated = authorized
            peer.buffer.removeSubrange(..<end.upperBound)
            send(peer, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
            if !peer.buffer.isEmpty { frames(peer) }; return
        }
        guard authorized else { response(peer, status: "403 Forbidden", body: "Open the private control URL shown in the studio."); return }
        peer.authenticated = true
        let body = peer.buffer.subdata(in: end.upperBound..<(end.upperBound + length))
        switch (String(parts[0]), components.path) {
        case ("GET", "/"): response(peer, body: dashboard, contentType: "text/html; charset=utf-8")
        case ("GET", "/state"): responseJSON(peer, state())
        case ("GET", "/snapshot.jpg"), ("GET", "/preview.jpg"):
            if let image = model?.engine.preview ?? model?.engine.secondaryPreview,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
                responseBinary(peer, data: jpeg, contentType: "image/jpeg")
            } else {
                response(peer, status: "503 Service Unavailable", body: "No preview frame available")
            }
        case ("POST", "/action"):
            guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let action = request["action"] as? String else { response(peer, status: "400 Bad Request", body: "JSON action required"); return }
            responseJSON(peer, command(action, args: request["args"] as? [String: Any] ?? [:]))
        default: response(peer, status: "404 Not Found", body: "Not found")
        }
    }
    private func responseBinary(_ peer: Peer, status: String = "200 OK", data: Data, contentType: String) {
        var result = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\nExpires: 0\r\nAccess-Control-Allow-Origin: *\r\n\r\n".utf8)
        result.append(data)
        peer.connection.send(content: result, completion: .contentProcessed { [weak self, weak peer] _ in Task { @MainActor in if let self, let peer { self.close(peer) } } })
    }
    private func response(_ peer: Peer, status: String = "200 OK", body: String, contentType: String = "text/plain; charset=utf-8") {
        let data = Data(body.utf8)
        var result = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'\r\n\r\n".utf8)
        result.append(data)
        peer.connection.send(content: result, completion: .contentProcessed { [weak self, weak peer] _ in Task { @MainActor in if let self, let peer { self.close(peer) } } })
    }
    private func responseJSON(_ peer: Peer, _ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let body = String(data: data, encoding: .utf8) else { close(peer); return }
        response(peer, body: body, contentType: "application/json")
    }
    private func send(_ peer: Peer, _ data: Data) {
        guard peer.pendingBytes + data.count <= maximum + 1024 else { close(peer); return }
        peer.pendingBytes += data.count
        peer.connection.send(content: data, completion: .contentProcessed { [weak self, weak peer] error in
            Task { @MainActor in
                guard let self, let peer else { return }
                peer.pendingBytes = max(0, peer.pendingBytes - data.count)
                if error != nil { self.close(peer) }
            }
        })
    }
    private func packet(_ peer: Peer, _ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= maximum else { close(peer); return }
        frame(peer, opcode: 1, data: data)
    }
    private func frame(_ peer: Peer, opcode: UInt8, data: Data) {
        var result = Data([0x80 | opcode])
        if data.count < 126 { result.append(UInt8(data.count)) }
        else if data.count <= 65535 { result.append(126); result.append(UInt8(data.count >> 8)); result.append(UInt8(data.count & 255)) }
        else { result.append(127); let size = UInt64(data.count); for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((size >> shift) & 255)) } }
        result.append(data); send(peer, result)
    }
    private func frames(_ peer: Peer) {
        while peer.buffer.count >= 2 {
            let bytes = [UInt8](peer.buffer.prefix(14))
            let opcode = bytes[0] & 15
            guard bytes[0] & 0xF0 == 0x80, bytes[1] & 0x80 != 0, [1,8,9,10].contains(opcode) else { close(peer); return }
            var count = Int(bytes[1] & 127), offset = 2
            if count == 126 { guard bytes.count >= 4 else { return }; count = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4 }
            else if count == 127 {
                guard bytes.count >= 10 else { return }
                var size: UInt64 = 0; for byte in bytes[2..<10] { size = (size << 8) | UInt64(byte) }
                guard size <= maximum else { close(peer); return }; count = Int(size); offset = 10
            }
            guard count <= maximum, (opcode == 1 || count <= 125) else { close(peer); return }
            guard peer.buffer.count >= offset + 4 + count else { return }
            let all = [UInt8](peer.buffer.prefix(offset + 4 + count)); let mask = Array(all[offset..<(offset+4)]); offset += 4
            let payload = Data((0..<count).map { all[offset+$0] ^ mask[$0 % 4] })
            peer.buffer.removeSubrange(..<(offset + count))
            if opcode == 8 { close(peer); return }
            if opcode == 9 { frame(peer, opcode: 10, data: payload); continue }
            if opcode == 10 { continue }
            guard String(data: payload, encoding: .utf8) != nil, let request = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let type = request["type"] as? String else { close(peer); return }
            if type == "hello" {
                guard peer.authenticated || request["token"] as? String == token,
                      let version = request["protocol"] as? [String: Any], version["major"] as? Int == 1 else { close(peer); return }
                peer.authenticated = true
                packet(peer, ["type":"welcome", "appVersion":"independent-0.1", "protocol":["major":1,"minor":0]])
                packet(peer, ["type":"state", "state":state()])
            } else {
                guard peer.authenticated else { close(peer); return }
                if type == "command", let action = request["action"] as? String {
                    var result = command(action, args: request["args"] as? [String:Any] ?? [:]); result["type"] = "result"; result["id"] = request["id"] ?? NSNull(); packet(peer,result)
                    packet(peer,["type":"state","state":state()])
                } else if type == "subscribe" { /* No fabricated audio meters. */ }
                else { packet(peer,["type":"error","code":"unsupported","message":"Unsupported control message"]) }
            }
        }
    }
    private func broadcast() {
        let snapshot = state()
        for peer in Array(peers.values) where peer.websocket && peer.authenticated && !peer.sending {
            guard let payload = try? JSONSerialization.data(withJSONObject:["type":"state","state":snapshot]), payload.count <= maximum else { close(peer); continue }
            peer.sending = true
            // Backpressure bounds each peer to one pending snapshot.
            var output = Data([0x81])
            if payload.count < 126 { output.append(UInt8(payload.count)) }
            else if payload.count <= 65535 { output.append(126); output.append(UInt8(payload.count >> 8)); output.append(UInt8(payload.count & 255)) }
            else { close(peer); continue }
            output.append(payload)
            peer.connection.send(content: output, completion: .contentProcessed { [weak peer] _ in Task { @MainActor in peer?.sending = false } })
        }
    }
    private func state() -> [String:Any] {
        guard let model else { return [:] }
        let enabledCount = model.project.destinations.filter(\.enabled).count
        return ["application":"Framecast Studio", "layout":model.selectedLayout,
                "canvasMode":model.canvasMode, "editingCanvas":model.vertical ? "vertical":"horizontal",
                "layouts":model.project.scenes.map { scene in
                    let sources=model.vertical ? (scene.verticalSources ?? scene.sources):scene.sources
                    return ["id":scene.id.uuidString,"name":scene.name,"onAir":scene.id == model.scene.id,
                            "horizontalOnAir":scene.id == model.project.selectedSceneID,"verticalOnAir":scene.id == model.project.selectedVerticalSceneID,
                            "layers":sources.map { ["key":$0.id.uuidString,"name":$0.name,"shown":$0.visible] as [String:Any] }] as [String:Any]
                },
                "templates":StudioModel.layouts,
                "stream":[
                    "phase":model.engine.streaming ? "streaming":"idle",
                    "encoderProcessRunning":model.engine.streaming,
                    "destinationsCount":enabledCount,
                    "activeOutputs":model.engine.activeStreamOutputs.count,
                    "deliveryVerified":model.engine.streaming,
                    "errorMessage":model.engine.errorMessage ?? ""
                ],
                "recording":[
                    "isOn":model.engine.recording,
                    "isPaused":model.engine.recordingPaused,
                    "isFinalizing":model.engine.isFinalizingRecording,
                    "elapsed":model.engine.elapsed
                ],
                "lowerThird":[
                    "text":model.project.lowerThird,
                    "visible":model.project.lowerThirdVisible
                ],
                "audio":[
                    ["key":"microphone","name":"Microphone","muted":model.project.microphoneMuted,"gain":model.engine.microphoneGain],
                    ["key":"desktop","name":"Desktop Audio","muted":!(model.project.captureSystemAudio ?? false),"gain":model.engine.capturedAudioGain]
                ],
                "destinations":model.project.destinations.map { [
                    "id": $0.id.uuidString,
                    "name": $0.name,
                    "enabled": $0.enabled,
                    "vertical": $0.vertical
                ] },
                "guests":["slots":[],"knockingCount":0],
                "limitations":["Loopback only; private token required"]]
    }
    private func command(_ action: String, args: [String:Any]) -> [String:Any] {
        guard let model else { return ["ok":false,"code":"offline"] }
        func failure(_ message: String) -> [String:Any] { ["ok":false,"code":"unsupported","message":message] }
        switch action {
        case "layout.pick":
            guard let raw = args["id"] as? String, let id = UUID(uuidString:raw), model.project.scenes.contains(where:{$0.id == id}) else { return ["ok":false,"code":"notFound"] }; model.selectScene(id)
        case "layout.next", "layout.prev":
            let count = model.project.scenes.count; let delta = action == "layout.next" ? 1 : -1
            model.selectScene(model.project.scenes[(model.sceneIndex+delta+count)%count].id)
        case "template.pick":
            guard let name = args["name"] as? String, StudioModel.layouts.contains(name) else { return ["ok":false,"code":"notFound"] }; model.applyLayout(name)
        case "canvas.setMode":
            guard let mode = args["mode"] as? String, ["horizontal", "vertical", "both"].contains(mode) else { return ["ok":false,"code":"invalidArgument"] }
            model.canvasMode = mode
            if mode != "both" { model.vertical = mode == "vertical" }
            model.refreshComposition()
        case "elements.toggleLowerThird":
            model.project.lowerThirdVisible.toggle()
            model.refreshComposition()
            model.save()
        case "layer.toggle":
            let canvas=args["canvas"] ?? (model.vertical ? "vertical":"horizontal")
            guard let canvas=canvas as? String, ["horizontal","vertical"].contains(canvas) else{return ["ok":false,"code":"invalidArgument","message":"canvas must be horizontal or vertical"]}
            guard let sceneRaw=args["layoutID"] as? String, let sceneID=UUID(uuidString:sceneRaw),
                  let sourceRaw=args["layerKey"] as? String, let sourceID=UUID(uuidString:sourceRaw),
                  model.toggleSourceVisibility(sceneID:sceneID,sourceID:sourceID,onVerticalCanvas:canvas == "vertical") else{return ["ok":false,"code":"notFound"]}
        case "audio.mute":
            let key = args["key"] as? String ?? "microphone"
            if key == "microphone" {
                model.project.microphoneMuted.toggle()
                model.engine.microphoneEnabled = !model.project.microphoneMuted
                model.save()
            } else if key == "desktop" {
                let current = model.project.captureSystemAudio ?? false
                model.project.captureSystemAudio = !current
                model.engine.capturedAudioEnabled = !current
                model.save()
            } else {
                return failure("Supported audio keys: microphone, desktop")
            }
        case "audio.setGain":
            let key = args["key"] as? String ?? "microphone"
            guard let gain = args["value"] as? Double, gain.isFinite, (0...4).contains(gain) else { return ["ok":false,"code":"invalidArgument"] }
            if key == "microphone" {
                model.project.microphoneVolume = gain
                model.engine.microphoneGain = gain
                model.save()
            } else if key == "desktop" {
                model.project.capturedAudioVolume = gain
                model.engine.capturedAudioGain = gain
                model.save()
            } else {
                return failure("Supported audio keys: microphone, desktop")
            }
        case "record.toggle":
            guard !model.engine.isFinalizingRecording else { return ["ok":false,"code":"blocked","message":"Recording is still finalizing"] }
            let wasRecording = model.engine.recording; model.toggleRecording()
            if !wasRecording && !model.engine.recording { return ["ok":false,"code":"blocked","message":"Recording did not start; check the studio"] }
        case "record.pause":
            guard model.engine.recording else{return ["ok":false,"code":"blocked","message":"Start recording before pausing"]}
            model.toggleRecordingPause()
        case "stream.start":
            guard !model.engine.streaming else { return ["ok":true,"code":"ok"] }
            guard !model.project.destinations.filter({$0.enabled}).isEmpty else { return ["ok":false,"code":"blocked","message":"Configure at least one enabled destination in the studio"] }
            model.toggleStreaming(); return ["ok":true,"code":"requested","message":"Stream start requested; check the studio for encoder or connection errors"]
        case "stream.stop": if model.engine.streaming { model.toggleStreaming() }
        default: return failure("This command is not implemented in the independent reconstruction")
        }
        return ["ok":true,"code":"ok"]
    }
    private var dashboard: String { #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>Framecast Studio Companion</title>
<style>
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
body { background: #141310; color: #EEECE7; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 16px; display: flex; flex-direction: column; align-items: center; min-height: 100vh; }
.deck { width: 100%; max-width: 680px; display: flex; flex-direction: column; gap: 14px; }
.header { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; background: #1C1A16; border: 1px solid #2B2822; border-radius: 12px; }
.brand { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 15px; }
.brand span { color: #F5C849; }
.pill { font-size: 10px; font-weight: 700; padding: 3px 8px; border-radius: 6px; letter-spacing: 0.5px; }
.pill--idle { background: #2A2721; color: #9C9588; }
.pill--rec { background: #FF3B30; color: white; animation: pulse 1.5s infinite; }
.pill--live { background: #34C759; color: black; }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.6; } }

.preview-card { position: relative; width: 100%; background: #000; border: 1px solid #2B2822; border-radius: 12px; overflow: hidden; aspect-ratio: 16/9; display: flex; align-items: center; justify-content: center; }
.preview-img { width: 100%; height: 100%; object-fit: contain; }
.preview-overlay { position: absolute; bottom: 8px; left: 8px; display: flex; gap: 6px; }

.section-title { font-size: 11px; font-weight: 700; letter-spacing: 1px; color: #9C9588; text-transform: uppercase; margin: 6px 0 2px; }
.grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
.grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
.grid-4 { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 8px; }

button { background: #22201B; border: 1px solid #332F27; color: #EEECE7; border-radius: 10px; padding: 12px; font-size: 13px; font-weight: 600; cursor: pointer; transition: all 0.15s; display: flex; align-items: center; justify-content: center; gap: 6px; }
button:active { transform: scale(0.97); }
button.btn-primary { background: #F5C849; color: #141310; border-color: #F5C849; }
button.btn-danger { background: #FF3B30; color: white; border-color: #FF3B30; }
button.btn-active { background: #38342B; border-color: #F5C849; color: #F5C849; }

.card { background: #1C1A16; border: 1px solid #2B2822; border-radius: 12px; padding: 14px; }
.slider-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; }
input[type=range] { flex: 1; accent-color: #F5C849; }
.footer { font-size: 11px; color: #6E685D; text-align: center; margin-top: 10px; }
#notice { font-size: 12px; color: #F5C849; min-height: 18px; text-align: center; }
</style>
</head>
<body>
<div class="deck">
  <div class="header">
    <div class="brand"><span>FRAMECAST</span> STUDIO</div>
    <div id="statusPill" class="pill pill--idle">STANDBY</div>
  </div>

  <div class="preview-card">
    <img id="previewImg" class="preview-img" alt="Live Preview" src="" />
    <div class="preview-overlay">
      <span id="canvasBadge" class="pill pill--idle">16:9</span>
      <span id="recTimeBadge" class="pill pill--idle" style="display:none">00:00</span>
    </div>
  </div>

  <div id="notice"></div>

  <div class="grid-2">
    <button id="btnRec" onclick="act('record.toggle')">● Record</button>
    <button id="btnStream" onclick="toggleStream()">Go Live</button>
  </div>

  <div class="grid-3">
    <button onclick="act('record.pause')">⏸ Pause Take</button>
    <button onclick="act('elements.toggleLowerThird')">Lower Third</button>
    <button onclick="cycleCanvas()">Aspect</button>
  </div>

  <div class="card">
    <div class="section-title">Audio Levels</div>
    <div class="slider-row">
      <button id="btnMicMute" style="padding:6px 12px;font-size:11px" onclick="act('audio.mute',{key:'microphone'})">Mic</button>
      <input type="range" min="0" max="4" step="0.05" id="micSlider" oninput="act('audio.setGain',{key:'microphone',value:Number(this.value)})">
    </div>
    <div class="slider-row">
      <button id="btnDeskMute" style="padding:6px 12px;font-size:11px" onclick="act('audio.mute',{key:'desktop'})">Desktop</button>
      <input type="range" min="0" max="4" step="0.05" id="deskSlider" oninput="act('audio.setGain',{key:'desktop',value:Number(this.value)})">
    </div>
  </div>

  <div class="section-title">Scenes</div>
  <div id="scenes" class="grid-4"></div>

  <div class="section-title">Layout Templates</div>
  <div id="templates" class="grid-4"></div>

  <div class="footer">Encrypted local session · Framecast Studio Companion</div>
</div>

<script>
const token = new URLSearchParams(location.search).get('token') || '';
const headers = { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' };
let currentState = null;

async function act(action, args = {}) {
  try {
    const r = await fetch('/action', { method: 'POST', headers, body: JSON.stringify({ action, args }) });
    const res = await r.json();
    if (res.message) showNotice(res.message);
    await updateState();
  } catch(e) {
    showNotice('Control connection unavailable');
  }
}

function showNotice(msg) {
  const n = document.getElementById('notice');
  n.textContent = msg;
  setTimeout(() => { if (n.textContent === msg) n.textContent = ''; }, 3000);
}

function toggleStream() {
  if (currentState && currentState.stream && currentState.stream.encoderProcessRunning) {
    act('stream.stop');
  } else {
    act('stream.start');
  }
}

function cycleCanvas() {
  if (!currentState) return;
  const modes = ['horizontal', 'vertical', 'both'];
  const next = modes[(modes.indexOf(currentState.canvasMode) + 1) % modes.length];
  act('canvas.setMode', { mode: next });
}

function refreshSnapshot() {
  const img = document.getElementById('previewImg');
  img.src = '/snapshot.jpg?token=' + encodeURIComponent(token) + '&_t=' + Date.now();
}

async function updateState() {
  try {
    const r = await fetch('/state', { headers });
    if (!r.ok) throw Error();
    const s = await r.json();
    currentState = s;

    const pill = document.getElementById('statusPill');
    const recBadge = document.getElementById('recTimeBadge');
    const btnRec = document.getElementById('btnRec');
    const btnStream = document.getElementById('btnStream');

    if (s.recording.isOn) {
      pill.className = s.recording.isPaused ? 'pill pill--idle' : 'pill pill--rec';
      pill.textContent = s.recording.isPaused ? 'REC PAUSED' : 'RECORDING';
      btnRec.className = 'btn-danger';
      btnRec.textContent = '■ Stop (' + Math.floor(s.recording.elapsed || 0) + 's)';
      recBadge.style.display = 'inline-block';
      recBadge.textContent = Math.floor(s.recording.elapsed || 0) + 's';
    } else {
      btnRec.className = '';
      btnRec.textContent = '● Record';
      recBadge.style.display = 'none';
      if (s.stream.encoderProcessRunning) {
        pill.className = 'pill pill--live';
        pill.textContent = 'LIVE (' + (s.stream.activeOutputs || 1) + ')';
      } else {
        pill.className = 'pill pill--idle';
        pill.textContent = 'STANDBY';
      }
    }

    if (s.stream.encoderProcessRunning) {
      btnStream.className = 'btn-danger';
      btnStream.textContent = 'End Stream (' + (s.stream.activeOutputs || 1) + ')';
    } else {
      btnStream.className = (s.destinations && s.destinations.some(d => d.enabled)) ? 'btn-primary' : '';
      btnStream.textContent = 'Go Live';
    }

    document.getElementById('canvasBadge').textContent = s.canvasMode.toUpperCase();

    // Audio
    const mic = s.audio.find(a => a.key === 'microphone');
    if (mic) {
      document.getElementById('btnMicMute').className = mic.muted ? 'btn-danger' : '';
      document.getElementById('micSlider').value = mic.gain;
    }
    const desk = s.audio.find(a => a.key === 'desktop');
    if (desk) {
      document.getElementById('btnDeskMute').className = desk.muted ? 'btn-danger' : '';
      document.getElementById('deskSlider').value = desk.gain;
    }

    // Scenes
    const sceneDiv = document.getElementById('scenes');
    sceneDiv.replaceChildren();
    for (const sc of s.layouts) {
      const b = document.createElement('button');
      b.textContent = sc.name;
      if (sc.onAir) b.className = 'btn-active';
      b.onclick = () => act('layout.pick', { id: sc.id });
      sceneDiv.appendChild(b);
    }

    // Templates
    const tDiv = document.getElementById('templates');
    tDiv.replaceChildren();
    for (const name of s.templates) {
      const b = document.createElement('button');
      b.textContent = name;
      if (name === s.layout) b.className = 'btn-active';
      b.onclick = () => act('template.pick', { name });
      tDiv.appendChild(b);
    }
  } catch(e) {}
}

updateState();
setInterval(updateState, 1500);
refreshSnapshot();
setInterval(refreshSnapshot, 1500);
</script>
</body>
</html>
"""# }
}
