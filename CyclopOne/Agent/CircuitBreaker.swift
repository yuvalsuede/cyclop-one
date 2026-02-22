import Foundation

/// Circuit breaker pattern for protecting against cascade failures.
///
/// States:
/// - **closed**: Normal operation. Calls pass through. Failures are counted.
/// - **open**: Failing state. All calls are immediately rejected with `CircuitBreakerError.open`.
/// - **halfOpen**: Testing state. One call is allowed through to test if the service has recovered.
///
/// Transitions:
/// - closed -> open: After `failureThreshold` consecutive failures.
/// - open -> halfOpen: After `cooldownInterval` has elapsed.
/// - halfOpen -> closed: On success.
/// - halfOpen -> open: On failure (resets the cooldown timer).
actor CircuitBreaker {

    // MARK: - Types

    enum State: Sendable, Equatable {
        case closed
        case open
        case halfOpen
    }

    enum CircuitBreakerError: LocalizedError, Sendable {
        case open(remainingCooldown: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .open(let remaining):
                return "Circuit breaker is open. Retry in \(Int(remaining))s."
            }
        }
    }

    // MARK: - Configuration

    /// Number of consecutive failures before the circuit opens.
    let failureThreshold: Int

    /// Time to wait before transitioning from open to halfOpen.
    let cooldownInterval: TimeInterval

    // MARK: - State

    private(set) var state: State = .closed
    private var consecutiveFailures: Int = 0
    private var lastFailureTime: Date?
    private var lastStateChange: Date = Date()

    // MARK: - Init

    init(failureThreshold: Int = 3, cooldownInterval: TimeInterval = 30) {
        self.failureThreshold = failureThreshold
        self.cooldownInterval = cooldownInterval
    }

    // MARK: - Execute

    /// Execute a unit of work through the circuit breaker.
    ///
    /// - In **closed** state: executes the work. On failure, increments failure count.
    ///   Opens the circuit after `failureThreshold` consecutive failures.
    /// - In **open** state: checks if cooldown has elapsed. If so, transitions to halfOpen
    ///   and allows the call. Otherwise, throws `CircuitBreakerError.open`.
    /// - In **halfOpen** state: allows exactly one call. On success, closes the circuit.
    ///   On failure, reopens it.
    func execute<T>(_ work: () async throws -> T) async throws -> T {
        switch state {
        case .open:
            // Check if cooldown period has elapsed
            if let lastFailure = lastFailureTime {
                let elapsed = Date().timeIntervalSince(lastFailure)
                if elapsed >= cooldownInterval {
                    // Transition to half-open: allow one test call
                    transitionTo(.halfOpen)
                } else {
                    throw CircuitBreakerError.open(remainingCooldown: cooldownInterval - elapsed)
                }
            } else {
                // No recorded failure time (shouldn't happen), transition to halfOpen
                transitionTo(.halfOpen)
            }
            // Fall through to execute in halfOpen state
            return try await executeInHalfOpen(work)

        case .halfOpen:
            return try await executeInHalfOpen(work)

        case .closed:
            return try await executeInClosed(work)
        }
    }

    // MARK: - Queries

    /// Whether the circuit breaker is currently allowing calls.
    var isAllowingCalls: Bool {
        switch state {
        case .closed, .halfOpen:
            return true
        case .open:
            if let lastFailure = lastFailureTime {
                return Date().timeIntervalSince(lastFailure) >= cooldownInterval
            }
            return true
        }
    }

    /// Current number of consecutive failures.
    var currentFailureCount: Int { consecutiveFailures }

    /// Manually reset the circuit breaker to closed state.
    func reset() {
        consecutiveFailures = 0
        lastFailureTime = nil
        transitionTo(.closed)
    }

    // MARK: - Private

    private func executeInClosed<T>(_ work: () async throws -> T) async throws -> T {
        do {
            let result = try await work()
            recordSuccess()
            return result
        } catch {
            recordFailure()
            throw error
        }
    }

    private func executeInHalfOpen<T>(_ work: () async throws -> T) async throws -> T {
        do {
            let result = try await work()
            // Success in halfOpen: circuit recovers
            recordSuccess()
            transitionTo(.closed)
            return result
        } catch {
            // Failure in halfOpen: reopen the circuit
            recordFailure()
            transitionTo(.open)
            throw error
        }
    }

    private func recordSuccess() {
        consecutiveFailures = 0
        lastFailureTime = nil
    }

    private func recordFailure() {
        consecutiveFailures += 1
        lastFailureTime = Date()

        if state == .closed && consecutiveFailures >= failureThreshold {
            transitionTo(.open)
        }
    }

    private func transitionTo(_ newState: State) {
        guard state != newState else { return }
        state = newState
        lastStateChange = Date()
    }
}
