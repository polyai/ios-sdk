import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class AppLifecycleObserver: @unchecked Sendable {

    let foreground = Multicaster<Void>()

    private var observers: [NSObjectProtocol] = []

    func start() {
        #if canImport(UIKit) && !os(watchOS)
        let fgObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.foreground.emit(())
        }
        observers.append(fgObserver)
        #endif
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        stop()
    }
}
