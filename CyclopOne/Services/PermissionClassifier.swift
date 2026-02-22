import Foundation

/// Classifies commands into permission tiers for the tiered autonomy system.
///
/// Classification order (highest priority first):
/// 1. Tier 3 path-based rules (path trumps command)
/// 2. Tier 3 exact command matches
/// 3. Tier 3 regex patterns
/// 4. Tier 2 category triggers
/// 5. Tier 1 if command matches read-only allowlist
/// 6. Default: Tier 2 "uncategorized" (unknown commands get one-time approval)
struct PermissionClassifier {

    // MARK: - Classification Result

    enum PermissionTier {
        case tier1                          // Always autonomous — never confirm
        case tier2(Tier2Category)           // Approve once per session per category
        case tier3(String)                  // Always confirm — shows exact command
    }

    enum Tier2Category: String, Hashable, CaseIterable {
        case fileWrites = "file_writes"
        case networkAccess = "network_access"
        case packageInstalls = "package_installs"
        case gitWrites = "git_writes"
        case appStateChanges = "app_state_changes"
        case processManagement = "process_management"
        case uncategorized = "uncategorized"

        var approvalPrompt: String {
            switch self {
            case .fileWrites:        return "Cyclop One wants to create/modify files"
            case .networkAccess:     return "Cyclop One wants to access the network"
            case .packageInstalls:   return "Cyclop One wants to install/remove packages"
            case .gitWrites:         return "Cyclop One wants to modify git repositories"
            case .appStateChanges:   return "Cyclop One wants to control applications"
            case .processManagement: return "Cyclop One wants to manage running processes"
            case .uncategorized:     return "Cyclop One wants to run an unrecognized command"
            }
        }
    }

    // MARK: - Classify

    /// Classify a shell command into a permission tier.
    static func classify(_ command: String) -> PermissionTier {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Tier 3 path-based rules (highest priority)
        if matchesTier3Path(lower) {
            return .tier3("Targets a sensitive path")
        }

        // 2. Tier 3 exact command matches
        if matchesTier3Exact(lower) {
            return .tier3("Destructive or dangerous command")
        }

        // 3. Tier 3 regex patterns (encoded execution, pipe to shell, etc.)
        if matchesTier3Regex(trimmed) {
            return .tier3("Potentially dangerous pattern detected")
        }

        // 4. Tier 2 category triggers
        if let category = matchesTier2(lower) {
            return .tier2(category)
        }

        // 5. Tier 1 read-only allowlist
        if matchesTier1(lower) {
            return .tier1
        }

        // 6. Default: Tier 2 "uncategorized" — unknown commands get one-time approval
        return .tier2(.uncategorized)
    }

    /// Classify an AppleScript command into a permission tier.
    static func classifyAppleScript(_ script: String) -> PermissionTier {
        let lower = script.lowercased()

        // Check for `do shell script` — extract inner command and classify it
        if let shellCommand = extractDoShellScript(from: script) {
            let innerTier = classify(shellCommand)
            switch innerTier {
            case .tier1:
                // AppleScript wrapping a Tier 1 shell command → Tier 2 (app state)
                return .tier2(.appStateChanges)
            default:
                return innerTier
            }
        }

        // Tier 3 AppleScript verbs
        let tier3Verbs = ["delete", "empty trash", "format", "erase"]
        for verb in tier3Verbs {
            if lower.contains(verb) {
                return .tier3("AppleScript destructive verb: \(verb)")
            }
        }

        // Tier 3: targeting system settings
        if lower.contains("system preferences") || lower.contains("system settings") {
            return .tier3("Modifying system configuration")
        }

        // Tier 3: Terminal script execution
        if lower.contains("tell application \"terminal\"") && lower.contains("do script") {
            return .tier3("Arbitrary Terminal execution via AppleScript")
        }

        // Tier 2: write verbs
        let writeVerbs = ["set", "make", "move", "duplicate", "activate", "save", "close"]
        for verb in writeVerbs {
            if lower.contains(verb) {
                return .tier2(.appStateChanges)
            }
        }

        // Tier 1: read-only AppleScript verbs
        let readVerbs = ["get", "count", "exists", "name of", "properties of", "bounds of"]
        for verb in readVerbs {
            if lower.contains(verb) {
                return .tier1
            }
        }

        // Default for AppleScript: Tier 2 (app state changes)
        return .tier2(.appStateChanges)
    }

    // MARK: - Tier 3: Path-Based Rules

    private static let sensitivePaths = [
        "~/.ssh/", "~/.gnupg/", "~/.aws/",
        "~/library/keychains/",
        "/etc/", "/system/", "/usr/local/bin/",
        "/library/launchdaemons/", "/library/launchagents/",
        "~/library/launchagents/",
    ]

    private static func matchesTier3Path(_ command: String) -> Bool {
        let expanded = command.replacingOccurrences(of: "~", with: NSHomeDirectory().lowercased())
        for path in sensitivePaths {
            let expandedPath = path.replacingOccurrences(of: "~", with: NSHomeDirectory().lowercased())
            if expanded.contains(expandedPath) {
                return true
            }
        }
        return false
    }

    // MARK: - Tier 3: Exact Commands

    private static let tier3Commands: [String] = [
        "rm ", "rm\t", "rmdir ", "unlink ",
        "sudo ", "su ", "doas ",
        "shutdown", "reboot", "halt", "poweroff",
        "mkfs", "diskutil erase", "diskutil partitiondisk", "dd ",
        "chmod -r", "chown -r",
        "kill -9", "kill -kill",
        "launchctl load", "launchctl unload", "launchctl bootstrap",
        "defaults write",
        "security ",
        "csrutil", "spctl", "codesign",
        "systemsetup", "networksetup",
    ]

    private static func matchesTier3Exact(_ command: String) -> Bool {
        for pattern in tier3Commands {
            if command.hasPrefix(pattern) || command.contains(" " + pattern) || command.contains(";" + pattern) || command.contains("&&" + pattern) || command.contains("|" + pattern) {
                return true
            }
        }
        return false
    }

    // MARK: - Tier 3: Regex Patterns

    private static let tier3Patterns: [(pattern: String, description: String)] = [
        (#"\|\s*base64\s+-d\s*\|\s*(bash|sh|zsh|eval)"#, "Base64-encoded execution"),
        (#"\|\s*(bash|sh|zsh|eval)\s*$"#, "Pipe to shell"),
        (#"\$\(.*\).*>"#, "Command substitution in redirect"),
        (#"curl\s+.*\|\s*(bash|sh|eval)"#, "Remote code execution"),
        (#"wget\s+.*\|\s*(bash|sh|eval)"#, "Remote code execution"),
        (#"python[23]?\s+-c\s+.*(os\.|subprocess|shutil\.rmtree|eval|exec)"#, "Python arbitrary execution"),
        (#"perl\s+-e\s+.*(system|exec|unlink)"#, "Perl arbitrary execution"),
        (#"ruby\s+-e\s+.*(system|exec|FileUtils\.rm)"#, "Ruby arbitrary execution"),
    ]

    private static func matchesTier3Regex(_ command: String) -> Bool {
        for (pattern, _) in tier3Patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Tier 2: Category Triggers

    private static let tier2Categories: [(prefixes: [String], category: Tier2Category)] = [
        // File writes
        (["cp ", "mv ", "mkdir ", "touch ", "tee ", "rsync "], .fileWrites),

        // Network access
        (["curl ", "wget ", "http ", "ssh ", "scp ", "sftp ", "ftp ", "nc ", "nmap ", "ping "], .networkAccess),

        // Package installs
        (["brew install", "brew uninstall", "brew remove",
          "npm install", "npm uninstall", "npm i ",
          "pip install", "pip uninstall", "pip3 install", "pip3 uninstall",
          "gem install", "gem uninstall",
          "cargo install", "cargo uninstall",
          "apt install", "apt remove", "apt-get install", "apt-get remove",
          "port install", "port uninstall"], .packageInstalls),

        // Git writes
        (["git add", "git commit", "git push", "git merge", "git rebase",
          "git checkout", "git reset", "git stash", "git cherry-pick"], .gitWrites),

        // Process management
        (["kill ", "killall ", "pkill "], .processManagement),
    ]

    private static func matchesTier2(_ command: String) -> Tier2Category? {
        // Check for write redirects
        if command.contains(">") || command.contains(">>") {
            return .fileWrites
        }

        for (prefixes, category) in tier2Categories {
            for prefix in prefixes {
                if command.hasPrefix(prefix) || command.contains(" " + prefix) || command.contains(";" + prefix) || command.contains("&&" + prefix) || command.contains("|" + prefix) {
                    return category
                }
            }
        }
        return nil
    }

    // MARK: - Tier 1: Read-Only Allowlist

    private static let tier1Commands: [String] = [
        "ls", "cat", "head", "tail", "less", "wc", "file", "stat", "du", "df",
        "pwd", "cd", "echo", "date", "whoami", "uname", "which", "where", "type",
        "find", "locate", "mdfind",
        "grep", "rg", "ag", "ack",
        "ps", "top", "uptime", "sw_vers", "system_profiler",
        "git status", "git log", "git diff", "git branch", "git show", "git remote",
        "open ",
        "defaults read", "plutil",
        "mdls", "xattr", "otool",
        "man", "help",
    ]

    private static func matchesTier1(_ command: String) -> Bool {
        // Check if the command starts with a Tier 1 command
        for cmd in tier1Commands {
            if command.hasPrefix(cmd) {
                // Extra check: `find` with -exec or -delete is NOT Tier 1
                if cmd == "find" && (command.contains("-exec") || command.contains("-delete")) {
                    return false
                }
                // `sed -n` and `awk` print-only are Tier 1
                if cmd == "sed" && !command.contains("-n") {
                    return false
                }
                return true
            }
        }

        // --help and --version flags are always safe
        if command.hasSuffix("--help") || command.hasSuffix("--version") {
            return true
        }

        return false
    }

    // MARK: - AppleScript Helpers

    /// Extract the shell command from `do shell script "..."` in AppleScript.
    private static func extractDoShellScript(from script: String) -> String? {
        let pattern = #"do\s+shell\s+script\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else {
            return nil
        }
        return String(script[range])
    }
}

// MARK: - Permission Mode

/// User-configurable permission mode.
enum PermissionMode: String, Codable, CaseIterable {
    case standard    // Default: Tier 1/2/3 as described
    case autonomous  // Tier 2 categories auto-approved, only Tier 3 confirms
    case yolo        // Everything runs, only Tier 3 path-based rules confirm

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .autonomous: return "Autonomous"
        case .yolo: return "YOLO (experts only)"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Ask once per session for file writes, network, etc. Always confirm destructive actions."
        case .autonomous: return "Auto-approve file writes and network. Only confirm destructive actions."
        case .yolo: return "Run everything. Only confirm path-based destructive rules (ssh, gnupg, system)."
        }
    }
}
