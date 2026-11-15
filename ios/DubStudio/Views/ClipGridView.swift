import SwiftUI

struct ClipGridView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var thumbs = ThumbnailCache.shared

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 24)]

    var body: some View {
        VStack(spacing: 0) {
            header
            if app.clips.isEmpty {
                Spacer()
                ErrorCard(title: "No clips in the app",
                          message: "Add mp4s and clips.json to ios/DubStudio/Clips and rebuild.",
                          retry: nil)
                    .frame(maxWidth: 560)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        StageTitle(text: "Pick your scene", size: 48)
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(app.clips) { clip in
                                ClipCard(clip: clip, image: thumbs.images[clip.id])
                                    .onAppear { thumbs.load(clip) }
                            }
                        }
                    }
                    .padding(32)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            LogoView(size: 34)
                .onLongPressGesture(minimumDuration: 1.0) { app.showDebugSettings = true }
            Spacer()
            Button { app.go(.consent) } label: {
                Label(app.nickname, systemImage: "person.fill")
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityHint("Switch player")
            Button { app.go(.leaderboard) } label: { Label("Leaderboard", systemImage: "trophy.fill") }
                .buttonStyle(ChipButtonStyle())
            Button { app.showCredits = true } label: { Label("Credits", systemImage: "film") }
                .buttonStyle(ChipButtonStyle())
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
    }
}

private struct ClipCard: View {
    @EnvironmentObject var app: AppState
    let clip: Clip
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                // Fixed 16:9 box; the image fills it as an overlay so a wide (2.39:1) frame can't
                // widen the card. (scaledToFill inside the box itself let it push the column wider.)
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(Theme.surfaceRaised).overlay(ProgressView())
                        }
                    }
                    .clipped()

                Text(formatSeconds(clip.duration))
                    .font(Theme.mono(14))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(clip.title)
                .font(Theme.display(24))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2, reservesSpace: true)   // 1- and 2-line titles give equal card heights
                .minimumScaleFactor(0.85)
            Text(clip.metaLine)
                .font(Theme.body(15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            HStack(spacing: 12) {
                Button { app.go(.record(clip)) } label: {
                    Label("Dub it", systemImage: "mic.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButtonStyle())
                Button { app.go(.preview(clip)) } label: {
                    Image(systemName: "eye.fill").frame(width: 28)
                }
                .buttonStyle(BigButtonStyle(filled: false))
                .accessibilityLabel("Preview with original audio")
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.gold.opacity(0.25), lineWidth: 1))
    }
}

private extension Clip {
    /// "7 lines of dialogue, suspense and panic" — plain words, no repeated emotions.
    var metaLine: String {
        var seen = Set<String>()
        let moods = beats.compactMap(\.emotion).filter { seen.insert($0).inserted }.prefix(2)
        let lines = "\(speechWindows.count) line\(speechWindows.count == 1 ? "" : "s") of dialogue"
        return moods.isEmpty ? lines : lines + ", " + moods.joined(separator: " and ")
    }
}
