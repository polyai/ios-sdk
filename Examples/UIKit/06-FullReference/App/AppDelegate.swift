// Copyright PolyAI Limited

//  AppDelegate.swift
//  Examples/UIKit/06-FullReference
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
        // Initialize once at app launch — the only place the connection details
        // live. The connect screen and resume / start-new flows use the no-arg
        // facade (chat(), start(), hasResumableSession()), which reuse this config.
        PolyMessaging.initialize(.init(
            connectorToken: "YOUR_CONNECTOR_TOKEN",
            environment: .dev,
            streamingEnabled: true,
            logLevel: .error
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
