import SwiftUI
import AVFoundation
import Combine

/// Drives one take: prepare mic + player, 3-2-1 countdown, then start the muted clip and the
/// recording from the same host time.
@MainActor
final class RecordController: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case countdown(Int)
        case recording
        case finishing
        case failed(String)
    }

    @Published var phase: Phase = .preparing
    @Published var playhead: Double = 0
    let player = AVPlayer()
    let recorder = AudioRecorder()

    private var timeObserver: Any?
    private var countdownTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    var onFinished: ((Recording) -> Void)?

    func start(clip: Clip) {
        phase = .preparing
        countdownTask?.cancel()
        countdownTask = Task { await run(clip: clip) }
    }

    private func run(clip: Clip) async {
        guard let url = clip.bundledVideoURL else { phase = .failed("This clip's video is missing from the app bundle."); return }
        let audio = AudioSessionManager.shared
        guard await audio.requestMicPermission() else { phase = .failed(RecorderError.permissionDenied.localizedDescription); return }
        audio.configureForRecording()

        // Muted clip, ready to start at an exact host time.
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false

        do { try recorder.prepare() } catch {
            phase = .failed(error.localizedDescription); return
        }

        // Wait for the item (≤3 s) while the countdown runs.
        for n in stride(from: 3, through: 1, by: -1) {
            phase = .countdown(n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
        }
        var waited = 0
        while item.status != .readyToPlay && waited < 60 {
            try? await Task.sleep(nanoseconds: 50_000_000); waited += 1
        }
        dlog("FLOW item status=\(item.status.rawValue) after \(waited * 50) ms, err=\(String(describing: item.error))")
        guard item.status == .readyToPlay else { phase = .failed("Couldn't load the clip."); return }
        let prerolled = await player.preroll(atRate: 1.0)
        dlog("FLOW preroll=\(prerolled)")

        // Shared start: 150 ms in the future so both pipelines are armed.
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.15)
        do {
            try recorder.beginRecording(atHostTime: startHost, duration: clip.duration,
                                        inputRoute: audio.inputRoute) { [weak self] result in
                Task { @MainActor in self?.handle(result) }
            }
        } catch {
            phase = .failed(error.localizedDescription); return
        }
        player.setRate(1.0, time: .zero, atHostTime: CMClockMakeHostTimeFromSystemUnits(startHost))
        phase = .recording
        dlog("FLOW recording started (clip \(clip.clipId), \(clip.duration) s)")

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            Task { @MainActor in self?.playhead = t.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            // Give the recorder a moment to reach the target frame count, then force-finish.
            dlog("FLOW player reached end")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.recorder.finishNow()
            }
        }
        // Safety net in case the end notification never arrives.
        safetyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((clip.duration + 2.0) * 1_000_000_000))
            if !Task.isCancelled { dlog("FLOW safety timer fired"); self?.recorder.finishNow() }
        }
    }

    private func handle(_ result: Result<Recording, Error>) {
        dlog("FLOW recorder delivered: \(result)")
        teardownObservers()
        player.pause()
        switch result {
        case .success(let rec):
            phase = .finishing
            dlog("FLOW navigating to results")
            onFinished?(rec)
        case .failure(let err):
            phase = .failed(err.localizedDescription)
        }
    }

    func cancel() {
        countdownTask?.cancel()
        teardownObservers()
        recorder.cancel()
        player.pause()
        AudioRecorder.teardownQueue.async {   // after the engine is released
            Task { @MainActor in AudioSessionManager.shared.configureForPlayback() }
        }
    }

    private func teardownObservers() {
        safetyTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

struct RecordView: View {
    @EnvironmentObject var app: AppState
    let clip: Clip
    @StateObject private var ctl = RecordController()

    var body: some View {
        ZStack {
            RecordingBackground(recorder: ctl.recorder, live: ctl.phase == .recording)
            VStack(spacing: 24) {
                topBar
                StageScreen(glow: ctl.phase == .recording ? Theme.danger : Theme.gold) {
                    ZStack {
                        PlayerView(player: ctl.player)
                        countdownOverlay
                    }
                }
                .frame(maxWidth: 1000)

                TimingBarView(duration: clip.duration, speechWindows: clip.speechWindows,
                              playerSegments: [], playhead: ctl.playhead)
                    .frame(maxWidth: 900)

                LevelMeterRow(recorder: ctl.recorder)

                if case .failed(let msg) = ctl.phase {
                    ErrorCard(title: "Mic check failed", message: msg) { ctl.start(clip: clip) }
                        .frame(maxWidth: 560)
                }
                Spacer(minLength: 0)
            }
            .padding(32)
        }
        .onAppear {
            ctl.onFinished = { rec in app.go(.result(clip, rec)) }
            ctl.start(clip: clip)
        }
        .onDisappear { ctl.cancel() }
    }

    private var topBar: some View {
        HStack {
            Button { ctl.cancel(); app.go(.grid) } label: { Label("Cancel", systemImage: "xmark") }
                .buttonStyle(ChipButtonStyle())
            Spacer()
            if ctl.phase == .recording {
                HStack(spacing: 10) {
                    Circle().fill(Theme.danger).frame(width: 14, height: 14)
                        .modifier(Pulse())
                    Text("ON AIR").font(Theme.display(22)).foregroundStyle(Theme.danger)
                    Text(formatSeconds(max(0, clip.duration - ctl.playhead)))
                        .font(Theme.mono(20)).foregroundStyle(Theme.textPrimary)
                }
            } else {
                Text(clip.title).font(Theme.body(18, weight: .bold)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Color.clear.frame(width: 110, height: 1)
        }
    }

    @ViewBuilder private var countdownOverlay: some View {
        switch ctl.phase {
        case .preparing:
            ZStack {
                Color.black.opacity(0.7)
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Setting the stage…").font(Theme.body(20, weight: .semibold))
                }
            }
        case .countdown(let n):
            CountdownSpotlight(number: n)
        case .finishing:
            Color.black.opacity(0.5).overlay(Text("That's a wrap!").font(Theme.display(54)).foregroundStyle(Theme.gold))
        default:
            EmptyView()
        }
    }
}

private struct LevelMeterRow: View {
    @ObservedObject var recorder: AudioRecorder
    var body: some View {
        HStack(spacing: 20) {
            LevelMeter(level: recorder.level, speaking: recorder.isSpeaking)
                .padding(.leading, 40)
            Text(recorder.isSpeaking ? "We hear you!" : "Speak when the gold bar lights up")
                .font(Theme.body(17, weight: .semibold))
                .foregroundStyle(recorder.isSpeaking ? Theme.you : Theme.textSecondary)
                .frame(width: 320, alignment: .leading)
        }
    }
}

/// 3-2-1 with a spotlight that narrows onto the number.
struct CountdownSpotlight: View {
    let number: Int
    @State private var pop = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
            RadialGradient(colors: [Theme.spotlight.opacity(0.55), Theme.gold.opacity(0.15), .clear],
                           center: .center, startRadius: 0, endRadius: pop ? 220 : 520)
            Text("\(number)")
                .font(Theme.display(220))
                .foregroundStyle(Theme.goldGradient)
                .scaleEffect(pop ? 1 : 1.8)
                .opacity(pop ? 1 : 0)
        }
        .id(number)
        .onAppear {
            pop = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { pop = true }
        }
        .transition(.opacity)
    }
}

struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 0.3 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = true } }
    }
}

/// While ON AIR the background soundwave follows the player's mic level.
private struct RecordingBackground: View {
    @ObservedObject var recorder: AudioRecorder
    let live: Bool
    var body: some View {
        StageBackground(intensity: live ? 0.6 : 1.0, level: live ? Double(recorder.level) : nil)
    }
}
