// Copyright PolyAI Limited

//  AppDelegate.swift
//  Examples/UIKit/01-Hello
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (UIKit)"
//

import UIKit
import PolyMessaging

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Initialize once at app launch. After this, PolyMessaging.chat()
        // works anywhere in the app with no arguments.
        // Replace YOUR_API_KEY with your connector token from Agent Studio.
        // API key + a cluster (or .production) before shipping.
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_API_KEY",
            environment: .production
        ))
        // UITests pass -uiTestFreshStart to force a brand-new greeting +
        // suggestions instead of resuming a prior conversation.
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}
}
