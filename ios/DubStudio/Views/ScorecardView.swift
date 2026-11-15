import SwiftUI

/// Count-up reveal of timing → emotion → comedy → overall, then the roast types out,
/// then the timing bar sweeps in. Fallback scorecards ("coffee break") get the same polish.
struct ScorecardView: View {
    let result: TakeResult
    let clip: Clip
    let localSegments: [TimeWindow]

    @State private var shown: [Int] = [0, 0, 0, 0]
    @State private var revealed = -1          // index of the tile currently counting / done
    @State private var roastText = ""
    @State private var barReveal: Double = 0
    @State private var started = false

    private var accent: Color { result.isNoAudio ? Theme.danger : result.isFallback ? Theme.coffee : Theme.gold }
    private var judgeCaption: String? { result.isNoAudio ? "Nothing to judge" : result.isFallback ? "Judge on break" : nil }

    var body: some View {
        Card(accent: accent) {
            VStack(alignment: .leading, spacing: 22) {
                header

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ScoreTile(title: "Timing", value: shown[0], max: 100, icon: "metronome.fill",
                              caption: "Measured by code against the character's lines", accent: accent, active: revealed >= 0)
                    ScoreTile(title: "Emotion", value: shown[1], max: 10, icon: "theatermasks.fill",
                              caption: judgeCaption ?? result.emotionReason, accent: accent, active: revealed >= 1)
                    ScoreTile(title: "Comedy", value: shown[2], max: 10, icon: "face.smiling.inverse",
                              caption: judgeCaption ?? result.comedyReason, accent: accent, active: revealed >= 2)
                    ScoreTile(title: "Overall", value: shown[3], max: 100, icon: "star.fill",
                              caption: "Half timing, half the judges' taste", accent: accent, active: revealed >= 3, big: true)
                }

                RoastBubble(text: roastText, accent: accent,
                            icon: result.isNoAudio ? "mic.slash.fill" : result.isFallback ? "cup.and.saucer.fill" : "quote.opening")
                    .opacity(revealed >= 4 ? 1 : 0)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Your timing").font(Theme.body(15, weight: .semibold)).foregroundStyle(accent)
                    TimingBarView(duration: clip.duration,
                                  speechWindows: result.speechWindows.isEmpty ? clip.speechWindows : result.speechWindows,
                                  playerSegments: result.vadSegments.isEmpty ? localSegments : result.vadSegments,
                                  reveal: barReveal)
                }
                .opacity(revealed >= 4 ? 1 : 0)
            }
        }
        .task {
            guard !started else { return }
            started = true
            await runReveal()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: result.isNoAudio ? "mic.slash.fill" : result.isFallback ? "cup.and.saucer.fill" : "rosette")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.isNoAudio ? "We couldn't hear you" : result.isFallback ? "Judges on a coffee break" : "The verdict")
                    .font(Theme.display(34))
                    .foregroundStyle(Theme.textPrimary)
                Text(result.isNoAudio
                     ? "The mic picked up silence. Speak up (or check the mic) and hit Retake."
                     : result.isFallback
                     ? "Your timing is real. The taste scores are a stand-in until the judges are back."
                     : "Timing by code. Taste by the AI judges.")
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func runReveal() async {
        let targets = [result.timing, result.emotion, result.comedy, result.overall]
        for i in 0..<4 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { revealed = i }
            await countUp(index: i, to: targets[i], duration: i == 3 ? 1.2 : 0.8)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        withAnimation(.easeOut(duration: 0.3)) { revealed = 4 }
        for ch in result.roast {
            roastText.append(ch)
            try? await Task.sleep(nanoseconds: 28_000_000)
        }
        withAnimation(.easeInOut(duration: 1.2)) { barReveal = 1 }
    }

    private func countUp(index: Int, to target: Int, duration: Double) async {
        guard target > 0 else { shown[index] = 0; return }
        let steps = min(target, 40)
        for s in 1...steps {
            shown[index] = Int((Double(target) * Double(s) / Double(steps)).rounded())
            try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1e9))
        }
        shown[index] = target
    }
}

private struct ScoreTile: View {
    let title: String
    let value: Int
    let max: Int
    let icon: String
    let caption: String
    let accent: Color
    let active: Bool
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(Theme.body(15, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(accent)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(Theme.display(54))   // same size in every tile so all four tiles match
                    .monospacedDigit()
                    .foregroundStyle(big ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.textPrimary))
                    .contentTransition(.numericText())
                Text("/\(max)").font(Theme.body(18, weight: .bold)).foregroundStyle(Theme.textSecondary)
            }
            Text(caption)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3, reservesSpace: true)   // every tile reserves 3 lines: equal heights
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(big ? accent.opacity(0.12) : Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(active ? 0.7 : 0.1), lineWidth: active ? 2 : 1))
        .opacity(active ? 1 : 0.35)
        .scaleEffect(active ? 1 : 0.96)
        .accessibilityElement(children: .combine)
    }
}

/// Speech bubble for the roast, with a tail pointing at the judges.
private struct RoastBubble: View {
    let text: String
    let accent: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(accent)
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 24, weight: .bold, design: .serif).italic())
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 22).fill(Theme.spotlight))
            BubbleTail()
                .fill(Theme.spotlight)
                .frame(width: 30, height: 18)
                .padding(.leading, 36)
        }
        .shadow(color: accent.opacity(0.35), radius: 16)
    }
}

private struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.2, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
