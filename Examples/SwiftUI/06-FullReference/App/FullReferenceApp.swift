import SwiftUI
import PolyMessaging

@main
struct FullReferenceApp: App {
    init() {
        // Initialize once at app launch — the only place the connection details
        // live. ContentView's resume / start-new flows use the no-arg facade
        // (chat(), start(), hasResumableSession()), which reuse this config.
        PolyMessaging.initialize(.init(
            connectorToken: "YOUR_CONNECTOR_TOKEN",
            environment: .dev,
            streamingEnabled: true,
            logLevel: .error
        ))
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
