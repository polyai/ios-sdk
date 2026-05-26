import SwiftUI
import PolyMessaging

@main
struct FullReferenceApp: App {
    init() {
        // Initialize once at app launch — the only place the connection details
        // live. ContentView's resume / start-new flows use the no-arg facade
        // (chat(), start(), hasResumableSession()), which reuse this config.
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_API_KEY",
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
