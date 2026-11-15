import SwiftUI
import AVFoundation

/// Bare AVPlayerLayer (no system controls) so the stage look stays consistent.
struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Framed "screen on stage" for video.
struct StageScreen<Content: View>: View {
    var glow: Color = Theme.gold
    @ViewBuilder var content: Content
    var body: some View {
        content
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(glow.opacity(0.5), lineWidth: 2))
    }
}

/// Live mic level meter: a row of bars that light up gold→red.
struct LevelMeter: View {
    var level: Float          // 0...1
    var speaking: Bool
    var bars = 24

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Float(i) / Float(bars)
                let lit = level > threshold
                RoundedRectangle(cornerRadius: 3)
                    .fill(lit ? color(for: i) : Theme.surfaceRaised)
                    .frame(width: 10, height: 14 + CGFloat(i) * 1.6)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .overlay(alignment: .leading) {
            Image(systemName: speaking ? "waveform" : "mic.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(speaking ? Theme.you : Theme.textSecondary)
                .offset(x: -36)
        }
        .accessibilityLabel(speaking ? "Hearing you" : "Microphone level")
    }

    private func color(for i: Int) -> Color {
        let f = Double(i) / Double(bars)
        if f > 0.85 { return Theme.danger }
        if f > 0.6 { return Theme.gold }
        return Theme.you
    }
}

/// Timing bar: the character's speech windows (gold) above the player's VAD segments (teal),
/// both on a 0...duration track. Optionally with a playhead (record screen) and reveal animation.
struct TimingBarView: View {
    var duration: Double
    var speechWindows: [TimeWindow]
    var playerSegments: [TimeWindow]
    var playhead: Double? = nil
    var reveal: Double = 1          // 0...1, sweeps left→right
    var showLabels = true
    var playerColor: Color = Theme.you

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            lane(label: "Character", windows: speechWindows, color: Theme.gold)
            if playhead == nil || !playerSegments.isEmpty {
                lane(label: "You", windows: playerSegments, color: playerColor)
            }
        }
    }

    private func lane(label: String, windows: [TimeWindow], color: Color) -> some View {
        HStack(spacing: 12) {
            if showLabels {
                Text(label)
                    .font(Theme.body(13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(color)
                    .frame(width: 84, alignment: .trailing)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceRaised)
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, win in
                        let x = w * CGFloat(max(0, win.start) / max(duration, 0.01))
                        let ww = w * CGFloat(win.length / max(duration, 0.01))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color)
                            .frame(width: max(3, ww), height: geo.size.height)
                            .offset(x: x)
                            .shadow(color: color.opacity(0.6), radius: 6)
                    }
                    if let playhead {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 3, height: geo.size.height + 10)
                            .offset(x: w * CGFloat(min(1, max(0, playhead / max(duration, 0.01)))) - 1.5)
                    }
                }
                .mask(alignment: .leading) {
                    Rectangle().frame(width: w * CGFloat(reveal))
                }
            }
            .frame(height: 22)
        }
    }
}

/// Section header with marquee font.
struct StageTitle: View {
    var text: String
    var size: CGFloat = 44
    var body: some View {
        Text(text)
            .font(Theme.display(size))
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Small helper to format seconds as "0:12".
func formatSeconds(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    return "\(t / 60):" + String(format: "%02d", t % 60)
}
