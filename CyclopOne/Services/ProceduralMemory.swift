import Foundation

// MARK: - Core Structs

/// A single step in a procedural memory sequence.
struct ProceduralMemoryStep: Codable {
    var stepIndex: Int
    var action: String
    var rationale: String?
    var alternativeIfFails: String?
    var confirmedWorking: Bool
    var failureCount: Int

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case action, rationale
        case alternativeIfFails = "alternative_if_fails"
        case confirmedWorking = "confirmed_working"
        case failureCount = "failure_count"
    }
}

/// A known failure pattern for an app/task type.
struct KnownTrap: Codable {
    var trapId: String
    var description: String
    var detectionSignal: String
    var recovery: String

    enum CodingKeys: String, CodingKey {
        case trapId = "trap_id"
        case description
        case detectionSignal = "detection_signal"
        case recovery
    }
}

/// A discriminated screen state pattern for recognising UI states.
struct ScreenStatePattern: Codable {
    var stateId: String
    var discriminators: [String]
    var description: String

    enum CodingKeys: String, CodingKey {
        case stateId = "state_id"
        case discriminators, description
    }
}

/// A single run's entry in the episodic history of a procedural memory.
struct ProceduralEpisodicEntry: Codable {
    var runId: String
    var timestamp: Date
    var success: Bool
    var iterations: Int
    var approachSummary: String
    var failureEncountered: String?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case timestamp, success, iterations
        case approachSummary = "approach_summary"
        case failureEncountered = "failure_encountered"
    }
}

/// Persistent procedural memory for a specific app + task type combination.
/// Stored as JSON at `~/.cyclopone/procedural/<app>/<task_type>.json`.
struct ProceduralMemory: Codable {
    var schemaVersion: Int = 1
    var app: String
    var appURL: String?
    var taskType: String
    var triggerPatterns: [String]
    var lastUpdated: Date
    var successCount: Int = 0
    var failureCount: Int = 0
    var avgIterations: Double = 0
    var reliabilityScore: Double = 0.5
    var steps: [ProceduralMemoryStep]
    var knownTraps: [KnownTrap]
    var screenStatePatterns: [ScreenStatePattern]
    var episodicHistory: [ProceduralEpisodicEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case app
        case appURL = "app_url"
        case taskType = "task_type"
        case triggerPatterns = "trigger_patterns"
        case lastUpdated = "last_updated"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case avgIterations = "avg_iterations"
        case reliabilityScore = "reliability_score"
        case steps
        case knownTraps = "known_traps"
        case screenStatePatterns = "screen_state_patterns"
        case episodicHistory = "episodic_history"
    }

    /// True once at least one run (success or failure) has been recorded.
    var hasValidData: Bool { successCount + failureCount >= 1 }

    /// Format this memory as a compact (~250 token) string for injection into the system prompt.
    func formatForPrompt() -> String {
        let pct = Int(reliabilityScore * 100)
        let avgIter = avgIterations > 0 ? String(format: "%.0f", avgIterations) : "?"

        var lines: [String] = [
            "\(app.uppercased()) — \(taskType.uppercased().replacingOccurrences(of: "_", with: " "))",
            "(reliability: \(pct)%, avg \(avgIter) iterations)",
            "",
            "STEPS:"
        ]

        for step in steps.sorted(by: { $0.stepIndex < $1.stepIndex }) {
            var line = "\(step.stepIndex + 1). \(step.action)"
            if let alt = step.alternativeIfFails, !alt.isEmpty {
                line += " — if fails: \(alt)"
            }
            lines.append(line)
        }

        if !knownTraps.isEmpty {
            lines.append("")
            lines.append("KNOWN TRAPS:")
            for trap in knownTraps {
                lines.append("- If \"\(trap.detectionSignal)\": \(trap.recovery)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Learning Events

/// Events emitted during a run that feed the post-run consolidation pipeline.
enum LearningEvent: Sendable {
    case trapEncountered(app: String, taskType: String, trapSignal: String, action: String, recovery: String?)
    case stepSucceeded(app: String, taskType: String, stepDescription: String, iterationIndex: Int)
    case stepFailed(app: String, taskType: String, stepDescription: String, errorDescription: String)
    case shortcutDiscovered(app: String, shortcutDescription: String)
}

// MARK: - Consolidation Learning (LLM extraction output)

/// Structured learning extracted by Haiku from a completed run.
struct ConsolidationLearning: Codable {
    /// "step_update" | "trap_discovered" | "shortcut_found" | "step_failed"
    var type: String
    var stepIndex: Int?
    var description: String
    var detectionSignal: String?
    var recovery: String?

    enum CodingKeys: String, CodingKey {
        case type
        case stepIndex = "step_index"
        case description
        case detectionSignal = "detection_signal"
        case recovery
    }
}
