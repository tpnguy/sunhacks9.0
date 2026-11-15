import SwiftUI
import AVFoundation
import Combine

/// Instant replay (left) + judges' panel (right). Upload starts immediately while the replay plays.
@MainActor
final class ResultController: ObservableObject {
    enum Scoring: Equatable {
        case deliberating
        case scored(TakeResult)
        case failed(String)
    }

    @Published var scoring: Scoring = .deliberating
    @Published var replayReady = false
    let player = AVQueuePlayer()
    let share = ShareUploader()
    private var looper: AVPlayerLooper?
    private var composition: AVComposition?
    private var submitTask: Task<Void, Never>?

    func start(clip: Clip, recording: Recording, nickname: String, playerID: String) {
        // Back to plain playback for the replay so AirPods stay on high-quality A2DP.
        AudioRecorder.teardownQueue.async {
            Task { @MainActor in AudioSessionManager.shared.configureForPlayback() }
        }
        dlog("FLOW results screen appeared, submitting take")
        Task { await buildReplay(clip: clip, recording: recording) }
        submit(clip: clip, recording: recording, nickname: nickname, playerID: playerID)
    }

    private func buildReplay(clip: Clip, recording: Recording) async {
        guard let url = clip.bundledVideoURL,
              let comp = try? await DubComposer.makeComposition(clipURL: url, audioURL: recording.audioURL) else { return }
        composition = comp
        let item = AVPlayerItem(asset: comp)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
        replayReady = true
        startShareIfPossible()
    }

    func submit(clip: Clip, recording: Recording, nickname: String, playerID: String) {
        scoring = .deliberating
        submitTask?.cancel()
        submitTask = Task {
            let started = Date()
            do {
                let meta = TakeMeta(clipId: clip.clipId, nickname: nickname, playerId: playerID,
                                    vadSegments: recording.vadSegments, audioPeakDb: recording.peakDB)
                let result = try await APIClient.current.submitTake(meta: meta, audioURL: recording.audioURL)
                // Let the "judges deliberating" bit land even on a very fast server.
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 1.8 { try? await Task.sleep(nanoseconds: UInt64((1.8 - elapsed) * 1e9)) }
                scoring = .scored(result)
                startShareIfPossible()
            } catch {
                if !Task.isCancelled { scoring = .failed(friendlyMessage(for: error)) }
            }
        }
    }

    private func startShareIfPossible() {
        guard case .scored(let result) = scoring, !result.uploadUrl.isEmpty, let composition else { return }
        share.start(composition: composition, result: result)
    }

    func stop() {
        player.pause()
        submitTask?.cancel()
    }
}

struct ResultView: View {
    @EnvironmentObject var app: AppState
    let clip: Clip
    let recording: Recording
    @StateObject private var ctl = ResultController()
    @State private var showQR = false
    @Environment(\.screenIsWide) private var screenIsWide

    var body: some View {
        // No GeometryReader here: measuring inside this ScrollView during the screen transition
        // caused a layout loop on device that froze on "That's a wrap!". Width comes from RootView.
        ScrollView {
            Group {
                if screenIsWide {
                    HStack(alignment: .top, spacing: 28) {
                        replayColumn.frame(maxWidth: .infinity)
                        judgesPanel.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 24) {
                        replayColumn
                        judgesPanel
                    }
                }
            }
            .padding(32)
        }
        .onAppear { ctl.start(clip: clip, recording: recording, nickname: app.nickname, playerID: app.playerID) }
        .onDisappear { ctl.stop() }
        .sheet(isPresented: $showQR) {
            if case .scored(let r) = ctl.scoring { QRShareView(result: r, clip: clip, uploader: ctl.share) }
        }
    }

    private var replayColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { app.go(.grid) } label: { Label("Home", systemImage: "chevron.left") }
                    .buttonStyle(ChipButtonStyle())
                Spacer()
                Text("Playing as \(app.nickname)").font(Theme.body(15, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            StageScreen {
                ZStack {
                    PlayerView(player: ctl.player)
                    if !ctl.replayReady { ProgressView().controlSize(.large) }
                }
            }
            Text(clip.title).font(Theme.display(28)).foregroundStyle(Theme.textPrimary)
            actionButtons
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 14) {
            Button { app.go(.grid) } label: {
                Label("Pick another scene", systemImage: "square.grid.2x2.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(BigButtonStyle())
            HStack(spacing: 14) {
                Button { app.go(.record(clip)) } label: {
                    Label("Retake", systemImage: "mic.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButtonStyle(filled: false))
                Button { app.go(.leaderboard) } label: {
                    Label("Leaderboard", systemImage: "trophy.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButtonStyle(filled: false))
            }
            if case .scored(let r) = ctl.scoring, !r.uploadUrl.isEmpty {
                Button { showQR = true } label: {
                    Label("Get a link to your dub", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButtonStyle(filled: false, tint: Theme.you))
            }
        }
    }

    @ViewBuilder private var judgesPanel: some View {
        switch ctl.scoring {
        case .deliberating:
            DeliberatingView()
                .transition(.opacity)
        case .scored(let result):
            ScorecardView(result: result, clip: clip, localSegments: recording.vadSegments)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        case .failed(let msg):
            ErrorCard(title: "Couldn't send your take", message: msg) {
                ctl.submit(clip: clip, recording: recording, nickname: app.nickname, playerID: app.playerID)
            }
        }
    }
}

/// "Judges deliberating" animation that hides the Gemini latency.
struct DeliberatingView: View {
    @State private var phase = 0
    private let lines = ["The judges are deliberating…", "Rewinding your big moment…", "Someone is taking notes…",
                         "Checking your timing to the millisecond…", "Arguing about the comedy score…"]
    private let timer = Timer.publish(every: 1.6, on: .main, in: .common).autoconnect()

    var body: some View {
        Card {
            VStack(spacing: 28) {
                HStack(spacing: 26) {
                    ForEach(0..<3, id: \.self) { i in JudgeSeat(index: i, phase: phase) }
                }
                .padding(.top, 12)
                Text(lines[phase % lines.count])
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .id(phase)
                    .transition(.opacity)
                ProgressView().tint(Theme.gold)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        }
        .onReceive(timer) { _ in withAnimation(.easeInOut(duration: 0.4)) { phase += 1 } }
    }
}

private struct JudgeSeat: View {
    let index: Int
    let phase: Int
    var body: some View {
        let active = phase % 3 == index
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.surfaceRaised).frame(width: 92, height: 92)
                Image(systemName: ["person.fill", "person.fill.questionmark", "person.fill.viewfinder"][index])
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(active ? Theme.gold : Theme.textSecondary)
            }
            .overlay(Circle().strokeBorder(Theme.gold.opacity(active ? 0.9 : 0.15), lineWidth: 3))
            .scaleEffect(active ? 1.1 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: active)
            Image(systemName: "ellipsis.bubble.fill")
                .foregroundStyle(Theme.gold)
                .opacity(active ? 1 : 0)
        }
    }
}
