// Copyright PolyAI Limited

//  StandardApp.swift
//  Examples/SwiftUI/02-Standard
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (SwiftUI)"
//

import SwiftUI
import PolyMessaging

@main
struct StandardApp: App {
    init() {
        // Initialize once at app launch. After this, PolyMessaging.chat()
        // works anywhere in the app with no arguments.
        // Replace YOUR_API_KEY with your connector token from Agent Studio.
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_API_KEY"
        ))
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
