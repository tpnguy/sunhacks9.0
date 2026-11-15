import SwiftUI
import CoreImage.CIFilterBuiltins

/// Tier-1 share: QR of share_url (/d/<take_id>), plus live upload status.
struct QRShareView: View {
    let result: TakeResult
    let clip: Clip
    @ObservedObject var uploader: ShareUploader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            StageBackground()
            VStack(spacing: 24) {
                StageTitle(text: "Scan to get your dub", size: 40)
                if let img = QRCode.image(for: result.shareUrl) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 320, height: 320)
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 24).fill(.white))
                        .shadow(color: Theme.gold.opacity(0.4), radius: 30)
                }
                statusLine
                Text("Scan with your phone camera. Your dub is deleted after 7 days, and the page has a delete button.")
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Text("Clip: \(clip.attribution)")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("Done") { dismiss() }.buttonStyle(BigButtonStyle())
            }
            .padding(32)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch uploader.status {
        case .idle, .exporting:
            Label("Cutting your dub…", systemImage: "film.stack").foregroundStyle(Theme.gold)
        case .uploading:
            Label("Uploading…", systemImage: "icloud.and.arrow.up").foregroundStyle(Theme.gold)
        case .done:
            Label("Ready to watch", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.you)
        case .failed(let msg):
            Label("Upload failed: \(msg)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        }
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
