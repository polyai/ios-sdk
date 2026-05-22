//  StandardApp.swift
//  Examples/SwiftUI/02-Standard
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (SwiftUI)"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

@main
struct StandardApp: App {
    init() {
        // Initialize once at app launch. After this, PolyMessaging.chat()
        // works anywhere in the app with no arguments.
        // Pre-filled with PolyAI dev environment — swap to your production
        // connector token + a cluster (or .production) before shipping.
        PolyMessaging.initialize(.init(
            connectorToken: "YOUR_CONNECTOR_TOKEN",
            environment: .dev
        ))
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
