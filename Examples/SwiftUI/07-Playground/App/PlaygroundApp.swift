import SwiftUI
import PolyMessaging

@main
struct PlaygroundApp: App {
    init() {
        // Initialize once at app launch. The playground rebuilds a fresh
        // Configuration from DevSettings on every connect, so this just primes a
        // sane default (the dev connector + environment).
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_API_KEY",
            environment: .dev
        ))
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
