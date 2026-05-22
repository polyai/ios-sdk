import Foundation

actor HeartbeatService {

    private var heartbeatTask: Task<Void, Never>?
    private var intervalSeconds: Int
    private let defaultIntervalSeconds: Int

    nonisolated let tick = Multicaster<Void>()

    init(intervalSeconds: Int = 30) {
        self.intervalSeconds = intervalSeconds
        self.defaultIntervalSeconds = intervalSeconds
    }

    func start(intervalSeconds: Int? = nil) {
        stop()
        if let i = intervalSeconds {
            // Server capability of 0 means "no heartbeat needed" — honour it as an
            // explicit disable. Distinguish from nil ("use default").
            if i == 0 { return }
            if i > 0 { self.intervalSeconds = i }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.intervalSeconds ?? 30)) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.tick.emit(())
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func setInterval(_ seconds: Int) {
        guard seconds > 0 else { return }
        intervalSeconds = seconds
        if heartbeatTask != nil {
            stop()
            start()
        }
    }

    func resetToDefaultInterval() {
        setInterval(defaultIntervalSeconds)
    }

    func destroy() {
        stop()
        tick.finish()
    }
}
