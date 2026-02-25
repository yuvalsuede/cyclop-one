import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor.
///
/// Detects offline state proactively so the Orchestrator can pause
/// iterations instead of burning circuit breaker retries on network errors.
actor NetworkMonitor {

    static let shared = NetworkMonitor()

    /// Whether the network is currently reachable.
    private(set) var isReachable: Bool = true

    /// The current network path status.
    private(set) var currentStatus: NWPath.Status = .satisfied

    /// Timestamp of the last status change.
    private(set) var lastStatusChange: Date = Date()

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.cyclop.one.network-monitor", qos: .utility)

    /// Start monitoring network connectivity.
    /// Safe to call multiple times — subsequent calls are no-ops.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            Task {
                await self.updatePath(path)
            }
        }
        monitor.start(queue: queue)
        NSLog("CyclopOne [NetworkMonitor]: Started monitoring")
    }

    /// Stop monitoring. Called on app termination.
    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// Wait for network to become reachable, up to the given timeout.
    /// Returns true if reachable, false if timeout elapsed.
    func waitForReachability(timeout: TimeInterval = 30) async -> Bool {
        if isReachable { return true }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReachable { return true }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
        return isReachable
    }

    // MARK: - Private

    private func updatePath(_ path: NWPath) {
        let wasReachable = isReachable
        currentStatus = path.status
        isReachable = path.status == .satisfied

        if wasReachable != isReachable {
            lastStatusChange = Date()
            if isReachable {
                NSLog("CyclopOne [NetworkMonitor]: Network reachable (status: %@)", "\(path.status)")
            } else {
                NSLog("CyclopOne [NetworkMonitor]: Network UNREACHABLE (status: %@)", "\(path.status)")
            }
        }
    }
}
