import Foundation

/// Server base URL: UserDefaults override (hidden debug sheet) > Info.plist `ServerBaseURL`
/// (build setting SERVER_BASE_URL) > http://localhost:8080.
enum ServerConfig {
    static let overrideKey = "serverBaseURLOverride"
    static let fallback = "http://localhost:8080"

    static var bundledDefault: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "ServerBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty || raw.hasPrefix("$(") ? fallback : raw
    }

    static var override: String? {
        get {
            let v = UserDefaults.standard.string(forKey: overrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                UserDefaults.standard.set(v, forKey: overrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            }
        }
    }

    static var baseURLString: String { override ?? bundledDefault }

    static var baseURL: URL {
        var s = baseURLString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? URL(string: fallback)!
    }
}
