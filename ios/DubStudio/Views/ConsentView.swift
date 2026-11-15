import SwiftUI

struct ConsentView: View {
    @EnvironmentObject var app: AppState
    @State private var name = ""
    @State private var lightsUp = false
    @FocusState private var focused: Bool

    /// Exact one-line disclosure from PLAN.md.
    static let disclosure = "Your voice is recorded, sent to Google Gemini for scoring, and deleted after 7 days"

    var body: some View {
        ZStack {
            StageBackground(intensity: lightsUp ? 1.4 : 0.4)
                .animation(.easeOut(duration: 1.2), value: lightsUp)

            VStack(spacing: 36) {
                Spacer()
                LogoView(size: 84)
                    .onLongPressGesture(minimumDuration: 1.0) { app.showDebugSettings = true }
                Text("Dub the scene. Face the judges.")
                    .font(Theme.body(24, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)

                VStack(spacing: 20) {
                    TextField("", text: $name, prompt: Text("Your stage name").foregroundStyle(Theme.textSecondary))
                        .font(Theme.display(34))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textPrimary)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(join)
                        .padding(.vertical, 18)
                        .padding(.horizontal, 24)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.gold.opacity(focused ? 0.9 : 0.3), lineWidth: 2))
                        .frame(maxWidth: 520)
                        .onChange(of: name) { _, v in if v.count > 20 { name = String(v.prefix(20)) } }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield.fill").foregroundStyle(Theme.gold)
                        Text(Self.disclosure + ".")
                            .font(Theme.body(17, weight: .medium))
                            .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    }
                    .frame(maxWidth: 560)

                    Button(action: join) {
                        Label("I agree. Let's go", systemImage: "star.fill")
                    }
                    .buttonStyle(BigButtonStyle())
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.45 : 1)
                }
                Spacer()
                Button("Clip credits") { app.showCredits = true }
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(32)
        }
        .onAppear {
            name = ""   // every player at the booth enters their own name
            lightsUp = true
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func join() {
        guard !trimmed.isEmpty else { return }
        focused = false
        Task { _ = await AudioSessionManager.shared.requestMicPermission() }
        app.join(nickname: trimmed)
    }
}
