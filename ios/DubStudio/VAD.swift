import Foundation

/// RMS-energy voice activity detector with hysteresis.
///
/// Feed mono float samples (already aligned so sample 0 == clip t=0); it slices them
/// into 20 ms frames, compares each frame's level (dBFS) against an open/close
/// threshold pair, and requires a minimum run before opening or closing a segment.
/// Thresholds float above a slowly tracked noise floor so a loud hall doesn't read as speech.
struct EnergyVAD {
    struct Config {
        var frameDuration: Double = 0.020
        var openDB: Float = -42          // absolute minimum level to open a segment
        var closeDB: Float = -50         // absolute minimum level to stay open
        var openAboveFloorDB: Float = 12 // must also exceed the noise floor by this much to open
        var closeAboveFloorDB: Float = 6
        var minSpeech: Double = 0.10     // consecutive loud time before a segment opens
        var minSilence: Double = 0.30    // consecutive quiet time before a segment closes (hangover)
        var minSegment: Double = 0.15    // drop segments shorter than this
    }

    let config: Config
    let sampleRate: Double
    private let frameSize: Int
    private var pending: [Float] = []
    private var frameIndex = 0
    private var noiseFloorDB: Float = -70

    private var inSpeech = false
    private var runCount = 0          // consecutive frames contradicting the current state
    private var runStartFrame = 0
    private var segmentStartFrame = 0
    private(set) var segments: [TimeWindow] = []

    /// True while a segment is open (for the live "you're talking" indicator).
    var isSpeaking: Bool { inSpeech }

    init(sampleRate: Double, config: Config = Config()) {
        self.sampleRate = sampleRate
        self.config = config
        self.frameSize = max(1, Int((sampleRate * config.frameDuration).rounded()))
        pending.reserveCapacity(frameSize * 2)
    }

    private var minSpeechFrames: Int { max(1, Int((config.minSpeech / config.frameDuration).rounded())) }
    private var minSilenceFrames: Int { max(1, Int((config.minSilence / config.frameDuration).rounded())) }
    private func time(ofFrame f: Int) -> Double { Double(f) * Double(frameSize) / sampleRate }

    mutating func process(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            pending.append(s)
            if pending.count == frameSize {
                processFrame(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// Feeds `count` zero samples (used when the recording is padded with leading silence).
    mutating func processSilence(count: Int) {
        process([Float](repeating: 0, count: count))
    }

    private mutating func processFrame(_ frame: [Float]) {
        var sum: Float = 0
        for x in frame { sum += x * x }
        let rms = (sum / Float(frame.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))

        let openT = max(config.openDB, noiseFloorDB + config.openAboveFloorDB)
        let closeT = max(config.closeDB, noiseFloorDB + config.closeAboveFloorDB)

        if inSpeech {
            if db < closeT {
                if runCount == 0 { runStartFrame = frameIndex }
                runCount += 1
                if runCount >= minSilenceFrames {
                    closeSegment(atFrame: runStartFrame)
                }
            } else {
                runCount = 0
            }
        } else {
            // Track noise floor only while silent: fast down, slow up.
            if db < noiseFloorDB { noiseFloorDB = db } else { noiseFloorDB += (db - noiseFloorDB) * 0.02 }
            if db > openT {
                if runCount == 0 { runStartFrame = frameIndex }
                runCount += 1
                if runCount >= minSpeechFrames {
                    inSpeech = true
                    segmentStartFrame = runStartFrame
                    runCount = 0
                }
            } else {
                runCount = 0
            }
        }
        frameIndex += 1
    }

    private mutating func closeSegment(atFrame endFrame: Int) {
        let seg = TimeWindow(start: time(ofFrame: segmentStartFrame), end: time(ofFrame: endFrame))
        if seg.length >= config.minSegment { segments.append(seg) }
        inSpeech = false
        runCount = 0
    }

    /// Closes any open segment at the end of the audio and returns all segments.
    mutating func finish() -> [TimeWindow] {
        if inSpeech {
            // If we were mid-hangover, end where the silence began; otherwise at the last frame.
            closeSegment(atFrame: runCount > 0 ? runStartFrame : frameIndex)
        }
        return segments
    }
}
