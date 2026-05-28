// Copyright PolyAI Limited

//  ResilienceApp.swift
//  Examples/SwiftUI/04-Resilience
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (SwiftUI)"
//

import SwiftUI
import PolyMessaging

@main
struct ResilienceApp: App {
    init() {
        // Initialize once at app launch. After this, PolyMessaging.chat()
        // works anywhere in the app with no arguments.
        // Replace with your production
        // API key + a cluster (or .production) before shipping.
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_API_KEY",
            environment: .production
        ))
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
