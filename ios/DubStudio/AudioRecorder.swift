import AVFoundation
import Combine

enum RecorderError: LocalizedError {
    case noMicrophone
    case permissionDenied
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone is available on this device."
        case .permissionDenied: return "LARPStudio needs microphone access. Enable it in Settings > LARPStudio."
        case .notPrepared: return "The recorder wasn't ready."
        }
    }
}

/// AVAudioEngine-based recorder:
/// - voice processing (echo cancellation + noise suppression) ON, AGC OFF
/// - live level meter
/// - starts capturing at a shared host time and drops the leading
///   `inputLatency + ioBufferDuration` worth of samples so t=0 == clip t=0
/// - runs the RMS VAD on the same samples → speech segments in clip time
/// - writes mono AAC (.m4a)
final class AudioRecorder: ObservableObject {
    @Published private(set) var level: Float = 0          // 0...1 (−60 dBFS ... 0 dBFS)
    @Published private(set) var isSpeaking = false
    @Published private(set) var isCapturing = false
    @Published private(set) var voiceProcessingOn = false

    private var engine: AVAudioEngine?
    private let lock = NSLock()

    // Capture state. Guarded by `lock` (touched from the tap thread and main).
    private var capturing = false
    private var file: AVAudioFile?
    private var buffersSkipped = 0
    private var peak: Float = 0
    private var tapBuffers = 0          // all tap callbacks since prepare()
    private var tapBuffersCapturing = 0 // tap callbacks while capturing
    private var lastTapHost: Double = 0
    private var configObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private var restarts = 0
    private var loggedFirstWrite = false
    private var monoFormat: AVAudioFormat?
    private var startHostSeconds: Double = 0
    private var latency: Double = 0
    private var targetFrames: AVAudioFramePosition = 0
    private var framesWritten: AVAudioFramePosition = 0
    private var vad: EnergyVAD?
    private var outputURL: URL?
    private var duration: Double = 0
    private var inputRoute = ""
    private var completion: ((Result<Recording, Error>) -> Void)?

    deinit { engine?.stop() }

    /// Starts the engine (meter only). Call before the countdown so the meter is live.
    static let teardownQueue = DispatchQueue(label: "dubstudio.audio.teardown")

    func prepare() throws {
        stopEngine()
        Self.teardownQueue.sync {} // never run two voice-processing engines at once
        let engine = AVAudioEngine()
        let input = engine.inputNode

        var vpOn = false
        // Voice processing (echo cancel + noise suppression) only when sound comes out of the iPad
        // speaker. With headphones there's no echo, and VP would force Bluetooth off A2DP.
        let useVP = !AudioSessionManager.shared.headphonesConnected
        dlog("REC voice processing \(useVP ? "ON (speaker)" : "OFF (headphones connected)")")
        do {
            guard useVP else { throw RecorderError.noMicrophone }   // skip to the no-VP path
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = false   // AGC flattens dramatic screams
            vpOn = true
            // Don't let voice processing duck the (muted) clip or anything else.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            // Simulator / unsupported route: record without voice processing.
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecorderError.noMicrophone }
        _ = engine.mainMixerNode // voice-processing IO needs an output side in the graph

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.handle(buffer: buffer, time: time)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        lock.lock(); tapBuffers = 0; tapBuffersCapturing = 0; restarts = 0; lock.unlock()
        // Starting the clip's AVPlayer (or a route change) can reconfigure the audio hardware, which
        // silently STOPS the engine: the tap then delivers nothing and the take is empty. Restart it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            dlog("REC ⚠️ engine configuration changed (running=\(engine.isRunning)) -> restarting")
            self?.restartEngine()
        }
        dlog("REC prepare: voiceProcessing=\(vpOn), inputFormat=\(format)")
        DispatchQueue.main.async { self.voiceProcessingOn = vpOn }
    }

    /// Begin capturing so that the first written sample corresponds to `hostTime`
    /// (the same host time the AVPlayer starts at).
    func beginRecording(atHostTime hostTime: UInt64, duration: Double, inputRoute: String,
                        completion: @escaping (Result<Recording, Error>) -> Void) throws {
        guard let engine else { throw RecorderError.notPrepared }
        let sr = engine.inputNode.outputFormat(forBus: 0).sampleRate
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false) else {
            throw RecorderError.noMicrophone
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let session = AVAudioSession.sharedInstance()

        lock.lock()
        self.file = file
        self.monoFormat = mono
        self.outputURL = url
        self.duration = duration
        self.inputRoute = inputRoute
        self.startHostSeconds = AVAudioTime.seconds(forHostTime: hostTime)
        // Built-in mic input latency + one IO buffer. Bluetooth output latency is NOT included:
        // the clip is muted and shown on screen, not heard.
        self.latency = session.inputLatency + session.ioBufferDuration
        self.targetFrames = AVAudioFramePosition((duration * sr).rounded())
        self.framesWritten = 0
        self.vad = EnergyVAD(sampleRate: sr)
        self.completion = completion
        self.capturing = true
        self.buffersSkipped = 0
        self.peak = 0
        self.loggedFirstWrite = false
        lock.unlock()
        if !engine.isRunning {
            dlog("REC ⚠️ engine was stopped at begin -> restarting")
            restartEngine()
        }
        startWatchdog()
        let nowHost = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        dlog("REC begin: sr=\(Int(sr)) Hz, route=\(inputRoute), inputLatency=\(String(format: "%.3f", session.inputLatency)) s, ioBuffer=\(String(format: "%.3f", session.ioBufferDuration)) s, start in \(String(format: "%.3f", AVAudioTime.seconds(forHostTime: hostTime) - nowHost)) s, duration=\(String(format: "%.2f", duration)) s, targetFrames=\(targetFrames)")
        dlog("REC file: \(url.lastPathComponent)")
        DispatchQueue.main.async { self.isCapturing = true }
    }

    /// Stop early (cancel or the player ended first). Finalizes whatever was captured.
    func finishNow() {
        lock.lock()
        let wasCapturing = capturing
        dlog("REC finishNow (capturing=\(wasCapturing), framesWritten=\(framesWritten))")
        if wasCapturing || completion != nil { finalizeLocked() }
        lock.unlock()
    }

    /// (Re)start the engine; the tap stays installed on the input node.
    private func restartEngine() {
        guard let engine else { return }
        lock.lock(); restarts += 1; lock.unlock()
        if engine.isRunning { engine.stop() }
        engine.prepare()
        do { try engine.start(); dlog("REC engine restarted (running=\(engine.isRunning))") }
        catch { dlog("REC ⚠️ engine restart FAILED: \(error)") }
    }

    /// While capturing, if the tap goes quiet for 0.5 s the engine has stalled: restart it.
    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let capturing = self.capturing, last = self.lastTapHost, restarts = self.restarts
            self.lock.unlock()
            guard capturing else { self.watchdog?.cancel(); self.watchdog = nil; return }
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            if last <= 0 || now - last > 0.5, restarts < 5 {
                dlog("REC ⚠️ no mic buffers for \(last <= 0 ? "ever" : String(format: "%.2f s", now - last)) -> restarting engine")
                self.lock.lock(); self.lastTapHost = now; self.lock.unlock() // give the restart time
                self.restartEngine()
            }
        }
        t.resume()
        watchdog = t
    }

    /// Cancel without delivering a recording.
    func cancel() {
        lock.lock()
        capturing = false
        completion = nil
        file = nil
        lock.unlock()
        stopEngine()
    }

    func stopEngine() {
        dlog("REC stopEngine begin")
        defer { dlog("REC stopEngine done") }
        watchdog?.cancel(); watchdog = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        // Tear the engine down OFF the main thread: on a real iPad, stopping a voice-processing
        // engine can block for a long time, which froze the UI on "That's a wrap!".
        // (We also no longer switch voice processing back off; releasing the engine is enough.)
        if let old = engine {
            engine = nil
            Self.teardownQueue.async {
                let t0 = Date()
                old.inputNode.removeTap(onBus: 0)
                old.stop()
                dlog("REC engine torn down in background (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
            }
        }
        DispatchQueue.main.async {
            self.level = 0
            self.isSpeaking = false
            self.isCapturing = false
        }
    }

    // MARK: - Tap

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let sr = buffer.format.sampleRate

        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let norm = max(0, min(1, (db + 60) / 60))

        lock.lock()
        tapBuffers += 1
        lastTapHost = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : -1
        if capturing { tapBuffersCapturing += 1; write(channel: channel, count: n, sampleRate: sr, time: time) }
        let speaking = capturing ? (vad?.isSpeaking ?? false) : db > -40
        lock.unlock()

        DispatchQueue.main.async {
            self.level = norm
            self.isSpeaking = speaking
        }
    }

    /// Called with `lock` held.
    private func write(channel: UnsafeMutablePointer<Float>, count n: Int, sampleRate sr: Double, time: AVAudioTime) {
        guard let file, let monoFormat else {
            if tapBuffersCapturing == 1 { dlog("REC ⚠️ write skipped: file=\(self.file != nil) monoFormat=\(self.monoFormat != nil)") }
            return
        }
        if tapBuffersCapturing == 1 {
            dlog("REC first capture buffer: n=\(n), bufferFormat=\(Int(sr)) Hz, hostTimeValid=\(time.isHostTimeValid), hostT=\(String(format: "%.3f", time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : -1)), start=\(String(format: "%.3f", startHostSeconds)), latency=\(String(format: "%.3f", latency))")
        }
        let bufferHost: Double
        if time.isHostTimeValid {
            bufferHost = AVAudioTime.seconds(forHostTime: time.hostTime)
        } else {
            bufferHost = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - Double(n) / sr
        }
        // Clip time (seconds) of this buffer's first sample, latency-compensated.
        let clipT0 = bufferHost - latency - startHostSeconds

        var startIdx = 0
        if framesWritten == 0 {
            if clipT0 + Double(n) / sr <= 0 { buffersSkipped += 1; return }  // entirely before clip t=0
            if !loggedFirstWrite {
                loggedFirstWrite = true
                dlog("REC first buffer: clipT0=\(String(format: "%.3f", clipT0)) s, n=\(n), bufferSR=\(Int(sr)), hostTimeValid=\(time.isHostTimeValid), skippedBefore=\(buffersSkipped)")
            }
            if clipT0 < 0 {
                startIdx = min(n, Int((-clipT0 * sr).rounded()))     // trim leading samples
            } else if clipT0 > 0 {
                // First buffer arrived after t=0: pad with silence so alignment holds.
                let pad = min(Int((clipT0 * sr).rounded()), Int(targetFrames))
                if pad > 0, let silence = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(pad)) {
                    silence.frameLength = AVAudioFrameCount(pad)
                    memset(silence.floatChannelData![0], 0, pad * MemoryLayout<Float>.size)
                    try? file.write(from: silence)
                    vad?.processSilence(count: pad)
                    framesWritten += AVAudioFramePosition(pad)
                }
            }
        }

        else {
            let gap = Int((clipT0 * sr).rounded()) - Int(framesWritten)
            if gap > Int(0.1 * sr) {
                let pad = min(gap, Int(targetFrames - framesWritten))
                if pad > 0, let silence = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(pad)) {
                    silence.frameLength = AVAudioFrameCount(pad)
                    memset(silence.floatChannelData![0], 0, pad * MemoryLayout<Float>.size)
                    try? file.write(from: silence)
                    vad?.processSilence(count: pad)
                    framesWritten += AVAudioFramePosition(pad)
                    dlog("REC padded \(String(format: "%.2f", Double(pad) / sr)) s gap of silence to keep sync")
                }
            }
        }

        let remaining = Int(targetFrames - framesWritten)
        let count = min(n - startIdx, remaining)
        if count > 0, let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(count)) {
            out.frameLength = AVAudioFrameCount(count)
            memcpy(out.floatChannelData![0], channel.advanced(by: startIdx), count * MemoryLayout<Float>.size)
            do { try file.write(from: out) } catch { dlog("REC write FAILED: \(error)") }
            let src = channel.advanced(by: startIdx)
            for i in 0..<count { peak = max(peak, abs(src[i])) }
            vad?.process(UnsafeBufferPointer(start: channel.advanced(by: startIdx), count: count))
            framesWritten += AVAudioFramePosition(count)
        }
        if framesWritten >= targetFrames { finalizeLocked() }
    }

    /// Called with `lock` held. Closes the file and delivers the recording on main.
    private func finalizeLocked() {
        capturing = false
        file = nil // releasing AVAudioFile flushes and closes the AAC file
        let segments = vad?.finish() ?? []
        let sr = monoFormat?.sampleRate ?? 48_000
        let captured = Double(framesWritten) / sr
        let fileBytes = outputURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? -1
        dlog("REC tap stats: total=\(tapBuffers), whileCapturing=\(tapBuffersCapturing), lastTapHost=\(String(format: "%.3f", lastTapHost)), now=\(String(format: "%.3f", AVAudioTime.seconds(forHostTime: mach_absolute_time())))")
        dlog("REC finalize: framesWritten=\(framesWritten)/\(targetFrames) (\(String(format: "%.2f", captured)) s), buffersSkipped=\(buffersSkipped), fileBytes(before close)=\(fileBytes), vadSegments=\(segments.count): \(segments.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: ", "))")
        if framesWritten == 0 { dlog("REC ⚠️ NO AUDIO WRITTEN: every buffer was before clip t=0 or capture stopped early") }
        let peakDB = framesWritten > 0 ? Double(20 * log10(max(peak, 1e-6))) : -120
        dlog("REC peak level: \(String(format: "%.1f", peakDB)) dBFS\(peakDB < -45 ? "  ⚠️ basically silent" : "")")
        let rec = outputURL.map {
            Recording(audioURL: $0, vadSegments: segments, duration: captured,
                      latencyCompensation: latency, inputRoute: inputRoute, peakDB: peakDB)
        }
        let done = completion
        completion = nil
        DispatchQueue.main.async {
            if let rec { done?(.success(rec)) } else { done?(.failure(RecorderError.notPrepared)) }
            self.stopEngine()
        }
    }
}
