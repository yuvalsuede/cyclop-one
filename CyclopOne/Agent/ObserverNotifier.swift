import Foundation

/// Utility struct for fire-and-forget observer notifications.
///
/// Replaces 8+ inline observer notification blocks scattered across Orchestrator
/// with a single, consistent notification pattern.
///
/// Uses a detached task with a 5-second timeout so slow Telegram I/O
/// (rate limits, network issues, offline) cannot stall the agent iteration loop.
///
/// Extracted from Orchestrator.swift in Sprint 3.
struct ObserverNotifier {

    /// Fire an observer callback without blocking the iteration loop.
    ///
    /// - Parameters:
    ///   - observer: The optional AgentObserver to notify. If nil, no-op.
    ///   - body: The async callback to execute on the observer.
    static func notify(
        _ observer: (any AgentObserver)?,
        _ body: @Sendable @escaping (any AgentObserver) async -> Void
    ) {
        guard let obs = observer else { return }
        Task.detached {
            let didTimeout = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                group.addTask { await body(obs); return false }
                group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); return true }
                let first = await group.next() ?? true
                group.cancelAll()
                return first
            }
            if didTimeout {
                NSLog("CyclopOne [ObserverNotifier]: Observer notification timed out after 5s — slow observer may be blocking")
            }
        }
    }

    /// Convenience: Notify observer of iteration start.
    static func notifyIterationStart(
        _ observer: (any AgentObserver)?,
        iteration: Int,
        maxIterations: Int
    ) {
        notify(observer) { obs in
            await obs.onIterationStart(iteration: iteration, maxIterations: maxIterations)
        }
    }

    /// Convenience: Notify observer of step start.
    static func notifyStepStart(
        _ observer: (any AgentObserver)?,
        stepIndex: Int,
        totalSteps: Int,
        title: String
    ) {
        notify(observer) { obs in
            await obs.onStepStart(stepIndex: stepIndex, totalSteps: totalSteps, title: title)
        }
    }

    /// Convenience: Notify observer of step completion.
    static func notifyStepComplete(
        _ observer: (any AgentObserver)?,
        stepIndex: Int,
        totalSteps: Int,
        title: String,
        outcome: String,
        screenshot: Data?
    ) {
        notify(observer) { obs in
            await obs.onStepComplete(
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                title: title,
                outcome: outcome,
                screenshot: screenshot
            )
        }
    }

    /// Convenience: Notify observer of an error.
    static func notifyError(
        _ observer: (any AgentObserver)?,
        error: String,
        screenshot: Data?,
        isFatal: Bool
    ) {
        notify(observer) { obs in
            await obs.onError(error: error, screenshot: screenshot, isFatal: isFatal)
        }
    }

    /// Convenience: Notify observer of run completion.
    static func notifyCompletion(
        _ observer: (any AgentObserver)?,
        success: Bool,
        summary: String,
        score: Int?,
        iterations: Int
    ) {
        notify(observer) { obs in
            await obs.onCompletion(success: success, summary: summary, score: score, iterations: iterations)
        }
    }
}
