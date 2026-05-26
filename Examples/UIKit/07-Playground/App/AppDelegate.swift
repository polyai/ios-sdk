// Copyright PolyAI Limited

//  AppDelegate.swift
//  Examples/UIKit/07-Playground
//
//  Mirrors README:
//    - § "Get started > Initialize once at app launch (UIKit)"
//
//  The playground rebuilds a fresh Configuration from DevSettings on every
//  connect, so initialize() here just primes a sane default (the connect /
//  start paths pass an explicit config built by DevSettings).
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
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_API_KEY",
            environment: .dev,
            streamingEnabled: true,
            logLevel: .debug
        ))
        // UITests pass -uiTestFreshStart to force a brand-new greeting +
        // suggestions instead of resuming a prior conversation.
        if CommandLine.arguments.contains("-uiTestFreshStart") { PolyMessaging.clearResumableSession() }
        return true
    }

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
