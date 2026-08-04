import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var country = "FR"
    @State private var anthropicKey = ""
    @State private var captchaCode = ""
    @State private var tfaCode = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Compte Eufy") {
                    TextField("Email", text: $username)
                    SecureField("Mot de passe", text: $password)
                    TextField("Pays (code, ex. FR)", text: $country)
                    Text("Astuce : crée un compte Eufy secondaire dédié à EufyGuard et partage-lui tes appareils, pour éviter d'être déconnecté de l'app officielle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Agent IA (Claude)") {
                    SecureField("Clé API Anthropic (sk-ant-…)", text: $anthropicKey)
                    Text("Nécessaire pour l'analyse des images et le chat. Sans clé, la détection fonctionne mais sans analyse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if client.status?.state == "captcha", let captcha = client.status?.captcha {
                    Section("Captcha requis") {
                        if let image = captchaImage(captcha.image) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 80)
                        }
                        HStack {
                            TextField("Code du captcha", text: $captchaCode)
                            Button("Valider") {
                                run { try await client.submitCaptcha(id: captcha.id, code: captchaCode) }
                            }
                            .disabled(captchaCode.isEmpty)
                        }
                    }
                }

                if client.status?.state == "tfa" {
                    Section("Vérification en deux étapes") {
                        HStack {
                            TextField("Code reçu par email/SMS", text: $tfaCode)
                            Button("Valider") {
                                run { try await client.submitTfa(code: tfaCode) }
                            }
                            .disabled(tfaCode.isEmpty)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                if let bridgeError = client.status?.lastError, client.status?.state == "error" {
                    Text("Erreur bridge : \(bridgeError)")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Fermer") { dismiss() }
                Button("Enregistrer et connecter") {
                    run {
                        try await client.sendConfig(
                            username: username,
                            password: password,
                            country: country,
                            anthropicApiKey: anthropicKey
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty || busy)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func captchaImage(_ base64: String) -> NSImage? {
        var payload = base64
        if let range = payload.range(of: "base64,") {
            payload = String(payload[range.upperBound...])
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return NSImage(data: data)
    }
}
