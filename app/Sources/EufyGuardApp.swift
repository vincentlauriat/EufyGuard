import SwiftUI

@main
struct EufyGuardApp: App {
    @StateObject private var client = BridgeClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    BridgeProcess.shared.startIfNeeded()
                    client.start()
                }
        }
        .windowStyle(.automatic)
    }
}
