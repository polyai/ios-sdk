import Foundation
import Network

final class NetworkMonitor: @unchecked Sendable {

    let networkRestored = Multicaster<Void>()
    let networkLost = Multicaster<Void>()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.poly.messaging.network")
    private let lock = NSLock()
    private var previousStatus: NWPath.Status = .satisfied
    private var _currentlyOnline: Bool = true
    private var pollTimer: DispatchSourceTimer?
    private var _wasOffline: Bool = false

    var currentlyOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _currentlyOnline
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let newStatus = path.status

            self.lock.lock()
            let wasOnline = self._currentlyOnline
            self._currentlyOnline = (newStatus == .satisfied)
            self.lock.unlock()

            if self.previousStatus != .satisfied && newStatus == .satisfied {
                self.stopPolling()
                self.networkRestored.emit(())
            } else if self.previousStatus == .satisfied && newStatus != .satisfied {
                self.networkLost.emit(())
                self.startPolling()
            }

            self.previousStatus = newStatus
        }
        monitor.start(queue: queue)
    }

    func stop() {
        stopPolling()
        monitor.cancel()
    }

    // NWPathMonitor can miss restore callbacks on some devices/simulator.
    // Poll every 3s while offline and emit networkRestored if status flips.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let path = self.monitor.currentPath
            if path.status == .satisfied && self.previousStatus != .satisfied {
                self.lock.lock()
                self._currentlyOnline = true
                self.lock.unlock()
                self.previousStatus = .satisfied
                self.stopPolling()
                self.networkRestored.emit(())
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}
