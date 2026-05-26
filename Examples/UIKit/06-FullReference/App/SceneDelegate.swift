// Copyright PolyAI Limited

//  SceneDelegate.swift
//  Examples/UIKit/06-FullReference
//
//  Programmatic root: a UINavigationController wrapping RootViewController,
//  the container that swaps between the connect / loading / chat / error
//  screens and owns the single ChatSession across them. No storyboard.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let nav = UINavigationController(rootViewController: RootViewController())
        nav.navigationBar.prefersLargeTitles = false
        window.rootViewController = nav
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}
