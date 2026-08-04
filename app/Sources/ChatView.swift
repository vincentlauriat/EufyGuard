import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var client: BridgeClient
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if client.chat.isEmpty {
                            intro
                        }
                        ForEach(client.chat) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                        if client.chatBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("L'agent réfléchit…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: client.chat.count) {
                    if let last = client.chat.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Pose une question à ton agent… (ex : « que s'est-il passé aujourd'hui ? »)", text: $input)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || client.chatBusy)
            }
            .padding(12)
            .background(.bar)
        }
        .navigationTitle("Agent IA")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await client.requestDigest(hours: 24) }
                } label: {
                    Label("Résumé 24 h", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(client.chatBusy)
            }
        }
        .onAppear { inputFocused = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("👋 Je suis ton agent de surveillance.")
                .font(.headline)
            Text("Je connais tout l'historique d'événements de tes caméras. Exemples :")
                .foregroundStyle(.secondary)
            ForEach([
                "Que s'est-il passé aujourd'hui ?",
                "Quelqu'un est-il passé devant la porte d'entrée cet après-midi ?",
                "Y a-t-il eu des livraisons cette semaine ?",
                "Résume les alertes des dernières 24 h.",
            ], id: \.self) { example in
                Button {
                    input = example
                    send()
                } label: {
                    Text("· \(example)").foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 12)
    }

    private func send() {
        let message = input.trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty, !client.chatBusy else { return }
        input = ""
        Task { await client.sendChat(message) }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(10)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
            if message.role != "user" { Spacer(minLength: 60) }
        }
    }

    private var background: Color {
        switch message.role {
        case "user": return .blue.opacity(0.25)
        case "error": return .red.opacity(0.15)
        default: return .gray.opacity(0.15)
        }
    }
}
