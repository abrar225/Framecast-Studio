@main struct StreamSelfTest {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let stream = StreamPipe()
        var settings = StreamEncodingSettings()
        if ProcessInfo.processInfo.environment["FRAMECAST_STREAM_ENCODER"] == "software" { settings.encoder = .software }
        try stream.start(executable: CommandLine.arguments[1], destination: output.path, width: 320, height: 180, fps: 30, settings: settings)
        let video = Data(repeating: 80, count: 320 * 180 * 4)
        var audio = Data(count: 1600 * 4)
        for frame in 0..<100 {
            audio.withUnsafeMutableBytes { bytes in
                let samples = bytes.bindMemory(to: Int16.self)
                for index in samples.indices { samples[index] = Int16(sin(Double(frame * 1600 + index / 2) * 440 * 2 * Double.pi / 48000) * 8000) }
            }
            if frame % 3 == 0 { stream.send(video) } // Deliberately skip2/3 video submissions.
            stream.sendAudio(audio)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        stream.stop()
        for _ in 0..<40 { if !stream.process.isRunning { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        guard !stream.process.isRunning else { fatalError("FFmpeg did not stop") }
        if let failure = stream.failure { fputs("Encoder diagnostic: \(stream.diagnosticText)\n", stderr); throw failure }
        print("PASS bounded raw video + private FIFO synthetic PCM; FFmpeg process stopped")
        print("Output: \(output.path)")
        try await MediaEngine.runPinnedCanvasStreamTest(executable:CommandLine.arguments[1],output:output.deletingPathExtension().appendingPathExtension("canvas.flv"),settings:settings)
    }
}

extension MediaEngine {
    @MainActor static func runPinnedCanvasStreamTest(executable:String,output:URL,settings:StreamEncodingSettings) async throws {
        let engine=MediaEngine();engine.microphoneEnabled=true;engine.capturedAudioEnabled=true;engine.microphoneGain=0.5;engine.capturedAudioGain=0.25
        defer{engine.stopAll()}
        let pipe=StreamPipe()
        try pipe.start(executable:executable,destination:output.path,width:320,height:180,fps:30,settings:settings)
        var horizontal=RenderConfiguration(backgroundHex:"FF0000",width:320,height:180,vertical:false)
        let portrait=RenderConfiguration(backgroundHex:"0000FF",width:180,height:320,vertical:true)
        engine.setCompositions(horizontal,secondary:portrait)
        engine.streamConfiguration=horizontal;engine.streamWidth=320;engine.streamHeight=180;engine.streamFPS=30
        engine.audioMixer.start(at:CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        engine.streamPipe=pipe;engine.streaming=true;engine.lastStreamTime=0
        for frame in 0..<100 {
            if frame==30 {horizontal.backgroundHex="00FF00";engine.setCompositions(portrait,secondary:horizontal)}
            if frame==60 {engine.setCompositions(portrait,secondary:nil)}
            let host=CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let mic=(0..<1470).map { Float(sin(Double(frame*1470+$0)*440*2*Double.pi/44100)*0.4) }
            let captured=(0..<1470).flatMap { index -> [Float] in
                let value=Float(sin(Double(frame*1470+index)*880*2*Double.pi/44100)*0.4)
                return [value,-value]
            }
            engine.audioMixer.insert(AudioPacket(hostTime:host,rate:44100,channels:1,samples:mic),input:.microphone)
            engine.audioMixer.insert(AudioPacket(hostTime:host,rate:44100,channels:2,samples:captured),input:.captured)
            try await Task.sleep(nanoseconds:33_333_333)
        }
        engine.stopStreaming()
        for _ in 0..<60 {if !pipe.process.isRunning{break};try await Task.sleep(nanoseconds:50_000_000)}
        guard !pipe.process.isRunning else {throw EngineError.message("Pinned-canvas stream did not finalize")}
        if let failure = pipe.failure { fputs("Encoder diagnostic: \(pipe.diagnosticText)\n", stderr); throw failure }
        print("PASS local engine stream finalizes after editing-canvas switch and horizontal-preview removal")
    }
}
