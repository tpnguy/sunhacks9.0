import XCTest
@testable import DubStudio

final class VADTests: XCTestCase {
    let sr = 48_000.0

    /// Low noise everywhere, with a 220 Hz tone (amplitude `amp`) inside the given windows.
    func synth(duration: Double, bursts: [TimeWindow], amp: Float = 0.3, noise: Float = 0.001) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        let n = Int(duration * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            var s = Float.random(in: -noise...noise, using: &rng)
            if bursts.contains(where: { t >= $0.start && t < $0.end }) {
                s += amp * Float(sin(2 * .pi * 220 * t))
            }
            out[i] = s
        }
        return out
    }

    func run(_ samples: [Float], chunk: Int = 4800) -> [TimeWindow] {
        var vad = EnergyVAD(sampleRate: sr)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + chunk)
            vad.process(Array(samples[i..<end]))
            i = end
        }
        return vad.finish()
    }

    func testSilenceHasNoSegments() {
        XCTAssertTrue(run(synth(duration: 3, bursts: [])).isEmpty)
    }

    func testSingleBurstDetected() {
        let segs = run(synth(duration: 4, bursts: [TimeWindow(start: 1.0, end: 2.5)]))
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 1.0, accuracy: 0.05)
        XCTAssertEqual(segs[0].end, 2.5, accuracy: 0.05)
    }

    func testTwoBurstsSeparatedByLongGap() {
        let segs = run(synth(duration: 6, bursts: [TimeWindow(start: 0.5, end: 1.5), TimeWindow(start: 3.0, end: 4.0)]))
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[1].start, 3.0, accuracy: 0.05)
    }

    func testShortGapIsBridgedByHangover() {
        // 150 ms pause < 300 ms min silence → one segment
        let segs = run(synth(duration: 4, bursts: [TimeWindow(start: 1.0, end: 2.0), TimeWindow(start: 2.15, end: 3.0)]))
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].end, 3.0, accuracy: 0.05)
    }

    func testClickIsIgnored() {
        // 40 ms blip is shorter than min speech (100 ms)
        XCTAssertTrue(run(synth(duration: 3, bursts: [TimeWindow(start: 1.0, end: 1.04)])).isEmpty)
    }

    func testOpenSegmentClosedAtEnd() {
        let segs = run(synth(duration: 3, bursts: [TimeWindow(start: 2.0, end: 3.0)]))
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].end, 3.0, accuracy: 0.05)
    }

    func testChunkingDoesNotMatter() {
        let s = synth(duration: 4, bursts: [TimeWindow(start: 1.0, end: 2.5)])
        let a = run(s, chunk: 333), b = run(s, chunk: 9600)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.first?.start ?? -1, b.first?.start ?? -2, accuracy: 0.001)
    }
}
