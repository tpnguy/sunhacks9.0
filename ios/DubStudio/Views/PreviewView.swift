import SwiftUI
import AVFoundation

/// Optional preview with the clip's original audio.
struct PreviewView: View {
    @EnvironmentObject var app: AppState
    let clip: Clip
    @State private var player = AVPlayer()
    @State private var muted = false

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Button { app.go(.grid) } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(ChipButtonStyle())
                Spacer()
                Text("Preview").font(Theme.body(18, weight: .bold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { muted.toggle(); player.isMuted = muted } label: {
                    Label(muted ? "Muted" : "Original audio", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(ChipButtonStyle())
            }
            StageTitle(text: clip.title, size: 40)
            StageScreen { PlayerView(player: player) }
                .frame(maxWidth: 1000)
            TimingBarView(duration: clip.duration, speechWindows: clip.speechWindows, playerSegments: [])
                .frame(maxWidth: 900)
            HStack(spacing: 20) {
                Button { player.seek(to: .zero); player.play() } label: { Label("Watch again", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(BigButtonStyle(filled: false))
                Button { app.go(.record(clip)) } label: { Label("I'm ready. Dub it", systemImage: "mic.fill") }
                    .buttonStyle(BigButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .onAppear {
            if let url = clip.bundledVideoURL {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
            }
        }
        .onDisappear { player.pause() }
    }
}
