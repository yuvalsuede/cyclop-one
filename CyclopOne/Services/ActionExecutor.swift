import Foundation
import AppKit

/// Sprint 7: Configurable timing for UI actions (click, drag, typing).
struct ActionTimingConfig {
    /// Delay before a click event (nanoseconds). Default 50ms.
    var clickDelayBefore: UInt64 = 50_000_000
    /// Delay after a click event (nanoseconds). Default 500ms.
    var clickDelayAfter: UInt64 = 500_000_000
    /// Number of intermediate drag steps. Default 30.
    var dragSteps: Int = 30
    /// Delay per drag step (microseconds). Default 20ms.
    var dragStepDelayMicroseconds: useconds_t = 20_000
    /// Delay between typed characters (nanoseconds per char). Default 15ms.
    var typingDelayPerChar: UInt64 = 15_000_000
    /// Minimum typing settle time (nanoseconds). Default 200ms.
    var typingMinSettle: UInt64 = 200_000_000
    /// Delay after key press (nanoseconds). Default 300ms.
    var keyPressDelay: UInt64 = 300_000_000
}

/// Executes actions on the OS: shell commands, AppleScript, UI clicks, keyboard input.
/// Integrates with PermissionClassifier for tiered autonomy.
actor ActionExecutor {

    static let shared = ActionExecutor()

    private let accessibility = AccessibilityService.shared
    private let capture = ScreenCaptureService.shared

    /// Tier 2 categories that have been approved for the current session.
    private var sessionApprovals: Set<PermissionClassifier.Tier2Category> = []

    /// Callback for requesting user approval. Set by the AgentLoop before each run.
    /// Returns true if approved, false if denied.
    private var approvalHandler: ((String) async -> Bool)?

    /// Current permission mode.
    private var permissionMode: PermissionMode = .standard

    /// Sprint 7: Configurable action timing.
    private(set) var timing: ActionTimingConfig = ActionTimingConfig()

    private init() {}

    // MARK: - Session Management

    /// Reset session approvals (called at the start of each new top-level task).
    func resetSessionApprovals() {
        sessionApprovals.removeAll()
    }

    /// Set the approval handler for the current run.
    func setApprovalHandler(_ handler: @escaping (String) async -> Bool) {
        self.approvalHandler = handler
    }

    /// Set the permission mode.
    func setPermissionMode(_ mode: PermissionMode) {
        self.permissionMode = mode
    }

    /// Sprint 7: Update action timing configuration.
    func setTiming(_ newTiming: ActionTimingConfig) {
        self.timing = newTiming
    }

    /// Sprint 7: Take a multi-monitor aware verification screenshot at a specific point.
    /// Uses the per-screen capture to get the screen containing the given coordinates.
    func captureVerificationScreenshot(at point: CGPoint, maxDimension: Int = 1568, quality: Double = 0.8) async throws -> ScreenCapture {
        return try await capture.captureScreen(containing: point, maxDimension: maxDimension, quality: quality)
    }

    // MARK: - Shell Command Sanitization (Sprint 17)

    /// Dangerous shell patterns that should be outright rejected regardless of permission tier.
    /// These patterns indicate command injection or catastrophic destruction.
    private static let rejectedPatterns: [(pattern: String, reason: String)] = [
        ("rm -rf /", "Recursive deletion of root filesystem"),
        ("rm -rf /*", "Recursive deletion of root filesystem contents"),
        ("rm -rf ~", "Recursive deletion of home directory"),
        ("rm -rf ~/", "Recursive deletion of home directory"),
        (":(){:|:&};:", "Fork bomb"),
        (">(){ >|>&};>", "Fork bomb variant"),
        ("mkfs.", "Filesystem formatting"),
        ("dd if=/dev/zero of=/dev/", "Direct disk overwrite"),
        ("dd if=/dev/random of=/dev/", "Direct disk overwrite"),
        ("chmod -R 777 /", "Recursive global permission change at root"),
        ("chown -R", "Recursive ownership change"),
    ]

    /// Characters that must be escaped when appearing in shell arguments.
    private static let shellSpecialChars = CharacterSet(charactersIn: "`$\"\\!#&|;(){}[]<>*?~\n\r")

    /// Regex patterns for dangerous shell constructs that bypass naive string matching.
    /// These detect injection vectors like path traversal, variable expansion,
    /// backtick execution, and encoded characters.
    /// Pre-compiled at load time to avoid per-call regex compilation overhead.
    private static let dangerousRegexPatterns: [(regex: NSRegularExpression, reason: String)] = {
        let patterns: [(String, String)] = [
            (#"(\.\./|\.\.\\|%2e%2e%2f|%2e%2e/|\.\.%2f|%2e%2e%5c)"#, "Path traversal detected"),
            (#"\$\{[^}]*\}"#, "Variable expansion (${}) detected"),
            (#"\$\([^)]*\)"#, "Command substitution $() detected"),
            (#"`[^`]+`"#, "Backtick command execution detected"),
            (#"\\x[0-9a-fA-F]{2}"#, "Hex-encoded character detected"),
            (#"\\[0-7]{1,3}"#, "Octal-encoded character detected"),
            (#"[<>]\([^)]*\)"#, "Process substitution detected"),
        ]
        return patterns.compactMap { pattern, reason in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (regex, reason)
        }
    }()

    /// Normalize a command string for consistent security checks.
    /// Collapses whitespace and resolves obvious path traversal.
    private static func normalizeCommand(_ command: String) -> String {
        var normalized = command
        // Collapse multiple whitespace to single space
        normalized = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // Resolve path traversal: /foo/../bar → /bar
        while normalized.contains("/../") {
            guard let range = normalized.range(of: #"/[^/]+/\.\./"#, options: .regularExpression) else { break }
            normalized = normalized.replacingCharacters(in: range, with: "/")
        }
        return normalized
    }

    /// Sanitize a shell command string by validating and escaping.
    /// Returns the sanitized command or throws if the command contains rejected patterns.
    ///
    /// Sprint 17: Uses regex-based detection for path traversal, variable expansion,
    /// backtick execution, and encoded characters. Normalizes the command before checking.
    static func sanitizeShellCommand(_ command: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reject empty commands
        guard !trimmed.isEmpty else {
            throw ShellSanitizationError.emptyCommand
        }

        // Reject null bytes (command injection vector)
        if trimmed.contains("\0") {
            throw ShellSanitizationError.rejectedPattern("Null byte injection detected")
        }

        // Reject excessively long commands (potential buffer overflow / abuse)
        if trimmed.count > 10_000 {
            throw ShellSanitizationError.commandTooLong
        }

        // Normalize for consistent pattern matching
        let normalized = normalizeCommand(trimmed)
        let lower = normalized.lowercased()

        // Reject commands that match catastrophic patterns (normalized)
        for (pattern, reason) in rejectedPatterns {
            let normalizedPattern = pattern.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if lower.contains(normalizedPattern) {
                throw ShellSanitizationError.rejectedPattern(reason)
            }
        }

        // Sprint 17: Regex-based detection for injection vectors (pre-compiled)
        for (regex, reason) in dangerousRegexPatterns {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if regex.firstMatch(in: trimmed, range: range) != nil {
                throw ShellSanitizationError.rejectedPattern(reason)
            }
        }

        // Return the validated command as-is. The command is passed to
        // Process.arguments = ["-c", command] which doesn't go through
        // shell expansion, so additional escaping would break execution.
        return trimmed
    }

    /// Escape a single argument for safe inclusion in a shell command.
    /// Wraps the argument in single quotes and escapes any embedded single quotes.
    static func escapeShellArgument(_ argument: String) -> String {
        // Single-quote escaping: replace ' with '\''
        let escaped = argument.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Scoped CGEvent Taps (Sprint 17)

    /// Create a scoped CGEvent tap that only listens to specific event types
    /// instead of tapping all events. This reduces attack surface and improves performance.
    ///
    /// - Parameters:
    ///   - eventTypes: The specific event types to tap (e.g., .keyDown, .leftMouseDown)
    ///   - callback: The event tap callback
    /// - Returns: A CFMachPort for the event tap, or nil if creation failed
    static func createScopedEventTap(
        for eventTypes: [CGEventType],
        callback: @escaping CGEventTapCallBack
    ) -> CFMachPort? {
        // Build the event mask from only the specified event types
        var eventMask: CGEventMask = 0
        for eventType in eventTypes {
            eventMask |= (1 << eventType.rawValue)
        }

        // Create the tap with the scoped mask instead of kCGEventMaskForAllEvents.
        // Sprint 17: Use .listenOnly for monitoring — events are observed but not
        // intercepted or modified, reducing attack surface.
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        return tap
    }

    /// Convenience: Create an event tap scoped to keyboard events only.
    static func createKeyboardEventTap(callback: @escaping CGEventTapCallBack) -> CFMachPort? {
        return createScopedEventTap(
            for: [.keyDown, .keyUp, .flagsChanged],
            callback: callback
        )
    }

    /// Convenience: Create an event tap scoped to mouse events only.
    static func createMouseEventTap(callback: @escaping CGEventTapCallBack) -> CFMachPort? {
        return createScopedEventTap(
            for: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved, .scrollWheel],
            callback: callback
        )
    }

    // MARK: - Permission-Aware Shell Commands

    /// Execute a shell command with tiered permission checks and sanitization.
    func runShellCommand(_ command: String, timeout: TimeInterval = 60) async throws -> ShellResult {
        // Sprint 17: Sanitize command before execution
        let sanitizedCommand = try Self.sanitizeShellCommand(command)

        // Classify the command
        let tier = PermissionClassifier.classify(sanitizedCommand)

        switch tier {
        case .tier1:
            // Execute immediately — no approval needed
            break

        case .tier2(let category):
            // In autonomous/yolo mode, auto-approve Tier 2
            if permissionMode == .autonomous || permissionMode == .yolo {
                sessionApprovals.insert(category)
            }

            if !sessionApprovals.contains(category) {
                // Request one-time session approval
                let prompt = category.approvalPrompt
                let approved = await approvalHandler?(prompt) ?? false
                if approved {
                    sessionApprovals.insert(category)
                } else {
                    throw PermissionError.denied(prompt)
                }
            }

        case .tier3(let reason):
            // In yolo mode, only Tier 3 path-based rules still require confirmation.
            // Other Tier 3 commands auto-approve.
            let isPathBased = reason == "Targets a sensitive path"
            if permissionMode == .yolo && !isPathBased {
                break // Auto-approve non-path Tier 3 in yolo mode
            }

            // Always show exact command and confirm
            let prompt = "⚠️ Destructive action:\n\n\(sanitizedCommand)\n\nReason: \(reason)"
            let approved = await approvalHandler?(prompt) ?? false
            if !approved {
                throw PermissionError.denied(reason)
            }
        }

        return try await executeProcess(sanitizedCommand, timeout: timeout)
    }

    /// Execute a shell command without permission checks (internal use only).
    private func executeProcess(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // SEC-H3: Use arguments array — never interpolate into bash string.
        // Note: -c still passes a string to bash, but the command comes from
        // Claude's structured tool output, not from user string interpolation.
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            // Timeout handler
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                process.terminate()
                continuation.resume(throwing: ActionError.timeout(command))
            }
            timer.resume()

            do {
                try process.run()
            } catch {
                timer.cancel()
                continuation.resume(throwing: ActionError.processLaunchFailed(error.localizedDescription))
                return
            }

            process.terminationHandler = { _ in
                timer.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                let result = ShellResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    command: command
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Permission-Aware AppleScript

    /// Execute an AppleScript with tiered permission checks.
    func runAppleScript(_ script: String) async throws -> String {
        // Classify the AppleScript
        let tier = PermissionClassifier.classifyAppleScript(script)

        switch tier {
        case .tier1:
            break

        case .tier2(let category):
            if permissionMode == .autonomous || permissionMode == .yolo {
                sessionApprovals.insert(category)
            }

            if !sessionApprovals.contains(category) {
                let prompt = category.approvalPrompt
                let approved = await approvalHandler?(prompt) ?? false
                if approved {
                    sessionApprovals.insert(category)
                } else {
                    throw PermissionError.denied(prompt)
                }
            }

        case .tier3(let reason):
            let isPathBased = reason == "Targets a sensitive path"
            if permissionMode == .yolo && !isPathBased {
                break
            }

            let prompt = "⚠️ Destructive AppleScript:\n\n\(script.prefix(200))\n\nReason: \(reason)"
            let approved = await approvalHandler?(prompt) ?? false
            if !approved {
                throw PermissionError.denied(reason)
            }
        }

        return try await executeAppleScript(script)
    }

    /// Execute an AppleScript without permission checks (internal use only).
    private func executeAppleScript(_ script: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                let result = appleScript?.executeAndReturnError(&error)

                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: ActionError.appleScriptError(message))
                } else {
                    let output = result?.stringValue ?? "OK"
                    continuation.resume(returning: output)
                }
            }
        }
    }

    // MARK: - UI Actions (delegated to AccessibilityService)

    func click(x: Double, y: Double) async {
        await accessibility.clickAt(x: x, y: y)
    }

    func doubleClick(x: Double, y: Double) async {
        await accessibility.doubleClickAt(x: x, y: y)
    }

    func typeText(_ text: String) async {
        await accessibility.typeText(text)
    }

    func pressKey(keyCode: CGKeyCode, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) async {
        var flags = CGEventFlags()
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if option { flags.insert(.maskAlternate) }
        if control { flags.insert(.maskControl) }
        await accessibility.pressShortcut(keyCode: keyCode, modifiers: flags)
    }

    func rightClick(x: Double, y: Double) async {
        await accessibility.rightClickAt(x: x, y: y)
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async {
        await accessibility.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
    }

    func scroll(x: Double, y: Double, deltaY: Int) async {
        await accessibility.scroll(x: x, y: y, deltaY: deltaY)
    }

    func moveMouse(x: Double, y: Double) async {
        await accessibility.moveMouse(x: x, y: y)
    }

    // MARK: - Open Application

    /// Escape a string for safe interpolation into an AppleScript string literal.
    /// Handles backslashes and double quotes to prevent injection.
    private static func escapeAppleScriptString(_ input: String) -> String {
        var escaped = input
        // Escape backslashes first (before escaping quotes which introduce backslashes)
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        // Escape double quotes
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return escaped
    }

    func openApplication(_ name: String) async throws -> String {
        // First try NSWorkspace for the most reliable app launch on macOS.
        // This uses Launch Services to resolve bundle identifiers to app URLs.
        if let bundleID = Self.bundleIdentifier(for: name) {
            let appURL = await MainActor.run {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            }
            if let url = appURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                    return "Launched \(name) via NSWorkspace"
                } catch {
                    // Fall through to next method
                    NSLog("CyclopOne [ActionExecutor]: NSWorkspace launch failed for %@: %@", name, error.localizedDescription)
                }
            }
        }

        // Second try: `open -a` shell command — handles fuzzy app name matching
        // and is the standard macOS way to open apps from the command line.
        // Bypasses permission classifier since opening apps is a safe operation.
        let escapedName = Self.escapeShellArgument(name)
        let openResult = try await executeProcess("open -a \(escapedName)", timeout: 15)
        if openResult.isSuccess {
            return "Launched \(name) via open -a"
        }

        // Third try: AppleScript `tell application "X" to activate` as final fallback
        let safeName = Self.escapeAppleScriptString(name)
        let script = "tell application \"\(safeName)\" to activate"
        return try await executeAppleScript(script)
    }

    /// Map common app names to their macOS bundle identifiers.
    private static func bundleIdentifier(for appName: String) -> String? {
        let lower = appName.lowercased()
        let knownApps: [String: String] = [
            "google chrome": "com.google.Chrome",
            "chrome": "com.google.Chrome",
            "safari": "com.apple.Safari",
            "firefox": "org.mozilla.firefox",
            "terminal": "com.apple.Terminal",
            "finder": "com.apple.finder",
            "notes": "com.apple.Notes",
            "messages": "com.apple.MobileSMS",
            "mail": "com.apple.mail",
            "calendar": "com.apple.iCal",
            "music": "com.apple.Music",
            "photos": "com.apple.Photos",
            "maps": "com.apple.Maps",
            "preview": "com.apple.Preview",
            "textedit": "com.apple.TextEdit",
            "activity monitor": "com.apple.ActivityMonitor",
            "system settings": "com.apple.systempreferences",
            "system preferences": "com.apple.systempreferences",
            "xcode": "com.apple.dt.Xcode",
            "visual studio code": "com.microsoft.VSCode",
            "vscode": "com.microsoft.VSCode",
            "slack": "com.tinyspeck.slackmacgap",
            "discord": "com.hnc.Discord",
            "spotify": "com.spotify.client",
            "iterm": "com.googlecode.iterm2",
            "iterm2": "com.googlecode.iterm2",
        ]
        return knownApps[lower]
    }

    // MARK: - Common Key Codes

    static let keyCodes: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02,
        "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
        "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
        "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
        "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
    ]
}

// MARK: - Models

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let command: String

    var isSuccess: Bool { exitCode == 0 }

    var summary: String {
        var parts: [String] = []
        if !stdout.isEmpty {
            let truncated = stdout.count > 2000 ? String(stdout.prefix(2000)) + "\n…(truncated)" : stdout
            parts.append("stdout:\n\(truncated)")
        }
        if !stderr.isEmpty {
            let truncated = stderr.count > 500 ? String(stderr.prefix(500)) + "\n…(truncated)" : stderr
            parts.append("stderr:\n\(truncated)")
        }
        parts.append("exit_code: \(exitCode)")
        return parts.joined(separator: "\n")
    }
}

enum ActionError: LocalizedError {
    case timeout(String)
    case processLaunchFailed(String)
    case appleScriptError(String)
    case unknownAction(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let cmd): return "Command timed out: \(cmd)"
        case .processLaunchFailed(let msg): return "Failed to launch process: \(msg)"
        case .appleScriptError(let msg): return "AppleScript error: \(msg)"
        case .unknownAction(let name): return "Unknown action: \(name)"
        }
    }
}

enum PermissionError: LocalizedError {
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .denied(let reason): return "Permission denied: \(reason)"
        }
    }
}

/// Sprint 17: Errors from shell command sanitization.
enum ShellSanitizationError: LocalizedError {
    case emptyCommand
    case rejectedPattern(String)
    case commandTooLong

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Shell command rejected: empty command."
        case .rejectedPattern(let reason):
            return "Shell command rejected: \(reason)"
        case .commandTooLong:
            return "Shell command rejected: command exceeds maximum allowed length (10,000 characters)."
        }
    }
}
