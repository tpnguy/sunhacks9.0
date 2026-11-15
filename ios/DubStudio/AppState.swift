import SwiftUI
import UIKit
import AVFoundation

enum Screen: Equatable {
    case consent
    case grid
    case preview(Clip)
    case record(Clip)
    case result(Clip, Recording)
    case leaderboard

    var key: String {
        switch self {
        case .consent: return "consent"
        case .grid: return "grid"
        case .preview(let c): return "preview-\(c.id)"
        case .record(let c): return "record-\(c.id)"
        case .result(let c, let r): return "result-\(c.id)-\(r.audioURL.lastPathComponent)"
        case .leaderboard: return "leaderboard"
        }
    }
}

/// App-wide state + navigation (a simple screen enum gives full control over stage transitions).
@MainActor
final class AppState: ObservableObject {
    @Published var screen: Screen = .consent
    @Published var nickname: String
    @Published private(set) var playerID: String
    @Published private(set) var clips: [Clip] = []
    @Published var showCredits = false
    @Published var showDebugSettings = false

    private let defaults = UserDefaults.standard

    init() {
        MainThreadWatchdog.start()
        nickname = defaults.string(forKey: "nickname") ?? ""
        if let id = defaults.string(forKey: "playerID") {
            playerID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "playerID")
            playerID = id
        }
        clips = ClipStore.loadBundled()
        #if DEBUG
        // Debug autopilot: `-autoRecord <clip_id>` jumps straight to recording that clip (simulator repro).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-autoRecord"), i + 1 < args.count, let c = clips.first(where: { $0.clipId == args[i + 1] }) {
            if nickname.isEmpty { nickname = "autopilot" }
            screen = .record(c)
        }
        // `-autoScreen grid|leaderboard` opens that screen directly (screenshots).
        if let i = args.firstIndex(of: "-autoScreen"), i + 1 < args.count {
            if nickname.isEmpty { nickname = "autopilot" }
            switch args[i + 1] {
            case "grid": screen = .grid
            case "leaderboard": screen = .leaderboard
            default: break
            }
        }
        #endif
    }

    /// Called from the consent screen. A new nickname means a new player on the shared booth iPad,
    /// so it gets a fresh persistent player_id.
    func join(nickname raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if name != defaults.string(forKey: "nickname") {
            let id = UUID().uuidString
            defaults.set(id, forKey: "playerID")
            playerID = id
        }
        nickname = name
        defaults.set(name, forKey: "nickname")
        defaults.set(Date().timeIntervalSince1970, forKey: "consentedAt")
        go(.grid)
    }

    func go(_ s: Screen) {
        dlog("NAV -> \(s.key)")
        withAnimation(.easeInOut(duration: 0.45)) { screen = s }
        // @Published notifies BEFORE the value is stored. If SwiftUI renders synchronously inside
        // that notification (it did when leaving the record screen), it draws the OLD screen and
        // marks itself clean, so the app sat on "That's a wrap!". Nudge one more render now that
        // the new value is in place.
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    func refreshClipsFromServer() async {
        if let remote = try? await APIClient.current.clips() {
            clips = ClipStore.merge(bundled: ClipStore.loadBundled(), remote: remote)
        }
    }

    func clip(id: String) -> Clip? { clips.first { $0.clipId == id } }
}

enum ClipStore {
    /// Bundled clips are primary: Clips/clips.json + mp4s in the app bundle (folder reference).
    static func loadBundled() -> [Clip] {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Clips/clips.json"),
              let data = try? Data(contentsOf: url),
              let clips = try? JSONDecoder().decode([Clip].self, from: data) else { return [] }
        return clips.filter { $0.bundledVideoURL != nil }
    }

    /// Server data refreshes metadata (speech windows, beats, credits) of clips we have video for.
    /// Server-only clips are ignored because there is no bundled video to play.
    static func merge(bundled: [Clip], remote: [Clip]) -> [Clip] {
        let byID = Dictionary(remote.map { ($0.clipId, $0) }, uniquingKeysWith: { a, _ in a })
        return bundled.map { local in
            guard let r = byID[local.clipId] else { return local }
            var c = local
            if !r.speechWindows.isEmpty { c.speechWindows = r.speechWindows }
            if !r.beats.isEmpty { c.beats = r.beats }
            if !r.attribution.isEmpty { c.attribution = r.attribution }
            if !r.license.isEmpty { c.license = r.license }
            return c
        }
    }
}

/// Poster frames for the clip grid.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    @Published private(set) var images: [String: UIImage] = [:]
    private var inFlight: Set<String> = []

    func load(_ clip: Clip) {
        guard images[clip.id] == nil, !inFlight.contains(clip.id), let url = clip.bundledVideoURL else { return }
        inFlight.insert(clip.id)
        Task {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 800, height: 800)
            let t = CMTime(seconds: min(2, clip.duration / 3), preferredTimescale: 600)
            if let (cg, _) = try? await gen.image(at: t) {
                images[clip.id] = UIImage(cgImage: cg)
            }
            inFlight.remove(clip.id)
        }
    }
}
