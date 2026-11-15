import AVFoundation
import Combine

/// Tier-1 QR share: export the dub in the background, PUT it to S3 via the presigned URL,
/// then tell the server it's uploaded. The QR points at share_url (/d/<take_id>), never at S3.
@MainActor
final class ShareUploader: ObservableObject {
    enum Status: Equatable {
        case idle, exporting, uploading, done
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    private var task: Task<Void, Never>?

    func start(composition: AVComposition, result: TakeResult) {
        guard task == nil, let uploadURL = URL(string: result.uploadUrl), !result.uploadUrl.isEmpty else { return }
        task = Task {
            do {
                status = .exporting
                let file = try await DubComposer.export(composition)
                status = .uploading
                let api = APIClient.current
                try await api.putDub(fileURL: file, to: uploadURL)
                try await api.markUploaded(takeID: result.takeId)
                try? FileManager.default.removeItem(at: file)
                status = .done
            } catch {
                status = .failed(friendlyMessage(for: error))
            }
        }
    }

    func cancel() { task?.cancel() }
}
