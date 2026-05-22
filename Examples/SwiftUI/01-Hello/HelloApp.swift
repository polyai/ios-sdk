//  HelloApp.swift
//  Examples/SwiftUI/01-Hello
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (SwiftUI)"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

@main
struct HelloApp: App {
    init() {
        // Initialize once at app launch. After this, PolyMessaging.chat()
        // works anywhere in the app with no arguments.
        // Pre-filled with PolyAI dev environment — swap to your production
        // connector token + a cluster (or .production) before shipping.
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
