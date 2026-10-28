import Foundation

/// Imports the composition document only. Never reads account stores or starts devices.
enum VidystCollectionImport {
    private struct Collection: Decodable {
        let schemaVersion: Int
        let sources: [Input]
        let scenes: [Scene]
        let pointers: [String:String]
        let audio: Value?
        let cameraLUTs: Value?
    }
    private struct Input: Decodable { let id: UUID; let name: String; let kind: [String:Value]; let audio: Value? }
    private struct Scene: Decodable {
        let id: UUID; let name: String; let verticalName: String?; let template: String?
        let horizontal: [Layer]; let vertical: [Layer]
        let arrangesGuests: Bool; let isLinked: Bool; let sceneAudio: [Value]
    }
    private struct Layer: Decodable {
        let id: UUID; let sourceID: UUID; let transform: Transform
        let crop: Crop; let mask: [String:Value]; let filters: [Value]
        let fit: String; let isVisible: Bool; let isMirrored: Bool; let opacity: Double
        let isLinked: Bool; let isLocked: Bool; let role: String?
    }
    private struct Transform: Decodable { let x: Double; let y: Double; let width: Double; let height: Double; let rotationDegrees: Double }
    private struct Crop: Decodable { let left: Double; let right: Double; let top: Double; let bottom: Double }
    private enum Value: Decodable {
        case object([String:Value]), array([Value]), number(Double), string(String), bool(Bool), null
        init(from decoder:Decoder) throws {
            let c=try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b=try? c.decode(Bool.self) { self = .bool(b) }
            else if let n=try? c.decode(Double.self), n.isFinite { self = .number(n) }
            else if let s=try? c.decode(String.self) { self = .string(s) }
            else if let a=try? c.decode([Value].self) { self = .array(a) }
            else { self = .object(try c.decode([String:Value].self)) }
        }
        var object: [String:Value]? { if case .object(let o)=self {return o};return nil }
        var number: Double? { if case .number(let n)=self {return n};return nil }
        var string: String? { if case .string(let s)=self {return s};return nil }
        var bool: Bool? { if case .bool(let b)=self {return b};return nil }
    }
    private static func failure(_ message:String)->NSError { NSError(domain:"VidystCollectionImport",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    static func load(_ data:Data) throws -> (project:StudioProject,limitations:[String]) {
        guard data.count <= 8_000_000 else { throw failure("Composition exceeds the 8 MB importer bound.") }
        let original=try JSONDecoder().decode(Collection.self,from:data)
        guard original.schemaVersion == 1, !original.scenes.isEmpty else {throw failure("Unsupported or empty collection.")}
        guard Set(original.sources.map(\.id)).count == original.sources.count,
              Set(original.scenes.map(\.id)).count == original.scenes.count else {throw failure("Duplicate source or scene identity.")}
        var issues:Set<String> = []
        let inputs=Dictionary(uniqueKeysWithValues:original.sources.map {($0.id,$0)})
        var project=StudioProject(); project.name="Imported Vidyst Studio"; project.scenes=[]
        project.elements=[]; project.canvasVisibility="both"; project.editingVertical=true
        let cameraIDs=Set(original.sources.compactMap {$0.kind["camera"]?.object?["deviceID"]?.string})
        if cameraIDs.count == 1 {project.cameraDeviceID=cameraIDs.first!}
        else if cameraIDs.count > 1 {issues.insert("Multiple camera inputs are present; the reconstruction currently has one global camera device.")}
        let mics=original.sources.filter {$0.kind["microphone"] != nil}
        if mics.count == 1 {
            project.microphoneDeviceID=mics[0].kind["microphone"]?.object?["deviceID"]?.string ?? ""
            if let settings=mics[0].audio?.object {
                if let fader=settings["fader"]?.number, (0...4).contains(fader) {project.microphoneVolume=fader}
                if let muted=settings["isMuted"]?.bool {project.microphoneMuted=muted}
            }
        }
        if original.sources.contains(where:{$0.audio != nil}) || original.audio != nil {
            issues.insert("Audio routing, master/headphone faders, tracks, monitoring, delay and effects are not imported; only one microphone device/fader/mute can be represented. No capture is started.")
        }
        if let lut=original.cameraLUTs?.object,!lut.isEmpty {issues.insert("Camera LUT assignments are retained only in the source snapshot; they are not rendered.")}
        for input in original.sources {
            guard input.kind.count == 1 else {throw failure("Source \(input.id) must have exactly one kind tag.")}
            if let kind=input.kind.keys.first,!(["camera","display","text","color","microphone","systemAudio"].contains(kind)) {
                issues.insert("Unsupported source kind '\(kind)' (\(input.id)); its layers are omitted. No external asset is fetched.")
            }
        }
        for scene in original.scenes {
            var mapped=StudioScene(id:scene.id,name:scene.name)
            mapped.layout=scene.name
            mapped.verticalLayout=scene.verticalName ?? scene.name
            mapped.sources=try layers(scene.horizontal,canvasWidth:1920,canvasHeight:1080,inputs:inputs,issues:&issues)
            mapped.verticalSources=try layers(scene.vertical,canvasWidth:1080,canvasHeight:1920,inputs:inputs,issues:&issues)
            // Source labels are preserved. Labels observed on the vertical UI are a separate field.
            if scene.verticalName == nil,let template=scene.template {
                let observed=["screenCam":"Stacked","camLeft":"Stacked inverted","screenTile":"Screen + bubble","screenTileLeft":"Spotlight","side":"Two up","sideLeft":"Two up inverted"]
                if let label=observed[template] {mapped.verticalLayout=label;issues.insert("Some absent vertical labels were filled using template/UI correspondence; this fallback is inferred.")}
            }
            if scene.isLinked || scene.horizontal.contains(where:{$0.isLinked}) || scene.vertical.contains(where:{$0.isLinked}) {
                issues.insert("Shared source/layer linkage is flattened into independently editable layers; sourceID references remain in the retained original snapshot.")
            }
            if scene.arrangesGuests {issues.insert("Dynamic guest arrangement in '\(scene.name)' is imported as saved static geometry.")}
            if !scene.sceneAudio.isEmpty {issues.insert("Scene-specific audio routing in '\(scene.name)' is not imported.")}
            project.scenes.append(mapped)
        }
        func pointer(_ key:String)throws->UUID? {
            guard let raw=original.pointers[key] else {return nil}
            guard let id=UUID(uuidString:raw),project.scenes.contains(where:{$0.id == id}) else {throw failure("Invalid \(key) scene identity.")}
            return id
        }
        project.selectedSceneID=try pointer("horizontalProgram") ?? project.scenes.first?.id
        project.selectedVerticalSceneID=try pointer("verticalProgram") ?? project.selectedSceneID
        for key in ["horizontalPreview","verticalPreview"] {_ = try pointer(key)}
        issues.insert("Canvas dimensions use the reconstruction's 1920×1080 and 1080×1920 defaults; this collection contains normalized geometry, not output settings.")
        issues.insert("Display capture input IDs are preserved only in the original snapshot; the reconstruction uses its primary-display capture path; original display/window selection is not supported. No capture starts during import.")
        issues.insert("Rounded mask radii are converted as a fraction of the shorter layer dimension; this unit correspondence is inferred from saved geometry, not verified by a rendered comparison.")
        return (project,issues.sorted())
    }
    private static func layers(_ layers:[Layer],canvasWidth:Double,canvasHeight:Double,inputs:[UUID:Input],issues:inout Set<String>)throws->[StudioSource] {
        guard Set(layers.map(\.id)).count == layers.count else {throw failure("Duplicate layer identity within a canvas.")}
        return try layers.compactMap { layer in
            guard let input=inputs[layer.sourceID] else {throw failure("Layer \(layer.id) references a missing source.")}
            let t=layer.transform,c=layer.crop
            guard [t.x,t.y,t.width,t.height,t.rotationDegrees,c.left,c.right,c.top,c.bottom,layer.opacity].allSatisfy(\.isFinite),
                  t.width > 0,t.height > 0,(0...1).contains(layer.opacity),
                  [c.left,c.right,c.top,c.bottom].allSatisfy({(0...0.99).contains($0)}),c.left+c.right < 1,c.top+c.bottom < 1 else {throw failure("Invalid geometry, crop or opacity on \(layer.id).")}
            guard let tag=input.kind.keys.first,let payload=input.kind[tag]?.object else {throw failure("Malformed source kind payload on \(input.id).")}
            var source=StudioSource(id:layer.id,name:input.name,kind:tag)
            switch tag {
            case "camera": source.kind="camera"
            case "display": source.kind="screen"
            case "text":
                guard let settings=payload["_0"]?.object,let text=settings["text"]?.string else {throw failure("Malformed text source \(input.id).")}
                source.text=text
                issues.insert("Text font family, size, weight, foreground/background color and alignment are not representable in the current renderer; text content and layer geometry are preserved.")
            case "color":
                guard let rgba=payload["_0"]?.object else {throw failure("Malformed color source \(input.id).")}
                var components:[Double]=[]
                for channel in ["red","green","blue","alpha"] {
                    guard let n=rgba[channel]?.number,(0...1).contains(n) else {throw failure("Invalid color component on \(input.id).")};components.append(n)
                }
                source.text=String(format:"#%02X%02X%02X",Int((components[0]*255).rounded()),Int((components[1]*255).rounded()),Int((components[2]*255).rounded()))
                source.opacity=components[3]
                issues.insert("Color components are quantized to the renderer's 8-bit RGB hex representation.")
            case "microphone","systemAudio": issues.insert("Audio sources are not visual layers and were excluded from visual composition.");return nil
            default:return nil
            }
            source.x=t.x;source.y=t.y;source.width=t.width;source.height=t.height;source.rotation=t.rotationDegrees
            source.visible=layer.isVisible;source.mirrored=layer.isMirrored;source.opacity *= layer.opacity
            source.cropLeft=c.left;source.cropRight=c.right;source.cropTop=c.top;source.cropBottom=c.bottom
            let fit=["Fill":"fill","Fit":"fit","Stretch":"stretch"]
            guard let mode=fit[layer.fit] else {throw failure("Unknown fit mode '\(layer.fit)' on \(layer.id).")};source.fit=mode
            guard layer.mask.count == 1,let mask=layer.mask.keys.first else {throw failure("Ambiguous mask on \(layer.id).")}
            let shortSide=min(t.width*canvasWidth,t.height*canvasHeight)
            switch mask {
            case "none":break
            case "circle":
                source.cornerRadius=shortSide/2
                if abs(t.width*canvasWidth-t.height*canvasHeight)>0.01 {issues.insert("A circle mask on a nonsquare layer is approximated by a rounded rectangle; the current model has no ellipse mask.")}
            case "roundedRect":
                guard let radius=layer.mask[mask]?.object?["radius"]?.number,radius >= 0 else {throw failure("Invalid rounded mask radius on \(layer.id).")};source.cornerRadius=radius*shortSide
            default:issues.insert("Unsupported mask '\(mask)' on \(layer.id) is omitted.")
            }
            if !layer.filters.isEmpty {issues.insert("Filters on layer \(layer.id) are not imported; no filter equivalence is assumed.")}
            if layer.isLocked {issues.insert("Layer locks are not imported; the current editor has no lock state.")}
            return source
        }
    }
    /// Runs against a retained composition fixture; no application or account state is read.
    static func runSelfTest(_ fixture:Data)throws {
        let result=try load(fixture)
        guard !result.project.scenes.isEmpty,result.project.scenes.allSatisfy({$0.verticalSources != nil}) else {throw failure("Import lost scene/canvas coverage.")}
        let encoded=try JSONEncoder().encode(result.project)
        _ = try ProjectDocument.decode(encoded)
        func rejected(_ mutate:(inout [String:Any])->Void)throws {
            var object=try JSONSerialization.jsonObject(with:fixture) as! [String:Any];mutate(&object)
            let data=try JSONSerialization.data(withJSONObject:object)
            do {_ = try load(data)} catch {return};throw failure("Malformed fixture was accepted.")
        }
        try rejected { root in var scenes=root["scenes"] as! [[String:Any]];scenes[0]["id"]="bad-id";root["scenes"]=scenes }
        try rejected { root in var scenes=root["scenes"] as! [[String:Any]];scenes.append(scenes[0]);root["scenes"]=scenes }
        try rejected { root in var pointers=root["pointers"] as! [String:Any];pointers["horizontalProgram"]="00000000-0000-0000-0000-000000000000";root["pointers"]=pointers }
        try rejected { root in
            var scenes=root["scenes"] as! [[String:Any]],layers=scenes[0]["horizontal"] as! [[String:Any]],transform=layers[0]["transform"] as! [String:Any]
            transform["width"] = -1;layers[0]["transform"]=transform;scenes[0]["horizontal"]=layers;root["scenes"]=scenes
        }
        let raw=String(data:fixture,encoding:.utf8)!
        if let range=raw.range(of:#""opacity" : 1"#) ?? raw.range(of:#""opacity": 1"#) {
            let invalid=raw.replacingCharacters(in:range,with:#""opacity": 1e999"#)
            do {_ = try load(Data(invalid.utf8))} catch {return};throw failure("Nonfinite number was accepted.")
        }
        throw failure("Nonfinite regression fixture could not be produced.")
    }
}
