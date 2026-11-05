// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging

@main
struct FullReferenceApp: App {
    init() {
        // Initialize once at app launch — the only place the connection details
        // live. ContentView's resume / start-new flows use the no-arg facade
        // (chat(), start(), hasResumableSession()), which reuse this config.
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_CONNECTOR_TOKEN",
            environment: .us,
            streamingEnabled: true,
            logLevel: .error
            // Verified context (README § "Verified context"): add
            //   onContextRequired: { request in try await yourBackend.sign(request.contextId) }
            // and call session.refreshVerifiedContext() after a mid-chat sign-in.
            // Left out here so the sample takes the zero-delay path.
        ))
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
