import SwiftUI

/// "Talent-show stage" theme. Every screen pulls colors, fonts and button styles from here.
enum Theme {
    // MARK: Colors
    // Palette: a dubbing booth on a talent-show stage.
    //   Theatre black #000000 · Wing #1A1712 · Marquee gold #F2B632 · VU green #4CC77F
    //   Spotlight #FFF3DC · Dust #A39C8E
    static let background = Color.black                                       // theatre blacks
    static let surface = Color(red: 0.102, green: 0.090, blue: 0.071)          // #1A1712 wing
    static let surfaceRaised = Color(red: 0.149, green: 0.133, blue: 0.106)    // #26221B
    static let gold = Color(red: 0.949, green: 0.714, blue: 0.196)             // #F2B632 marquee gold (primary)
    static let goldDeep = Color(red: 0.788, green: 0.553, blue: 0.098)         // #C98D19
    static let spotlight = Color(red: 1.0, green: 0.953, blue: 0.863)          // #FFF3DC
    /// Secondary color: "on air" green. Used for the player (their speech, mic meter), secondary buttons
    /// and the soundwave. Gold stays primary (character lines, scores, main buttons).
    static let green = Color(red: 0.298, green: 0.780, blue: 0.498)            // #4CC77F VU-meter green
    static let greenDeep = Color(red: 0.180, green: 0.596, blue: 0.361)        // #2E985C
    static let you = green                                                     // player segments
    static let coffee = Color(red: 0.710, green: 0.565, blue: 0.443)           // fallback scorecard accent
    static let textPrimary = spotlight
    static let textSecondary = Color(red: 0.639, green: 0.612, blue: 0.557)    // #A39C8E dust
    static let danger = Color(red: 1.0, green: 0.408, blue: 0.408)

    static let goldGradient = LinearGradient(colors: [gold, goldDeep], startPoint: .top, endPoint: .bottom)
    static let greenGradient = LinearGradient(colors: [green, greenDeep], startPoint: .top, endPoint: .bottom)

    // MARK: Fonts
    // Type: Futura Condensed ExtraBold (film-poster display; condensed so long words fit) and
    // Avenir Next for everything you read. Monospace only for timecode. All ship with iOS.
    static func display(_ size: CGFloat) -> Font {
        .custom("Futura-CondensedExtraBold", size: size * 1.12)   // condensed face reads small; scale up
    }
    static func body(_ size: CGFloat = 18, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .black, .heavy: name = "AvenirNext-Heavy"
        case .bold: name = "AvenirNext-Bold"
        case .semibold: name = "AvenirNext-DemiBold"
        case .medium: name = "AvenirNext-Medium"
        default: name = "AvenirNext-Regular"
        }
        return .custom(name, size: size)
    }
    static func mono(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    // MARK: Metrics
    static let corner: CGFloat = 24
    static let buttonHeight: CGFloat = 72
}

// MARK: - Backgrounds

/// Theatre black, one soft spotlight from above, and the soundwave: the app's one bold element.
struct StageBackground: View {
    var intensity: Double = 1.0
    var focus: UnitPoint = .top
    /// Live mic level 0...1 while recording; nil = idle drift.
    var level: Double? = nil

    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(
                colors: [Theme.spotlight.opacity(0.16 * intensity), .clear],
                center: focus, startRadius: 10, endRadius: 650)
            SoundwaveBackground(level: level)
        }
        .ignoresSafeArea()
    }
}

/// Slow, faint soundwave bars across the middle of every screen (gold in the center, green at the
/// edges). Drawn with Canvas so it's one cheap layer; static when Reduce Motion is on.
struct SoundwaveBackground: View {
    /// Live mic level while recording (the wave answers your voice); nil = slow idle drift.
    var level: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = level != nil
        let strength = live ? 0.8 + 1.6 * (level ?? 0) : 1.0
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            // Idle: barely moving. Recording: faster and taller with your voice.
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate * (live ? 1.0 : 0.25)
            Canvas { g, size in
                let barW: CGFloat = 6, gap: CGFloat = 8
                let count = Int(size.width / (barW + gap)) + 1
                let midY = size.height * 0.55
                let maxH = size.height * (live ? 0.22 + 0.25 * (level ?? 0) : 0.26)
                for i in 0..<count {
                    let x = CGFloat(i) * (barW + gap)
                    let u = Double(i) / Double(max(count - 1, 1))          // 0...1 across the screen
                    let envelope = sin(u * .pi)                             // taller in the middle
                    let a = sin(u * 13 + t * 1.7) * 0.5 + sin(u * 31 - t * 2.3) * 0.3 + sin(u * 5 + t * 0.9) * 0.2
                    let h = max(4, CGFloat(abs(a) * envelope) * maxH)
                    let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                    // green at the edges → gold in the middle (manual blend; Color.mix is iOS 18+)
                    let k = envelope * envelope
                    let color = Color(red: 0.239 + (0.961 - 0.239) * k,
                                      green: 0.871 + (0.769 - 0.871) * k,
                                      blue: 0.494 + (0.318 - 0.494) * k)
                    g.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                           with: .color(color.opacity(min(0.5, (0.10 + 0.10 * envelope) * strength))))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

struct BigButtonStyle: ButtonStyle {
    var filled = true
    /// nil = theme default: gold for primary (filled) buttons, green for secondary (outlined) ones.
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        let tint = self.tint ?? (filled ? Theme.gold : Theme.green)
        return configuration.label
            .font(Theme.display(26))
            .lineLimit(1)                 // "Leaderboard" etc. shrink instead of wrapping
            .minimumScaleFactor(0.55)
            .foregroundStyle(filled ? Color.black : tint)
            .padding(.horizontal, 22)
            .frame(minHeight: Theme.buttonHeight)
            .background {
                if filled {
                    Capsule().fill(tint)
                } else {
                    Capsule().strokeBorder(tint, lineWidth: 2.5)
                        .background(Capsule().fill(Theme.surface.opacity(0.6)))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(17, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .background(Capsule().fill(Theme.surfaceRaised))
            .overlay(Capsule().strokeBorder(Theme.green.opacity(0.45), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Common pieces

/// The DubStudio marquee logo.
struct LogoView: View {
    var size: CGFloat = 64
    var body: some View {
        HStack(spacing: size * 0.18) {
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.7, weight: .black))
                .foregroundStyle(Theme.goldGradient)
            Text("DubStudio")
                .font(Theme.display(size))
                .foregroundStyle(Theme.goldGradient)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("DubStudio")
    }
}

struct Card<Content: View>: View {
    var accent: Color = Theme.gold
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(24)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(accent.opacity(0.3), lineWidth: 1))
    }
}

/// Designed error card with a retry button.
struct ErrorCard: View {
    var title: String
    var message: String
    var retry: (() -> Void)?

    var body: some View {
        Card(accent: Theme.danger) {
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.danger)
                Text(title).font(Theme.display(30)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
                Text(message)
                    .font(Theme.body(17))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if let retry {
                    Button("Try again", action: retry).buttonStyle(BigButtonStyle(filled: false))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
