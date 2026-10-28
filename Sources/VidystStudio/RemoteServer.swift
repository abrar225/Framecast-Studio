import Foundation
import Network
import CryptoKit

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
        case ("POST", "/action"):
            guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let action = request["action"] as? String else { response(peer, status: "400 Bad Request", body: "JSON action required"); return }
            responseJSON(peer, command(action, args: request["args"] as? [String: Any] ?? [:]))
        default: response(peer, status: "404 Not Found", body: "Not found")
        }
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
        return ["application":"Vidyst Reconstructed", "layout":model.selectedLayout,
                "canvasMode":model.canvasMode, "editingCanvas":model.vertical ? "vertical":"horizontal",
                "layouts":model.project.scenes.map { scene in
                    let sources=model.vertical ? (scene.verticalSources ?? scene.sources):scene.sources
                    return ["id":scene.id.uuidString,"name":scene.name,"onAir":scene.id == model.scene.id,
                            "horizontalOnAir":scene.id == model.project.selectedSceneID,"verticalOnAir":scene.id == model.project.selectedVerticalSceneID,
                            "layers":sources.map { ["key":$0.id.uuidString,"name":$0.name,"shown":$0.visible] as [String:Any] }] as [String:Any]
                },
                "templates":StudioModel.layouts, "stream":["phase":model.engine.streaming ? "starting":"idle","encoderProcessRunning":model.engine.streaming,"deliveryVerified":false,"errorMessage":NSNull()],
                "recording":["isOn":model.engine.recording,"isPaused":model.engine.recordingPaused],
                "audio":[["key":"microphone","name":"Microphone","muted":model.project.microphoneMuted,"gain":model.engine.microphoneGain]],
                "guests":["slots":[],"knockingCount":0], "limitations":["Loopback only; no iOS discovery or LAN control", "No guest control, audio faders or provider chat", "Original Stream Deck plugin requires adapted discovery configuration"]]
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
        case "layer.toggle":
            let canvas=args["canvas"] ?? (model.vertical ? "vertical":"horizontal")
            guard let canvas=canvas as? String, ["horizontal","vertical"].contains(canvas) else{return ["ok":false,"code":"invalidArgument","message":"canvas must be horizontal or vertical"]}
            guard let sceneRaw=args["layoutID"] as? String, let sceneID=UUID(uuidString:sceneRaw),
                  let sourceRaw=args["layerKey"] as? String, let sourceID=UUID(uuidString:sourceRaw),
                  model.toggleSourceVisibility(sceneID:sceneID,sourceID:sourceID,onVerticalCanvas:canvas == "vertical") else{return ["ok":false,"code":"notFound"]}
        case "audio.mute":
            guard args["key"] as? String == "microphone" else { return failure("Only the microphone mute is available") }
            model.project.microphoneMuted.toggle(); model.engine.microphoneEnabled = !model.project.microphoneMuted; model.save()
        case "audio.setGain":
            guard args["key"] as? String == "microphone", let gain = args["value"] as? Double, gain.isFinite, (0...4).contains(gain) else { return ["ok":false,"code":"invalidArgument"] }
            model.project.microphoneVolume = gain; model.engine.microphoneGain = gain; model.save()
        case "record.toggle":
            guard !model.engine.isFinalizingRecording else { return ["ok":false,"code":"blocked","message":"Recording is still finalizing"] }
            let wasRecording = model.engine.recording; model.toggleRecording()
            if !wasRecording && !model.engine.recording { return ["ok":false,"code":"blocked","message":"Recording did not start; check the studio"] }
        case "record.pause":
            guard model.engine.recording else{return ["ok":false,"code":"blocked","message":"Start recording before pausing"]}
            model.toggleRecordingPause()
        case "stream.start":
            guard !model.engine.streaming else { return ["ok":true,"code":"ok"] }
            guard model.project.destinations.filter({$0.enabled}).count == 1 else { return ["ok":false,"code":"blocked","message":"Configure exactly one enabled destination in the studio"] }
            model.toggleStreaming(); return ["ok":true,"code":"requested","message":"Stream start requested; check the studio for encoder or connection errors"]
        case "stream.stop": if model.engine.streaming { model.toggleStreaming() }
        default: return failure("This command is not implemented in the independent reconstruction")
        }
        return ["ok":true,"code":"ok"]
    }
    private var dashboard: String { #"""
<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Studio control</title><style>body{background:#181615;color:#eee6de;font:16px system-ui;max-width:720px;margin:40px auto;padding:20px}button{padding:14px;margin:6px;border:1px solid #554b43;border-radius:9px;background:#302a25;color:inherit;cursor:pointer}h1{font-size:26px}.muted{color:#b3a69a}#status{padding:18px;background:#24201d;border-radius:12px}button.active{background:#785c32}</style></head><body><h1>Framecast Studio · Control</h1><p class="muted">Private, loopback control. This is an independent dashboard; iPhone/LAN control and guest management are unavailable.</p><p id="status">Connecting…</p><button onclick="act('record.toggle')">Record / Stop</button><button onclick="act('audio.mute',{key:'microphone'})">Mute / Unmute mic</button><button onclick="act('stream.start')">Start stream</button><button onclick="act('stream.stop')">End stream</button><p>Mic gain <input aria-label="Microphone gain" type="range" min="0" max="4" step="0.05" value="1" onchange="act('audio.setGain',{key:'microphone',value:Number(this.value)})"></p><h2>Scenes</h2><div id="scenes"></div><h2>Layouts</h2><div id="templates"></div><p id="notice" role="status"></p><script>
const token=new URLSearchParams(location.search).get('token');const headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'};
async function act(action,args={}){try{const r=await fetch('/action',{method:'POST',headers,body:JSON.stringify({action,args})});const value=await r.json();document.querySelector('#notice').textContent=value.message||value.code;await update()}catch(e){document.querySelector('#notice').textContent='Control connection unavailable'}}
function buttons(id,list,action,arg){const root=document.getElementById(id);root.replaceChildren();for(const item of list){const b=document.createElement('button');b.textContent=typeof item==='string'?item:item.name;if(item.onAir)b.className='active';b.onclick=()=>act(action,{[arg]:typeof item==='string'?item:item.id});root.appendChild(b)}}
async function update(){try{const r=await fetch('/state',{headers});if(!r.ok)throw Error();const s=await r.json();document.querySelector('#status').textContent=(s.recording.isOn?'● Recording':'Recording stopped')+' · Stream '+s.stream.phase+' · '+s.layout+' · Mic '+(s.audio[0].muted?'muted':'on');buttons('scenes',s.layouts,'layout.pick','id');buttons('templates',s.templates,'template.pick','name')}catch(e){document.querySelector('#status').textContent='Disconnected. Open the current private URL from the studio.'}}update();setInterval(update,1500);
</script></body></html>
"""# }
}
