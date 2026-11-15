import SwiftUI

/// In-app clip credits (CC-BY attribution) + privacy note.
struct CreditsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            StageBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        StageTitle(text: "Credits", size: 44)
                        Spacer()
                        Button("Done") { dismiss() }.buttonStyle(ChipButtonStyle())
                    }
                    ForEach(app.clips) { clip in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(clip.title).font(Theme.display(24)).foregroundStyle(Theme.textPrimary)
                                Text(clip.attribution).font(Theme.body(16)).foregroundStyle(Theme.textPrimary.opacity(0.9))
                                Text("License: \(clip.license)").font(Theme.body(14, weight: .semibold)).foregroundStyle(Theme.gold)
                                Text("Audio replaced by the player's dub.").font(Theme.body(13)).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Privacy").font(Theme.display(24)).foregroundStyle(Theme.textPrimary)
                            Text(ConsentView.disclosure + ". Nicknames only, no accounts.")
                                .font(Theme.body(16)).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("DubStudio, built at SunHacks 2026.")
                        .font(Theme.body(14)).foregroundStyle(Theme.textSecondary)
                }
                .padding(32)
            }
        }
    }
}
