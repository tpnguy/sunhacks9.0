import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject var app: AppState
    @State private var entries: [LeaderboardEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter: String? = nil   // nil = all clips

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button { app.go(.grid) } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(ChipButtonStyle())
                Spacer()
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(ChipButtonStyle())
            }
            HStack(spacing: 14) {
                Image(systemName: "trophy.fill").font(.system(size: 44)).foregroundStyle(Theme.goldGradient)
                StageTitle(text: "Leaderboard", size: 56)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    filterChip(title: "All scenes", id: nil)
                    ForEach(app.clips) { c in filterChip(title: c.title, id: c.clipId) }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: 900)

            Group {
                if loading && entries.isEmpty {
                    ProgressView().controlSize(.large).frame(maxHeight: .infinity)
                } else if let error {
                    ErrorCard(title: "Couldn't load the leaderboard", message: error) { Task { await load() } }
                        .frame(maxWidth: 560)
                    Spacer()
                } else if entries.isEmpty {
                    Card {
                        Text("No takes yet. Be the first legend.")
                            .font(Theme.display(28)).foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: 560)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                                row(rank: i + 1, e)
                            }
                        }
                        .frame(maxWidth: 900)
                        .padding(.bottom, 24)
                    }
                }
            }

            Button { app.go(.grid) } label: { Label("Pick a scene", systemImage: "mic.fill") }
                .buttonStyle(BigButtonStyle())
        }
        .padding(32)
        .task { await load() }
    }

    private func filterChip(title: String, id: String?) -> some View {
        let on = filter == id
        return Button {
            filter = id
            Task { await load() }
        } label: {
            Text(title)
                .font(Theme.body(16, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(on ? Color.black : Theme.textPrimary)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(Capsule().fill(on ? Theme.green : Theme.surfaceRaised))
        }
        .buttonStyle(.plain)
    }

    private func row(rank: Int, _ e: LeaderboardEntry) -> some View {
        let isMe = e.nickname == app.nickname
        let medal: Color? = rank == 1 ? Theme.gold : rank == 2 ? Color(white: 0.78) : rank == 3 ? Color(red: 0.80, green: 0.50, blue: 0.25) : nil
        return HStack(spacing: 18) {
            ZStack {
                Circle().fill(medal ?? Theme.surfaceRaised).frame(width: 52, height: 52)
                Text("\(rank)").font(Theme.display(24)).foregroundStyle(medal == nil ? Theme.textPrimary : .black)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(e.nickname).font(Theme.display(26)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(app.clip(id: e.clipId)?.title ?? e.clipId)
                    .font(Theme.body(14, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 16) {
                mini("Timing", e.timing); mini("Emotion", e.emotion); mini("Comedy", e.comedy)
            }
            Text("\(e.overall)")
                .font(Theme.display(40)).monospacedDigit()
                .foregroundStyle(Theme.goldGradient)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20).fill(isMe ? Theme.gold.opacity(0.14) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(isMe ? Theme.gold : Theme.gold.opacity(0.15), lineWidth: isMe ? 2 : 1))
    }

    private func mini(_ label: String, _ v: Int) -> some View {
        VStack(spacing: 0) {
            Text(label).font(Theme.body(12, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text("\(v)").font(Theme.body(18, weight: .bold)).monospacedDigit().foregroundStyle(Theme.textPrimary)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await APIClient.current.leaderboard(clipID: filter, limit: 10)
            error = nil
        } catch {
            self.error = friendlyMessage(for: error)
        }
    }
}
