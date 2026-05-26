//  RichContentApp.swift
//  Examples/SwiftUI/03-RichContent
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (SwiftUI)"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

@main
struct RichContentApp: App {
    init() {
        // Initialize once at app launch. After this, PolyMessaging.chat()
        // works anywhere in the app with no arguments.
        // Pre-filled with PolyAI dev environment — swap to your production
        // API key + a cluster (or .production) before shipping.
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
