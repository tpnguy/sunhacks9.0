import Foundation

/// A time span in seconds from clip start. Used for speech windows and VAD segments.
struct TimeWindow: Codable, Hashable {
    var start: Double
    var end: Double
    var length: Double { max(0, end - start) }
}

struct Beat: Codable, Hashable {
    var t: Double
    var desc: String
    var emotion: String?
}

/// Matches clips.json / GET /clips (API.md).
struct Clip: Codable, Hashable, Identifiable {
    var clipId: String
    var title: String
    var videoFile: String
    var duration: Double
    var speechWindows: [TimeWindow]
    var beats: [Beat]
    var license: String
    var attribution: String

    var id: String { clipId }

    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id", title, videoFile = "video_file", duration
        case speechWindows = "speech_windows", beats, license, attribution
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipId = try c.decode(String.self, forKey: .clipId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? clipId
        videoFile = try c.decodeIfPresent(String.self, forKey: .videoFile) ?? "\(clipId).mp4"
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 15
        speechWindows = try c.decodeIfPresent([TimeWindow].self, forKey: .speechWindows) ?? []
        beats = try c.decodeIfPresent([Beat].self, forKey: .beats) ?? []
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        attribution = try c.decodeIfPresent(String.self, forKey: .attribution) ?? ""
    }

    /// URL of the bundled video (Clips/ folder reference in the app bundle).
    var bundledVideoURL: URL? {
        guard let base = Bundle.main.resourceURL else { return nil }
        let url = base.appendingPathComponent("Clips").appendingPathComponent(videoFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct ClipsResponse: Codable { var clips: [Clip] }

/// Metadata half of the POST /takes multipart body.
struct TakeMeta: Codable {
    var clipId: String
    var nickname: String
    var playerId: String
    var vadSegments: [TimeWindow]
    var audioMime: String = "audio/mp4"
    var audioPeakDb: Double?

    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id", nickname, playerId = "player_id", vadSegments = "vad_segments", audioMime = "audio_mime", audioPeakDb = "audio_peak_db"
    }
}

/// POST /takes response. Fields are lenient so a partially-implemented server never crashes the UI.
struct TakeResult: Codable, Equatable {
    var takeId: String
    var clipId: String
    var nickname: String
    var timing: Int
    var emotion: Int
    var comedy: Int
    var overall: Int
    var roast: String
    var emotionReason: String
    var comedyReason: String
    var scoredBy: String
    var latencyMs: Int
    var speechWindows: [TimeWindow]
    var vadSegments: [TimeWindow]
    var uploadUrl: String
    var shareUrl: String

    var isFallback: Bool { scoredBy == "fallback" }
    /// The server heard nothing (empty or silent recording) and didn't call Gemini.
    var isNoAudio: Bool { scoredBy == "no_audio" }

    enum CodingKeys: String, CodingKey {
        case takeId = "take_id", clipId = "clip_id", nickname, timing, emotion, comedy, overall, roast
        case emotionReason = "emotion_reason", comedyReason = "comedy_reason", scoredBy = "scored_by"
        case latencyMs = "latency_ms", speechWindows = "speech_windows", vadSegments = "vad_segments"
        case uploadUrl = "upload_url", shareUrl = "share_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        takeId = try c.decodeIfPresent(String.self, forKey: .takeId) ?? ""
        clipId = try c.decodeIfPresent(String.self, forKey: .clipId) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        timing = try c.decodeIfPresent(Int.self, forKey: .timing) ?? 0
        emotion = try c.decodeIfPresent(Int.self, forKey: .emotion) ?? 0
        comedy = try c.decodeIfPresent(Int.self, forKey: .comedy) ?? 0
        overall = try c.decodeIfPresent(Int.self, forKey: .overall) ?? 0
        roast = try c.decodeIfPresent(String.self, forKey: .roast) ?? ""
        emotionReason = try c.decodeIfPresent(String.self, forKey: .emotionReason) ?? ""
        comedyReason = try c.decodeIfPresent(String.self, forKey: .comedyReason) ?? ""
        scoredBy = try c.decodeIfPresent(String.self, forKey: .scoredBy) ?? "gemini"
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
        speechWindows = try c.decodeIfPresent([TimeWindow].self, forKey: .speechWindows) ?? []
        vadSegments = try c.decodeIfPresent([TimeWindow].self, forKey: .vadSegments) ?? []
        uploadUrl = try c.decodeIfPresent(String.self, forKey: .uploadUrl) ?? ""
        shareUrl = try c.decodeIfPresent(String.self, forKey: .shareUrl) ?? ""
    }
}

struct LeaderboardEntry: Codable, Hashable, Identifiable {
    var takeId: String
    var nickname: String
    var clipId: String
    var overall: Int
    var timing: Int
    var emotion: Int
    var comedy: Int
    var createdAt: String?

    var id: String { takeId }

    enum CodingKeys: String, CodingKey {
        case takeId = "take_id", nickname, clipId = "clip_id", overall, timing, emotion, comedy, createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        takeId = try c.decodeIfPresent(String.self, forKey: .takeId) ?? UUID().uuidString
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? "?"
        clipId = try c.decodeIfPresent(String.self, forKey: .clipId) ?? ""
        overall = try c.decodeIfPresent(Int.self, forKey: .overall) ?? 0
        timing = try c.decodeIfPresent(Int.self, forKey: .timing) ?? 0
        emotion = try c.decodeIfPresent(Int.self, forKey: .emotion) ?? 0
        comedy = try c.decodeIfPresent(Int.self, forKey: .comedy) ?? 0
        // created_at may be a string or a number depending on the server; accept both.
        if let s = try? c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = s
        } else if let n = try? c.decodeIfPresent(Double.self, forKey: .createdAt) {
            createdAt = String(n)
        } else {
            createdAt = nil
        }
    }
}

struct LeaderboardResponse: Codable { var entries: [LeaderboardEntry] }

/// A finished local recording, latency-compensated so t=0 == clip t=0.
struct Recording: Equatable {
    var audioURL: URL
    var vadSegments: [TimeWindow]
    var duration: Double
    var latencyCompensation: Double
    var inputRoute: String
    /// Loudest recorded sample in dBFS (-120 = nothing written). Sent so the server can skip Gemini on silence.
    var peakDB: Double = -120
}
