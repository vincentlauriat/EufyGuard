import Foundation

/// Launches and supervises the local Node bridge if it isn't already running.
/// The bridge is intentionally NOT killed when the app quits, so surveillance
/// and AI analysis keep running in the background.
final class BridgeProcess {
    static let shared = BridgeProcess()

    private var process: Process?

    /// Bridge directory: configurable via UserDefaults "bridgePath",
    /// defaults to the development checkout.
    var bridgeDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "bridgePath"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevApps/Experimentations/EufyAnalysis/bridge")
    }

    func startIfNeeded() {
        Task.detached { [self] in
            if await isBridgeReachable() { return }
            await MainActor.run { launch() }
        }
    }

    private func isBridgeReachable() async -> Bool {
        var request = URLRequest(url: BridgeAPI.baseURL.appendingPathComponent("api/status"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func launch() {
        guard process == nil else { return }
        guard let node = findNode() else {
            NSLog("EufyGuard: node introuvable — lancer le bridge manuellement (npm start dans bridge/)")
            return
        }
        let entry = bridgeDirectory.appendingPathComponent("dist/index.js")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            NSLog("EufyGuard: bridge non compilé (%@)", entry.path)
            return
        }
        let proc = Process()
        proc.executableURL = node
        proc.arguments = [entry.path]
        proc.currentDirectoryURL = bridgeDirectory
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.process = nil
                self?.startIfNeeded()
            }
        }
        do {
            try proc.run()
            process = proc
            NSLog("EufyGuard: bridge lancé (pid %d)", proc.processIdentifier)
        } catch {
            NSLog("EufyGuard: échec lancement bridge: %@", error.localizedDescription)
        }
    }

    private func findNode() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
