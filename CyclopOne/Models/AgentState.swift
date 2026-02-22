import Foundation

/// Tracks the current state of the agent.
enum AgentState: Equatable {
    case idle
    case listening            // Panel open, waiting for user input
    case capturing            // Taking screenshot / reading accessibility tree
    case thinking             // Waiting for Claude API response
    case executing(String)    // Running a tool (description)
    case awaitingConfirmation(String) // Waiting for user to approve action
    case error(String)        // Something went wrong
    case done                 // Task completed

    var displayText: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .capturing: return "Observing screen…"
        case .thinking: return "Thinking…"
        case .executing(let action): return "Executing: \(action)"
        case .awaitingConfirmation(let action): return "Confirm: \(action)?"
        case .error(let msg): return "Error: \(msg)"
        case .done: return "Done"
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .listening, .done, .error: return false
        default: return true
        }
    }
}

/// Configuration for the agent's behavior.
struct AgentConfig {
    var maxIterations: Int = 20
    var toolTimeout: TimeInterval = 30
    var shellTimeout: TimeInterval = 60
    /// Max pixel dimension for screenshot scaling. Anthropic API accepts images up to
    /// ~8000px on the long edge. On Retina Macs, physical pixels are 2x logical points,
    /// so a 1512-point-wide display is 3024 physical pixels. Using 2048 preserves enough
    /// detail for Claude to read on-screen text clearly without excessive payload size.
    /// Previous value of 1568 caused aggressive downscaling on Retina displays,
    /// making text unreadable to Claude's vision.
    var screenshotMaxDimension: Int = 2048
    var screenshotJPEGQuality: Double = 0.8
    var confirmDestructiveActions: Bool = true
    var modelName: String = {
        let saved = UserDefaults.standard.string(forKey: "selectedModel")
        return (saved?.isEmpty == false) ? saved! : "claude-sonnet-4-6"
    }()
    var permissionMode: PermissionMode = .standard

    /// Click down/up delay in microseconds. Default 150ms (GFX-H2 fix: was 50ms).
    var clickDelayMicroseconds: useconds_t = 150_000

    /// Drag intermediate steps (GFX-H3 fix: was 10, now 30 for smoother drags).
    var dragSteps: Int = 30

    /// Drag dwell time per step in microseconds.
    var dragDwellMicroseconds: useconds_t = 20_000

    /// Legacy destructive patterns — kept for backward compatibility.
    /// The PermissionClassifier is the preferred approach.
    var destructivePatterns: [String] = [
        "rm ", "rm -", "rmdir", "delete", "trash",
        "sudo", "format", "mkfs", "dd if=",
        "DROP ", "DELETE FROM", "TRUNCATE",
        "shutdown", "reboot", "kill -9"
    ]

    func isDestructive(_ command: String) -> Bool {
        let lower = command.lowercased()
        return destructivePatterns.contains { lower.contains($0.lowercased()) }
    }
}
