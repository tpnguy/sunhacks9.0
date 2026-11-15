import AVFoundation

/// Builds the instant-replay composition: clip video track + the player's recorded audio.
/// Played directly in AVPlayer (no export), so AVPlayer handles Bluetooth output latency.
enum DubComposer {
    static func makeComposition(clipURL: URL, audioURL: URL) async throws -> AVComposition {
        let videoAsset = AVURLAsset(url: clipURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let comp = AVMutableComposition()

        let videoDuration = try await videoAsset.load(.duration)
        if let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
           let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try dst.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: srcVideo, at: .zero)
            dst.preferredTransform = try await srcVideo.load(.preferredTransform)
        }

        let audioDuration = try await audioAsset.load(.duration)
        if let srcAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let d = CMTimeMinimum(audioDuration, videoDuration)
            try dst.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: srcAudio, at: .zero)
        }
        return comp
    }

    /// Background export of the same composition to an .mp4 for the S3 upload (Tier 1 QR share).
    static func export(_ composition: AVComposition) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("dub-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720) else {
            throw NSError(domain: "DubComposer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Export unavailable"])
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status != .completed {
            throw session.error ?? NSError(domain: "DubComposer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export failed"])
        }
        return out
    }
}
