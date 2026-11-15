import SwiftUI

/// Hidden settings (long-press the logo): server URL override persisted in UserDefaults.
struct DebugSettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var audio: AudioSessionManager
    @ObservedObject private var log = DebugLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var url = ServerConfig.baseURLString
    @State private var health: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://<elastic-ip>.sslip.io", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.mono(16))
                    Button("Save") { save() }
                    Button("Reset to build default (\(ServerConfig.bundledDefault))") {
                        ServerConfig.override = nil
                        url = ServerConfig.baseURLString
                        health = nil
                    }
                    Button(checking ? "Checking…" : "Test /healthz") { Task { await check() } }
                        .disabled(checking)
                    if let health { Text(health).font(Theme.mono(13)) }
                } header: { Text("Server base URL") } footer: {
                    Text("Active: \(ServerConfig.baseURLString)")
                }
                Section("Audio route") {
                    LabeledContent("Input", value: audio.inputRoute)
                    LabeledContent("Output", value: audio.outputRoute)
                    if audio.inputIsBluetoothHFP {
                        Text("Warning: Bluetooth HFP mic in use").foregroundStyle(Theme.danger)
                    }
                    Button("Refresh route") { audio.refreshRoute() }
                }
                Section {
                    ScrollView {
                        Text(log.lines.isEmpty ? "No takes logged yet. Record one, then come back." : log.text)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220, maxHeight: 420)
                    Button("Copy log") { UIPasteboard.general.string = log.text }
                    Button("Clear log", role: .destructive) { log.clear() }
                } header: { Text("Take log") } footer: {
                    Text("Also printed to the Xcode console (search \"[DubStudio]\"). Server side: infra/logs.sh")
                }
                Section("Player") {
                    LabeledContent("Nickname", value: app.nickname)
                    LabeledContent("player_id", value: app.playerID).font(Theme.mono(12))
                    LabeledContent("Clips loaded", value: "\(app.clips.count)")
                }
            }
            .navigationTitle("Debug settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } } }
        }
    }

    private func save() {
        ServerConfig.override = (url == ServerConfig.bundledDefault) ? nil : url
        url = ServerConfig.baseURLString
        Task { await app.refreshClipsFromServer() }
    }

    private func check() async {
        save()
        checking = true
        defer { checking = false }
        do {
            let ok = try await APIClient.current.health()
            health = ok ? "OK: \(ServerConfig.baseURLString)" : "Server answered but not ok"
        } catch {
            health = "Failed: \(friendlyMessage(for: error))"
        }
    }
}

#if DEBUG
/// Debug-build overlay: current input/output route, so we can confirm the mic is built-in (not HFP).
struct DebugRouteOverlay: View {
    @EnvironmentObject var audio: AudioSessionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("IN  \(audio.inputRoute)")
            Text("OUT \(audio.outputRoute)")
            Text("SRV \(ServerConfig.baseURLString)")
        }
        .font(Theme.mono(10))
        .foregroundStyle(audio.inputIsBluetoothHFP ? Theme.danger : Theme.textSecondary)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.6)))
        .padding(8)
        .allowsHitTesting(false)
    }
}
#endif
