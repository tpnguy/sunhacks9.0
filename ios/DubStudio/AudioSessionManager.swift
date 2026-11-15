import AVFoundation
import Combine

/// Owns the shared AVAudioSession configuration and publishes the current route
/// (shown in the debug overlay so we can confirm the mic is built-in, not Bluetooth HFP).
@MainActor
final class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    @Published private(set) var inputRoute = "-"
    @Published private(set) var outputRoute = "-"
    @Published private(set) var lastError: String?

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRoute() }
        }
    }

    /// Everywhere except the record screen: plain playback, so AirPods behave exactly as in any
    /// video app. (Holding .playAndRecord for the whole app made iOS treat LARPStudio like a call
    /// and the AirPods dropped out of the output picker.)
    func configureForPlayback() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback, options: [])
            try s.setActive(true)
            lastError = nil
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
        }
        refreshRoute()
        dlog("AUDIO playback mode, out=\(outputRoute)")
    }

    /// Record screen only: .playAndRecord with A2DP only. NEVER .allowBluetooth / .allowBluetoothHFP:
    /// that would pull the AirPods mic in over HFP (low bandwidth + extra latency). With A2DP only,
    /// output stays high quality on headphones and input falls back to the iPad's built-in mic.
    func configureForRecording() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try? s.setPreferredIOBufferDuration(0.010)
            try? s.setPreferredSampleRate(48_000)
            try s.setActive(true)
            lastError = nil
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
        }
        refreshRoute()
        dlog("AUDIO record mode, in=\(inputRoute) out=\(outputRoute), headphones=\(headphonesConnected)")
    }

    /// Sound is going to headphones (AirPods, wired, USB) rather than the iPad speaker.
    /// Then there is no speaker-to-mic echo, so voice processing isn't needed, and turning it on
    /// would knock Bluetooth headphones off A2DP (voice processing only supports call-quality HFP).
    nonisolated var headphonesConnected: Bool {
        let headphoneTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphoneTypes.contains($0.portType) }
    }

    func refreshRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputRoute = route.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        outputRoute = route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        if inputRoute.isEmpty { inputRoute = "none" }
        if outputRoute.isEmpty { outputRoute = "none" }
    }

    /// True if the input is a Bluetooth HFP mic (which we never want).
    var inputIsBluetoothHFP: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }

    func requestMicPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    var micPermissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }
}
