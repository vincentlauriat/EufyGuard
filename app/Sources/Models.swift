import Foundation

struct BridgeStatus: Codable, Equatable {
    var state: String
    var configured: Bool
    var agentEnabled: Bool
    var lastError: String?
    var captcha: Captcha?

    struct Captcha: Codable, Equatable {
        var id: String
        var image: String
    }

    var stateLabel: String {
        switch state {
        case "unconfigured": return "Non configuré"
        case "connecting": return "Connexion…"
        case "captcha": return "Captcha requis"
        case "tfa": return "Code 2FA requis"
        case "connected": return "Connecté"
        case "error": return "Erreur"
        default: return state
        }
    }
}

struct DeviceInfo: Codable, Identifiable, Hashable {
    var serial: String
    var name: String
    var model: String
    var stationSerial: String
    var hasBattery: Bool
    var battery: Int?
    var enabled: Bool
    var canPanTilt: Bool?

    var id: String { serial }
    var isPTZ: Bool { canPanTilt ?? false }
}

struct Analysis: Codable, Hashable {
    var resume: String
    var personnes: Int
    var vehicules: Int
    var animaux: Bool
    var colis: Bool
    var niveau_alerte: String
}

struct EventRecord: Codable, Identifiable, Hashable {
    var id: String
    var ts: Double
    var deviceSn: String
    var deviceName: String
    var kind: String
    var snapshotFile: String?
    var analysis: Analysis?
    var analysisError: String?

    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
}

struct StationInfo: Codable, Identifiable, Hashable {
    var serial: String
    var name: String
    var model: String
    var guardMode: Int

    var id: String { serial }

    static let modes: [(value: Int, label: String, icon: String)] = [
        (1, "Domicile", "house.fill"),
        (0, "Absent", "figure.walk.departure"),
        (2, "Programmé", "calendar"),
        (63, "Désarmé", "shield.slash"),
    ]

    var modeLabel: String {
        Self.modes.first(where: { $0.value == guardMode })?.label ?? "Mode \(guardMode)"
    }
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    var role: String // "user" | "assistant" | "error"
    var text: String
}
