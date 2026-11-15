import SwiftUI

@main
struct DubStudioApp: App {
    @StateObject private var app = AppState()

    init() {
        AudioSessionManager.shared.configureForPlayback()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(AudioSessionManager.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    @State private var wide = false

    var body: some View {
        ZStack {
            // Measure the window once, outside any ScrollView, and hand it down.
            GeometryReader { geo in
                Color.clear
                    .onAppear { wide = geo.size.width > geo.size.height }
                    .onChange(of: geo.size) { _, s in wide = s.width > s.height }
            }
            StageBackground()
            Group {
                switch app.screen {
                case .consent: ConsentView()
                case .grid: ClipGridView()
                case .preview(let clip): PreviewView(clip: clip)
                case .record(let clip): RecordView(clip: clip)
                case .result(let clip, let rec): ResultView(clip: clip, recording: rec)
                case .leaderboard: LeaderboardView()
                }
            }
            .environment(\.screenIsWide, wide || ProcessInfo.processInfo.arguments.contains("-forceWide"))
            .id(app.screen.key)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)),
                                    removal: .opacity))
        }
        .overlay(alignment: .bottomLeading) {
            #if DEBUG
            DebugRouteOverlay()
            #endif
        }
        .sheet(isPresented: $app.showCredits) { CreditsView() }
        .sheet(isPresented: $app.showDebugSettings) { DebugSettingsView() }
        .task { await app.refreshClipsFromServer() }
    }
}

private struct ScreenIsWideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True in landscape. Measured once in RootView so screens don't need their own GeometryReader.
    var screenIsWide: Bool {
        get { self[ScreenIsWideKey.self] }
        set { self[ScreenIsWideKey.self] = newValue }
    }
}
