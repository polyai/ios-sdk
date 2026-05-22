import SwiftUI
import PolyMessaging

@main
struct PlaygroundApp: App {
    init() {
        // Initialize once at app launch. The playground rebuilds a fresh
        // Configuration from DevSettings on every connect, so this just primes a
        // sane default (the dev connector + environment).
        PolyMessaging.initialize(.init(
            connectorToken: ProcessInfo.processInfo.environment["POLY_CONNECTOR_TOKEN"] ?? "YOUR_CONNECTOR_TOKEN",
            environment: .dev
        ))
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
