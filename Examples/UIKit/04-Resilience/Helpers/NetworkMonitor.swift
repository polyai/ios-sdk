// Copyright PolyAI Limited

//  NetworkMonitor.swift
// Examples/UIKit/04-Resilience
//
//  Mirrors README:
//    - § "What you can build > Connection monitoring"
//

import Foundation
import Network
import Combine

/// Lightweight wrapper around NWPathMonitor that publishes online/offline
/// state on the main queue via `@Published`. The SDK does its own reconnection,
/// but apps should still surface device-level connectivity to users.
final class NetworkMonitor {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "poly.example.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
