//  AppDelegate.swift
//  Examples/UIKit/03-RichContent
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (UIKit)"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

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
        // Pre-filled with PolyAI dev environment — swap to your production
        // connector token + a cluster (or .production) before shipping.
        PolyMessaging.initialize(.init(
            connectorToken: ProcessInfo.processInfo.environment["POLY_CONNECTOR_TOKEN"] ?? "YOUR_CONNECTOR_TOKEN",
            environment: .dev
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
