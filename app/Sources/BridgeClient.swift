import Foundation
import Combine

enum BridgeAPI {
    static let baseURL = URL(string: "http://127.0.0.1:8791")!
}

@MainActor
final class BridgeClient: ObservableObject {
    static var baseURL: URL { BridgeAPI.baseURL }

    @Published var status: BridgeStatus?
    @Published var devices: [DeviceInfo] = []
    @Published var stations: [StationInfo] = []
    @Published var events: [EventRecord] = []
    @Published var chat: [ChatMessage] = []
    @Published var isReachable = false
    @Published var chatBusy = false

    let notifications = NotificationManager()
    private var wsTask: URLSessionWebSocketTask?
    private var refreshTimer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        return URLSession(configuration: config)
    }()

    func start() {
        notifications.requestAuthorization()
        connectWebSocket()
        Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        do {
            let status: BridgeStatus = try await get("/api/status")
            self.status = status
            self.isReachable = true
            self.devices = (try? await get("/api/devices") as [DeviceInfo]) ?? devices
            self.stations = (try? await get("/api/stations") as [StationInfo]) ?? stations
            self.events = (try? await get("/api/events?limit=200") as [EventRecord]) ?? events
        } catch {
            self.isReachable = false
        }
    }

    // MARK: - Actions

    func sendConfig(username: String, password: String, country: String, anthropicApiKey: String) async throws {
        try await post("/api/config", body: [
            "username": username,
            "password": password,
            "country": country,
            "anthropicApiKey": anthropicApiKey,
        ])
        await refresh()
    }

    func submitCaptcha(id: String, code: String) async throws {
        try await post("/api/captcha", body: ["captchaId": id, "code": code])
        await refresh()
    }

    func submitTfa(code: String) async throws {
        try await post("/api/tfa", body: ["code": code])
        await refresh()
    }

    func panTilt(device: DeviceInfo, direction: String) async {
        try? await post("/api/devices/\(device.serial)/ptz", body: ["direction": direction])
    }

    func setGuardMode(station: StationInfo, mode: Int) async {
        try? await post("/api/stations/\(station.serial)/guard", body: ["mode": String(mode)])
        await refresh()
    }

    func requestDigest(hours: Int = 24) async {
        chat.append(ChatMessage(role: "user", text: "🗞️ Résumé des \(hours) dernières heures"))
        chatBusy = true
        defer { chatBusy = false }
        do {
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/digest"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["hours": String(hours)])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                throw BridgeError.api(detail ?? "Erreur du bridge")
            }
            let payload = try JSONDecoder().decode([String: String].self, from: data)
            chat.append(ChatMessage(role: "assistant", text: payload["answer"] ?? ""))
        } catch {
            chat.append(ChatMessage(role: "error", text: "Erreur : \(error.localizedDescription)"))
        }
    }

    func sendChat(_ message: String) async {
        chat.append(ChatMessage(role: "user", text: message))
        chatBusy = true
        defer { chatBusy = false }
        do {
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["message": message])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                throw BridgeError.api(detail ?? "Erreur du bridge")
            }
            let payload = try JSONDecoder().decode([String: String].self, from: data)
            chat.append(ChatMessage(role: "assistant", text: payload["answer"] ?? ""))
        } catch {
            chat.append(ChatMessage(role: "error", text: "Erreur : \(error.localizedDescription)"))
        }
    }

    func snapshotURL(for device: DeviceInfo) -> URL {
        Self.baseURL.appendingPathComponent("api/devices/\(device.serial)/snapshot")
    }

    func eventSnapshotURL(for event: EventRecord) -> URL? {
        guard event.snapshotFile != nil else { return nil }
        return Self.baseURL.appendingPathComponent("api/events/\(event.id)/snapshot")
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.path = "/ws"
        let task = session.webSocketTask(with: components.url!)
        wsTask = task
        task.resume()
        receiveLoop(task)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8) {
                        self.handleWSMessage(data)
                    }
                    self.receiveLoop(task)
                case .failure:
                    self.isReachable = false
                    try? await Task.sleep(for: .seconds(5))
                    self.connectWebSocket()
                }
            }
        }
    }

    private func handleWSMessage(_ data: Data) {
        struct Envelope: Codable {
            var type: String
            var event: EventRecord?
            var status: BridgeStatus?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        switch envelope.type {
        case "event":
            if let event = envelope.event {
                events.insert(event, at: 0)
            }
        case "event_updated":
            if let event = envelope.event {
                if let index = events.firstIndex(where: { $0.id == event.id }) {
                    events[index] = event
                } else {
                    events.insert(event, at: 0)
                }
                if let analysis = event.analysis, analysis.niveau_alerte != "info" {
                    let title = analysis.niveau_alerte == "alerte"
                        ? "🚨 ALERTE — \(event.deviceName)"
                        : "⚠️ \(event.deviceName)"
                    notifications.post(title: title, body: analysis.resume)
                } else if event.analysis == nil {
                    notifications.post(title: event.deviceName, body: "Événement : \(event.kind)")
                }
            }
        case "status":
            if let status = envelope.status { self.status = status }
        case "devices_changed":
            Task { await refresh() }
        default:
            break
        }
    }

    // MARK: - HTTP helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: path, relativeTo: Self.baseURL)!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, body: [String: String]) async throws {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw BridgeError.api(detail ?? "Erreur du bridge")
        }
    }
}

enum BridgeError: LocalizedError {
    case api(String)
    var errorDescription: String? {
        if case .api(let message) = self { return message }
        return nil
    }
}
