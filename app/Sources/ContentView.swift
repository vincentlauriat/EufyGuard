import SwiftUI

enum SidebarItem: Hashable {
    case dashboard
    case events
    case chat
}

struct ContentView: View {
    @EnvironmentObject private var client: BridgeClient
    @State private var selection: SidebarItem? = .dashboard
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Surveillance") {
                    Label("Tableau de bord", systemImage: "square.grid.2x2").tag(SidebarItem.dashboard)
                    Label("Événements", systemImage: "clock.arrow.circlepath").tag(SidebarItem.events)
                    Label("Agent IA", systemImage: "brain").tag(SidebarItem.chat)
                }
                Section("Caméras (\(client.devices.count))") {
                    ForEach(client.devices) { device in
                        HStack {
                            Image(systemName: "web.camera")
                                .foregroundStyle(device.enabled ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.model)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let battery = device.battery {
                                Text("\(battery)%")
                                    .font(.caption2)
                                    .foregroundStyle(battery < 20 ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) { statusBar }
        } detail: {
            switch selection {
            case .events: EventsView()
            case .chat: ChatView()
            default: DashboardView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Réglages", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(client)
        }
        .onChange(of: client.status) { _, status in
            // Force settings open when the bridge needs configuration or a code
            guard let status else { return }
            if status.state == "captcha" || status.state == "tfa" || !status.configured {
                showSettings = true
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }

    private var statusColor: Color {
        guard client.isReachable, let status = client.status else { return .red }
        switch status.state {
        case "connected": return .green
        case "connecting": return .orange
        case "captcha", "tfa": return .yellow
        default: return .red
        }
    }

    private var statusText: String {
        guard client.isReachable else { return "Bridge injoignable…" }
        var text = client.status?.stateLabel ?? "…"
        if client.status?.agentEnabled == false { text += " · IA désactivée" }
        return text
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject private var client: BridgeClient
    @State private var reloadToken = UUID()
    @State private var liveDevice: DeviceInfo?

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        ScrollView {
            if client.devices.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(client.devices) { device in
                        CameraCard(device: device, reloadToken: reloadToken)
                            .onTapGesture { liveDevice = device }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Tableau de bord")
        .sheet(item: $liveDevice) { device in
            CameraLiveView(device: device)
        }
        .toolbar {
            ToolbarItem {
                guardModeMenu
            }
            ToolbarItem {
                Button {
                    reloadToken = UUID()
                } label: {
                    Label("Rafraîchir", systemImage: "arrow.clockwise")
                }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            reloadToken = UUID()
        }
    }

    private var guardModeMenu: some View {
        Menu {
            ForEach(client.stations) { station in
                if client.stations.count > 1 {
                    Section(station.name) { guardButtons(for: station) }
                } else {
                    guardButtons(for: station)
                }
            }
        } label: {
            Label(
                client.stations.first?.modeLabel ?? "Mode",
                systemImage: "shield.lefthalf.filled"
            )
        }
        .disabled(client.stations.isEmpty)
    }

    private func guardButtons(for station: StationInfo) -> some View {
        ForEach(StationInfo.modes, id: \.value) { mode in
            Button {
                Task { await client.setGuardMode(station: station, mode: mode.value) }
            } label: {
                if station.guardMode == mode.value {
                    Label(mode.label, systemImage: "checkmark")
                } else {
                    Label(mode.label, systemImage: mode.icon)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "web.camera")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(client.status?.configured == true
                 ? "En attente des caméras…"
                 : "Configure ton compte Eufy dans les Réglages (⚙️) pour commencer.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

struct CameraCard: View {
    @EnvironmentObject private var client: BridgeClient
    let device: DeviceInfo
    let reloadToken: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SnapshotImage(url: snapshotURL)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Label("Direct", systemImage: "play.circle.fill")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text(lastEventText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let battery = device.battery {
                    Label("\(battery)%", systemImage: "battery.75percent")
                        .font(.caption)
                        .foregroundStyle(battery < 20 ? .red : .secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var snapshotURL: URL {
        var components = URLComponents(
            url: client.snapshotURL(for: device),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "t", value: reloadToken.uuidString)]
        return components.url!
    }

    private var lastEventText: String {
        guard let event = client.events.first(where: { $0.deviceSn == device.serial }) else {
            return "Aucun événement"
        }
        let time = event.date.formatted(date: .omitted, time: .shortened)
        return "\(event.kind) à \(time)" + (event.analysis.map { " — \($0.resume)" } ?? "")
    }
}

/// Loads a snapshot without URL caching (the URL changes via the reload token).
struct SnapshotImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video.slash")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let loaded = NSImage(data: data) {
                image = loaded
            }
        }
    }
}

// MARK: - Events timeline

struct EventsView: View {
    @EnvironmentObject private var client: BridgeClient

    var body: some View {
        Group {
            if client.events.isEmpty {
                ContentUnavailableView(
                    "Aucun événement",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Les détections (mouvement, personne, sonnette…) apparaîtront ici avec leur analyse IA.")
                )
            } else {
                List(client.events) { event in
                    EventRow(event: event)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Événements")
    }
}

struct EventRow: View {
    @EnvironmentObject private var client: BridgeClient
    let event: EventRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = client.eventSnapshotURL(for: event) {
                SnapshotImage(url: url)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.deviceName).font(.headline)
                    Text(event.kind)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                    if let level = event.analysis?.niveau_alerte {
                        Text(level.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(alertColor(level).opacity(0.2), in: Capsule())
                            .foregroundStyle(alertColor(level))
                    }
                    Spacer()
                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let analysis = event.analysis {
                    Text(analysis.resume)
                    HStack(spacing: 12) {
                        if analysis.personnes > 0 {
                            Label("\(analysis.personnes)", systemImage: "person.fill")
                        }
                        if analysis.vehicules > 0 {
                            Label("\(analysis.vehicules)", systemImage: "car.fill")
                        }
                        if analysis.animaux { Label("Animal", systemImage: "pawprint.fill") }
                        if analysis.colis { Label("Colis", systemImage: "shippingbox.fill") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let error = event.analysisError {
                    Text("Analyse impossible : \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Analyse en cours…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func alertColor(_ level: String) -> Color {
        switch level {
        case "alerte": return .red
        case "attention": return .orange
        default: return .secondary
        }
    }
}
