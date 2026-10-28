import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Independent script representation. Marker pacing (1s/.75x/1.25x) is a reconstruction choice;
/// the original's syntax, three-second countdown and 140 WPM were observed, not these factors.
struct PrompterScript {
    struct Word: Identifiable { let id: Int; let text: String; let bold: Bool; let section: Int; let delay: Double; let rate: Double }
    struct Section: Identifiable { let id: Int; let title: String; let firstWord: Int }
    let words: [Word]
    let sections: [Section]
    init(_ source: String) {
        var result: [Word] = [], headings: [Section] = []
        var bold = false, rate = 1.0, delay = 0.0
        let pattern = try! NSRegularExpression(pattern: #"\*\*|\[(?i:pause|slow|fast)\]|[^\s*\[]+|\*|\["#)
        for line in source.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                headings.append(Section(id: headings.count, title: line.trimmingCharacters(in: .whitespaces).drop(while: {$0 == "#" || $0 == " "}).description, firstWord: result.count))
                continue
            }
            let ns = line as NSString
            for match in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let token = ns.substring(with: match.range)
                switch token.lowercased() {
                case "**": bold.toggle()
                case "[pause]": delay += 1
                case "[slow]": rate = 0.75
                case "[fast]": rate = 1.25
                default:
                    result.append(Word(id: result.count, text: token, bold: bold, section: max(0, headings.count - 1), delay: delay, rate: rate)); delay = 0
                }
            }
        }
        words = result; sections = headings
    }
    func ends(wpm: Double) -> [Double] {
        var time = 0.0
        return words.map { word in time += word.delay + 60 / (wpm * word.rate); return time }
    }
}

@MainActor final class PrompterController: ObservableObject {
    enum Phase: String { case idle, counting, running, paused, ended }
    @Published var script: String { didSet { parsed = PrompterScript(script); reset(); save() } }
    @Published private(set) var parsed: PrompterScript
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed = 0.0
    @Published private(set) var countdown = 3.0
    @Published var wpm: Double = 140 {
        didSet {
            let bounded = wpm.isFinite ? min(300,max(60,wpm)) : 140
            // @Published re-enters this observer on assignment. Only normalize once.
            if wpm != bounded { wpm = bounded; return }
            save()
        }
    }
    @Published var textSize = 24.0 { didSet { save() } }
    @Published var readingLine = "Upper" { didSet { save() } }
    @Published var mirrored = false { didSet { save() } }
    @Published var importError: String?
    private let persists: Bool
    private var timer: Timer?
    private var lastTick = Date()
    private let usesTimer: Bool
    private var pausedFrom: Phase = .running
    var duration: Double { parsed.ends(wpm: wpm).last ?? 0 }
    var activeWord: Int { parsed.ends(wpm: wpm).firstIndex(where: {$0 > elapsed}) ?? max(0,parsed.words.count - 1) }
    var activeSection: Int { parsed.words.isEmpty ? 0 : parsed.words[activeWord].section }
    var isReading: Bool { phase != .idle }
    var status: String {
        switch phase { case .idle: return "Script editor"; case .counting: return "Starting in \(Int(ceil(countdown)))…"; case .running: return "Running"; case .paused: return "Paused"; case .ended: return "Finished" }
    }
    init(persist: Bool = true, usesTimer: Bool = true) {
        self.persists = persist; self.usesTimer = usesTimer
        let defaults = UserDefaults.standard
        let intro = "# Welcome\nThis is your private reading space. Add your own script and set a comfortable pace.\n\n# Your next point\nTake a breath [pause] and give **important words** room to land. [slow] Finish with a clear next step."
        let source = persist ? defaults.string(forKey: "reconstructed.prompter.script") ?? intro : intro
        script = source; parsed = PrompterScript(source)
        if persist {
            if let n = defaults.object(forKey: "reconstructed.prompter.wpm") as? Double { wpm = min(300,max(60,n)) }
            if let n = defaults.object(forKey: "reconstructed.prompter.size") as? Double { textSize = min(40,max(18,n)) }
            readingLine = defaults.string(forKey: "reconstructed.prompter.line") == "Middle" ? "Middle" : "Upper"
            mirrored = defaults.bool(forKey: "reconstructed.prompter.mirror")
        }
    }
    deinit { timer?.invalidate() }
    private func save() {
        guard persists else { return }
        let d = UserDefaults.standard
        d.set(script, forKey:"reconstructed.prompter.script"); d.set(wpm, forKey:"reconstructed.prompter.wpm")
        d.set(textSize,forKey:"reconstructed.prompter.size"); d.set(readingLine,forKey:"reconstructed.prompter.line"); d.set(mirrored,forKey:"reconstructed.prompter.mirror")
    }
    func toggle() {
        switch phase {
        case .running, .counting: pausedFrom = phase; phase = .paused; stopTimer()
        case .paused: phase = pausedFrom; beginTimer()
        case .idle, .ended:
            guard !parsed.words.isEmpty else { return }
            elapsed = 0; countdown = 3; phase = .counting; beginTimer()
        }
    }
    func reset() { elapsed = 0; countdown = 3; phase = .idle; stopTimer() }
    func replay() { reset(); toggle() }
    func jump(to section: PrompterScript.Section) {
        let ends = parsed.ends(wpm:wpm)
        elapsed = section.firstWord == 0 ? 0 : ends[min(section.firstWord,ends.count) - 1]
        if phase == .idle || phase == .ended { phase = .paused; pausedFrom = .running }
    }
    func advance(delta: Double) {
        guard delta.isFinite, delta > 0 else { return }
        var remaining = delta
        if phase == .counting {
            let consumed = min(remaining,countdown); countdown -= consumed; remaining -= consumed
            if countdown <= 0 { phase = .running }
        }
        if phase == .running {
            elapsed = min(duration,elapsed + remaining)
            if elapsed >= duration { phase = .ended; stopTimer() }
        }
    }
    private func beginTimer() {
        stopTimer(); guard usesTimer else { return }; lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; let now = Date(); let delta = now.timeIntervalSince(self.lastTick); self.lastTick = now; self.advance(delta:delta)
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    func importScript(_ url: URL) {
        guard ["txt","md"].contains(url.pathExtension.lowercased()) else { importError = "Choose a .txt or .md script."; return }
        do {
            let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { importError = "Choose a script smaller than 2 MB."; return }
            script = try String(contentsOf:url,encoding:.utf8); importError = nil
        } catch { importError = "The script could not be read: \(error.localizedDescription)" }
    }
    static func runSelfTest() throws {
        func check(_ condition: Bool,_ message: String) throws { if !condition { throw NSError(domain:"PrompterSelfTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) } }
        let parsed = PrompterScript("# First\none **two** [pause] [slow] three [fast] four\n# End\nfive")
        try check(parsed.words.count == 5 && parsed.sections.count == 2,"Script parser lost words or headings")
        try check(parsed.words[1].bold && !parsed.words[2].bold,"Emphasis state leaked")
        try check(parsed.words[2].delay == 1 && parsed.words[2].rate == 0.75 && parsed.words[3].rate == 1.25,"Marker semantics failed")
        let controller = PrompterController(persist:false,usesTimer:false)
        controller.wpm = -10; try check(controller.wpm == 60,"Minimum pace normalization failed")
        controller.wpm = .infinity; try check(controller.wpm == 140,"Nonfinite pace normalization failed")
        controller.wpm = 500; try check(controller.wpm == 300,"Maximum pace normalization failed")
        controller.script = "one two"; controller.wpm = 120; controller.toggle(); controller.advance(delta:2)
        try check(controller.phase == .counting && controller.countdown == 1,"Countdown failed")
        controller.toggle(); controller.advance(delta:10)
        try check(controller.phase == .paused && controller.elapsed == 0,"Paused timer advanced")
        controller.toggle(); controller.advance(delta:1.5)
        try check(controller.phase == .running && controller.elapsed == 0.5 && controller.activeWord == 1,"Countdown overflow or word progression failed")
        controller.advance(delta:1)
        try check(controller.phase == .ended && controller.elapsed == 1,"Completion failed")
        controller.reset(); try check(controller.phase == .idle && controller.elapsed == 0,"Reset failed")
        controller.script = "# Only a heading"; controller.toggle(); try check(controller.phase == .idle,"Empty script started")
    }
}

private struct PrompterScriptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView(); let editor = scroll.documentView as! NSTextView
        editor.delegate = context.coordinator; editor.isRichText = false; editor.font = .systemFont(ofSize:13)
        editor.textColor = .init(white:0.9,alpha:1); editor.backgroundColor = .init(white:0.075,alpha:1)
        editor.textContainerInset = NSSize(width:12,height:12); editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = scroll.documentView as! NSTextView
        if editor.string != text { editor.string = text }
        let count = (text as NSString).length
        let safe = NSRange(location:min(selection.location,count),length:min(selection.length,max(0,count-selection.location)))
        if editor.selectedRange() != safe { editor.setSelectedRange(safe) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PrompterScriptEditor
        init(_ parent: PrompterScriptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string; parent.selection = view.selectedRange() } }
        func textViewDidChangeSelection(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.selection = view.selectedRange() } }
    }
}

private typealias PrompterState<Value> = SwiftUI.State<Value>
struct PrompterView: View {
    @ObservedObject var model: StudioModel
    var body: some View { PrompterPanel(controller:model.prompter) }
}
private struct PrompterPanel: View {
    @ObservedObject var controller: PrompterController
    @PrompterState private var selection = NSRange(location:0,length:0)
    @PrompterState private var importer = false
    private func insert(_ prefix: String,_ suffix: String = "") {
        let source = controller.script as NSString
        let range = NSIntersectionRange(selection,NSRange(location:0,length:source.length))
        let replacement = prefix + source.substring(with:range) + suffix
        controller.script = source.replacingCharacters(in:range,with:replacement)
        selection = NSRange(location:range.location + (replacement as NSString).length,length:0)
    }
    private func time(_ value:Double)->String { let n = Int(max(0,value)); return String(format:"%d:%02d",n/60,n%60) }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:5) {
                Button("Section") { insert("\n# ") }.help("Start a new section")
                Button("Pause") { insert(" [pause] ") }.help("Mark a beat")
                Button("Slow") { insert(" [slow] ") }.contextMenu { Button("Fast") { insert(" [fast] ") } }
                Button("Bold") { insert("**","**") }.help("Emphasise the selection")
                Button("Import…") { importer = true }
            }.controlSize(.small).buttonStyle(.borderless).fixedSize(horizontal:true,vertical:false).disabled(controller.isReading)
            if controller.isReading { reader } else {
                PrompterScriptEditor(text:$controller.script,selection:$selection)
                    .clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.1)))
            }
            HStack {
                Text("\(controller.parsed.words.count) words · ≈ \(time(controller.duration)) at \(Int(controller.wpm)) wpm")
                Spacer(); Text("\(controller.parsed.sections.count) sections")
            }.font(.system(size:9)).foregroundStyle(.secondary)
            HStack {
                Stepper(value:$controller.wpm,in:60...300,step:5) { Text("\(Int(controller.wpm)) wpm").monospacedDigit() }
                Spacer()
                Menu { Picker("Size",selection:$controller.textSize) { Text("Small").tag(18.0); Text("Medium").tag(24.0); Text("Large").tag(32.0) }; Picker("Reading line",selection:$controller.readingLine) { Text("Upper").tag("Upper");Text("Middle").tag("Middle") }; Toggle("Mirror",isOn:$controller.mirrored) } label: { Image(systemName:"textformat.size") }.help("Text size, reading line and mirror")
            }.font(.system(size:11)).controlSize(.small)
            if let error = controller.importError { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Text(controller.status).font(.system(size:10)); Spacer()
                Text("\(time(controller.elapsed)) / \(time(controller.duration))").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing:8) {
                Button { controller.toggle() } label: {
                    Label(controller.phase == .running || controller.phase == .counting ? "Pause" : controller.phase == .paused ? "Resume" : controller.phase == .ended ? "Replay" : "Start prompter",systemImage:controller.phase == .running || controller.phase == .counting ? "pause.fill":"play.fill").frame(maxWidth:.infinity)
                }.keyboardShortcut("p",modifiers:[.option,.command]).disabled(controller.parsed.words.isEmpty)
                Button { controller.replay() } label: { Image(systemName:"arrow.counterclockwise") }.help("Back to the top").disabled(!controller.isReading)
                Button { controller.reset() } label: { Image(systemName:"stop.fill") }.help("Close the prompter").disabled(!controller.isReading)
            }.controlSize(.large)
        }.padding(14)
        .fileImporter(isPresented:$importer,allowedContentTypes:[.plainText,.init(filenameExtension:"md") ?? .plainText]) { result in
            switch result { case .success(let url): let access=url.startAccessingSecurityScopedResource(); defer { if access {url.stopAccessingSecurityScopedResource()} }; controller.importScript(url)
            case .failure(let error): controller.importError=error.localizedDescription }
        }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { providers in
            guard let item=providers.first else { return false }
            item.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { value,_ in
                if let data=value as? Data,let url=URL(dataRepresentation:data,relativeTo:nil) { Task { @MainActor in controller.importScript(url) } }
            }; return true
        }
    }
    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Color.clear.frame(height:controller.readingLine == "Middle" ? 180:40)
                    ForEach(0..<max(1,controller.parsed.sections.count),id:\.self) { sectionIndex in
                        VStack(alignment:.leading,spacing:10) {
                            if let section = controller.parsed.sections.first(where:{$0.id == sectionIndex}) {
                                Button(section.title) { controller.jump(to:section) }.font(.system(size:14,weight:.bold)).foregroundStyle(.yellow).buttonStyle(.plain)
                            }
                            PrompterWordFlow(spacing:5) {
                                ForEach(controller.parsed.words.filter {$0.section == sectionIndex}) { word in
                                    Text(word.text).font(.system(size:controller.textSize,weight:word.bold ? .bold:.medium))
                                        .foregroundStyle(word.id < controller.activeWord ? .white.opacity(0.35):.white)
                                        .padding(.horizontal,2).padding(.vertical,3)
                                        .background(word.id == controller.activeWord ? Color.yellow.opacity(0.22):.clear)
                                        .id(word.id)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height:240)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
            }.scaleEffect(x:controller.mirrored ? -1:1,y:1)
            .onChange(of:controller.activeWord) { _,value in withAnimation(.linear(duration:0.15)) { proxy.scrollTo(value,anchor:controller.readingLine == "Middle" ? .center:.top) } }
        }.background(Color.black.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius:8))
    }
}

/// Wrap individual words while retaining a stable scroll target and emphasis per token.
private struct PrompterWordFlow: Layout {
    var spacing: CGFloat
    private func positions(_ views: Subviews,_ width: CGFloat) -> ([CGPoint],CGFloat) {
        var points:[CGPoint]=[], x:CGFloat=0, y:CGFloat=0, row:CGFloat=0
        for view in views {
            let size=view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x=0; y += row + spacing; row=0 }
            points.append(CGPoint(x:x,y:y)); x += size.width + spacing; row=max(row,size.height)
        }
        return (points,y + row)
    }
    func sizeThatFits(proposal: ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        let width=proposal.width ?? 260
        return CGSize(width:width,height:positions(subviews,width).1)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let points=positions(subviews,bounds.width).0
        for (index,view) in subviews.enumerated() {
            view.place(at:CGPoint(x:bounds.minX+points[index].x,y:bounds.minY+points[index].y),proposal:.unspecified)
        }
    }
}
