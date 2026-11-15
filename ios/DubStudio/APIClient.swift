import AVFoundation
import Foundation

enum APIError: LocalizedError {
    case http(Int, String)
    case badResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let snippet = body.prefix(160)
            return "Server returned \(code). \(snippet)"
        case .badResponse: return "The server sent something unexpected."
        case .decoding(let detail): return "Couldn't read the server's reply (\(detail))."
        }
    }
}

/// Thin client for the Go server. Contract: API.md.
struct APIClient {
    var baseURL: URL = ServerConfig.baseURL
    var session: URLSession = .shared

    static var current: APIClient { APIClient() }

    // MARK: Endpoints

    func health() async throws -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        req.timeoutInterval = 5
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        struct Health: Decodable { var ok: Bool }
        return (try? JSONDecoder().decode(Health.self, from: data).ok) ?? true
    }

    func clips() async throws -> [Clip] {
        var req = URLRequest(url: baseURL.appendingPathComponent("clips"))
        req.timeoutInterval = 6
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return try decode(ClipsResponse.self, data).clips
    }

    /// POST /takes (multipart: `meta` JSON string + `audio` file).
    func submitTake(meta: TakeMeta, audioURL: URL) async throws -> TakeResult {
        let boundary = "dubstudio-\(UUID().uuidString)"
        var body = Data()
        let metaJSON = try JSONEncoder().encode(meta)

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"meta\"\r\n")
        body.appendString("Content-Type: application/json\r\n\r\n")
        body.append(metaJSON)
        body.appendString("\r\n")

        let audio = try Data(contentsOf: audioURL)
        let head = audio.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
        let brand = audio.count >= 12 ? String(decoding: audio[4..<12], as: UTF8.self) : "?"
        let hasMdat = audio.range(of: Data("mdat".utf8)) != nil
        let asset = AVURLAsset(url: audioURL)
        let secs = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
        dlog("POST /takes: clip=\(meta.clipId) audio=\(audio.count) bytes, duration=\(String(format: "%.2f", secs)) s, header=\(brand) mdat=\(hasMdat) [\(head)], vadSegments=\(meta.vadSegments.count), url=\(baseURL.absoluteString)")
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"audio\"; filename=\"take.m4a\"\r\n")
        body.appendString("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.appendString("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: baseURL.appendingPathComponent("takes"))
        req.httpMethod = "POST"
        req.timeoutInterval = 50 // server: 15 s Gemini timeout + 1 retry (30 s worst case), then fallback
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let t0 = Date()
        let (data, resp) = try await session.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        dlog("POST /takes -> HTTP \(status) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(String(decoding: data.prefix(400), as: UTF8.self))")
        try check(resp, data)
        return try decode(TakeResult.self, data)
    }

    func leaderboard(clipID: String? = nil, limit: Int = 10) async throws -> [LeaderboardEntry] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("leaderboard"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let clipID { items.append(URLQueryItem(name: "clip_id", value: clipID)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 8
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return try decode(LeaderboardResponse.self, data).entries
    }

    /// PUT the exported dub straight to S3 via the presigned URL.
    func putDub(fileURL: URL, to uploadURL: URL) async throws {
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        req.timeoutInterval = 120
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, fromFile: fileURL)
        try check(resp, data)
    }

    func markUploaded(takeID: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("takes").appendingPathComponent(takeID).appendingPathComponent("uploaded"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
    }

    // MARK: Helpers

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error).prefix(120).description) }
    }
}

/// Human-friendly copy for network errors shown on the designed error cards.
func friendlyMessage(for error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "No connection to the judges' table. Check the Wi-Fi or hotspot."
        case .timedOut:
            return "The judges took too long to answer. Give it another go."
        case .cannotConnectToHost, .cannotFindHost:
            return "Couldn't reach the server at \(ServerConfig.baseURLString)."
        case .appTransportSecurityRequiresSecureConnection:
            return "This server needs HTTPS. Use the https:// sslip.io address."
        default:
            return urlError.localizedDescription
        }
    }
    return error.localizedDescription
}

extension Data {
    mutating func appendString(_ s: String) { append(Data(s.utf8)) }
}
