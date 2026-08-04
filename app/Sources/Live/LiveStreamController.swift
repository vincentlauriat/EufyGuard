import Foundation
import CoreMedia

/// Connects to the bridge's /stream/<serial> WebSocket, feeds binary chunks to
/// the NALU decoder and publishes connection state for the UI.
@MainActor
final class LiveStreamController: ObservableObject {
    enum State: Equatable {
        case connecting
        case playing
        case error(String)
    }

    @Published var state: State = .connecting

    let decoder = NALUStreamDecoder()
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var receivedFirstSample = false

    func connect(serial: String) {
        closed = false
        receivedFirstSample = false
        state = .connecting
        decoder.reset()

        var components = URLComponents(url: BridgeClient.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.path = "/stream/\(serial)"
        let task = URLSession.shared.webSocketTask(with: components.url!)
        self.task = task
        task.resume()
        receiveLoop(task)
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func markSampleDisplayed() {
        if !receivedFirstSample {
            receivedFirstSample = true
            state = .playing
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .success(.data(let data)):
                    self.decoder.append(data)
                    self.receiveLoop(task)
                case .success(.string(let text)):
                    self.handleControlMessage(text)
                    self.receiveLoop(task)
                case .success:
                    self.receiveLoop(task)
                case .failure(let error):
                    if !self.closed {
                        self.state = .error("Connexion au flux perdue : \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handleControlMessage(_ text: String) {
        struct Control: Codable {
            var type: String
            var codec: String?
            var message: String?
        }
        guard let data = text.data(using: .utf8),
              let control = try? JSONDecoder().decode(Control.self, from: data) else { return }
        switch control.type {
        case "metadata":
            decoder.codec = control.codec == "h265" ? .h265 : .h264
        case "error":
            state = .error(control.message ?? "Erreur de flux")
        default:
            break
        }
    }
}
