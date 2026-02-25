import Foundation
import os.log

private let logger = Logger(subsystem: "com.cyclop.one.app", category: "SkillSafetyScanner")

// MARK: - SkillSafetyScanner

/// Static analysis scanner for skill executable files and manifests.
///
/// Inspects shell scripts and plugin.json manifests for dangerous patterns
/// and generates macOS sandbox-exec profiles for safe execution.
actor SkillSafetyScanner {

    // MARK: - Singleton

    static let shared = SkillSafetyScanner()

    private init() {}

    // MARK: - RiskLevel

    enum RiskLevel: String, Sendable, Comparable, CaseIterable {
        case safe
        case low
        case medium
        case high

        static func < (a: RiskLevel, b: RiskLevel) -> Bool {
            let order: [RiskLevel] = [.safe, .low, .medium, .high]
            guard let ia = order.firstIndex(of: a),
                  let ib = order.firstIndex(of: b) else { return false }
            return ia < ib
        }
    }

    // MARK: - SafetyFinding

    struct SafetyFinding: Sendable {
        let severity: RiskLevel
        let description: String
        let file: String
        let line: Int?
    }

    // MARK: - ScanResult

    struct ScanResult: Sendable {
        /// false if any HIGH findings were found
        let passed: Bool
        /// Worst finding severity across all findings
        let riskLevel: RiskLevel
        let findings: [SafetyFinding]
        /// macOS sandbox-exec profile (.sb) content
        let sandboxProfile: String
    }

    // MARK: - Dangerous Pattern Definitions

    /// HIGH-severity patterns — auto-reject.
    private let highRiskPatterns: [(pattern: String, description: String)] = [
        // Filesystem destruction
        (#"rm\s+-[^\s]*r[^\s]*\s+/"#,            "Recursive delete from root (rm -rf /)"),
        (#"rm\s+-[^\s]*r[^\s]*\s+~"#,            "Recursive delete from home (rm -rf ~)"),
        (#"rm\s+--\s+-[^\s]*r"#,                 "Recursive delete with -- separator"),
        // Remote code execution
        (#"curl\s+.*\|\s*(bash|sh|zsh|fish)"#,   "Remote code execution: curl | shell"),
        (#"wget\s+.*\|\s*(bash|sh|zsh|fish)"#,   "Remote code execution: wget | shell"),
        (#"curl\s+.*\|\s*sudo"#,                  "Remote code execution with sudo: curl | sudo"),
        // Temp dir execution
        (#"chmod\s+.*\+x\s+/tmp"#,               "Making /tmp executable"),
        (#"/tmp/.*\.sh"#,                         "Executing script from /tmp"),
        // Privilege escalation
        (#"\bsudo\b"#,                            "Privilege escalation via sudo"),
        // Credential theft — system files
        (#"/etc/passwd"#,                         "Accessing /etc/passwd (credential theft risk)"),
        (#"/etc/shadow"#,                         "Accessing /etc/shadow (credential theft risk)"),
        (#"~/\.ssh/"#,                            "Accessing ~/.ssh/ (credential theft risk)"),
        (#"\$HOME/\.ssh"#,                        "Accessing $HOME/.ssh (credential theft risk)"),
        // API key exfiltration
        (#"\$ANTHROPIC_API_KEY"#,                 "Potential ANTHROPIC_API_KEY exfiltration"),
        (#"\$OPENAI_API_KEY"#,                    "Potential OPENAI_API_KEY exfiltration"),
        (#"ANTHROPIC_API_KEY"#,                   "Reference to ANTHROPIC_API_KEY"),
        (#"OPENAI_API_KEY"#,                      "Reference to OPENAI_API_KEY"),
    ]

    /// MEDIUM-severity patterns — warn and require approval.
    private let mediumRiskPatterns: [(pattern: String, description: String)] = [
        // Network access (curl/wget without piping to shell)
        (#"\bcurl\s+"#,                           "Network request via curl"),
        (#"\bwget\s+"#,                           "Network request via wget"),
        (#"\bfetch\s+"#,                          "Network fetch call"),
        // File writes outside allowed area
        (#">\s*/etc/"#,                           "File write to /etc/"),
        (#">\s*/usr/"#,                           "File write to /usr/"),
        (#">\s*/var/"#,                           "File write to /var/"),
        (#">\s*/Library/"#,                       "File write to /Library/"),
        // Sensitive environment variable access
        (#"\$AWS_"#,                              "Access to AWS environment variable"),
        (#"\$SECRET"#,                            "Access to SECRET environment variable"),
        (#"\$TOKEN"#,                             "Access to TOKEN environment variable"),
        (#"\$PASSWORD"#,                          "Access to PASSWORD environment variable"),
        (#"\$PRIVATE_KEY"#,                       "Access to PRIVATE_KEY environment variable"),
    ]

    /// LOW-severity patterns — informational.
    private let lowRiskPatterns: [(pattern: String, description: String)] = [
        (#"^#!/bin/bash|^#!/usr/bin/env\s+bash"#, "Script uses bash interpreter"),
        (#"^#!/bin/sh|^#!/usr/bin/env\s+sh"#,     "Script uses sh interpreter"),
        (#"^#!/bin/zsh|^#!/usr/bin/env\s+zsh"#,   "Script uses zsh interpreter"),
        (#"^#!/usr/bin/env\s+python"#,             "Script uses Python interpreter"),
        (#"^#!/usr/bin/env\s+node"#,               "Script uses Node.js interpreter"),
        (#"^#!/usr/bin/env\s+ruby"#,               "Script uses Ruby interpreter"),
    ]

    // MARK: - Public API

    /// Scan a skill package for safety issues.
    ///
    /// - Parameter package: The skill package to scan.
    /// - Returns: A `ScanResult` with findings and a sandbox profile.
    func scan(package: SkillPackage) async -> ScanResult {
        var allFindings: [SafetyFinding] = []

        // Determine the package directory URL
        let packageDirURL: URL?
        switch package.source {
        case .builtIn:
            packageDirURL = nil
        case .user(let dir), .marketplace(let dir):
            packageDirURL = dir
        }

        // Scan each tool's entrypoint executable
        if let tools = package.manifest.tools, let dirURL = packageDirURL {
            for tool in tools {
                let execURL = dirURL.appendingPathComponent(tool.entrypoint)
                let findings = scanFile(at: execURL)
                allFindings.append(contentsOf: findings)
            }

            // Also scan plugin.json manifest for suspicious content
            let manifestURL = dirURL.appendingPathComponent("plugin.json")
            let manifestFindings = scanFile(at: manifestURL)
            allFindings.append(contentsOf: manifestFindings)
        }

        // Determine worst risk level
        let worstRisk = allFindings.map { $0.severity }.max() ?? .safe

        // passed = false if any HIGH findings exist
        let passed = !allFindings.contains { $0.severity == .high }

        // Generate sandbox profile based on declared permissions
        let permissions = package.manifest.permissions ?? []
        let profile = generateSandboxProfile(permissions: permissions)

        let result = ScanResult(
            passed: passed,
            riskLevel: worstRisk,
            findings: allFindings,
            sandboxProfile: profile
        )

        logger.info("SkillSafetyScanner: scanned '\(package.name)' — risk=\(worstRisk.rawValue), passed=\(passed), findings=\(allFindings.count)")
        NSLog("CyclopOne [SkillSafetyScanner]: Scanned '%@' — risk=%@ passed=%@ findings=%d",
              package.name, worstRisk.rawValue, passed ? "true" : "false", allFindings.count)

        return result
    }

    /// Generate a macOS sandbox-exec (.sb) profile for the given permission set.
    ///
    /// - Parameter permissions: Array of permission strings from the package manifest.
    /// - Returns: A Scheme-language sandbox profile string.
    func generateSandboxProfile(permissions: [String]) -> String {
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "",
            "; Allow process execution",
            "(allow process-exec)",
            "(allow process-fork)",
            "",
            "; Allow reading system libraries and frameworks",
            "(allow file-read*",
            "  (literal \"/usr/lib\")",
            "  (subpath \"/System\")",
            "  (subpath \"/usr/lib\")",
            "  (subpath \"/usr/local/lib\")",
            "  (subpath \"/Library/Frameworks\")",
            "  (subpath \"/usr/share\")",
            ")",
            "",
            "; Allow reading user home directory (for PATH, shell config, etc.)",
            "(allow file-read*",
            "  (subpath \"/Users\")",
            "  (extension \"com.apple.app-sandbox.read\")",
            ")",
            "",
            "; Allow writes to /tmp",
            "(allow file-write*",
            "  (subpath \"/tmp\")",
            "  (subpath \"/private/tmp\")",
            ")",
            "",
            "; Allow writes to plugin data directory",
            "(allow file-write*",
            "  (subpath (string-append (param \"_HOME\") \"/.cyclopone/plugin-data\"))",
            ")",
            "",
            "; Allow reading /dev (needed for stdin/stdout/stderr)",
            "(allow file-read* file-write*",
            "  (subpath \"/dev\")",
            ")",
            "",
            "; Allow signal sending to self",
            "(allow signal (target self))",
            "",
            "; Allow sysctl reads (needed by runtime)",
            "(allow sysctl-read)",
        ]

        // Network permission
        if permissions.contains("network") {
            lines.append("")
            lines.append("; Network access (declared in manifest)")
            lines.append("(allow network-outbound)")
            lines.append("(allow network-inbound)")
        }

        // Filesystem permission
        if permissions.contains("filesystem") {
            lines.append("")
            lines.append("; Full home directory read/write (declared in manifest)")
            lines.append("(allow file-read*")
            lines.append("  (subpath (param \"_HOME\"))")
            lines.append(")")
            lines.append("(allow file-write*")
            lines.append("  (subpath (param \"_HOME\"))")
            lines.append(")")
        }

        // Shell permission
        if permissions.contains("shell") {
            lines.append("")
            lines.append("; Shell execution (declared in manifest)")
            lines.append("(allow process-exec (subpath \"/bin\"))")
            lines.append("(allow process-exec (subpath \"/usr/bin\"))")
            lines.append("(allow process-exec (subpath \"/usr/local/bin\"))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private: File Scanning

    /// Scan a single file at the given URL for dangerous patterns.
    private func scanFile(at url: URL) -> [SafetyFinding] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            // Try latin1 as fallback for binary-ish files
            guard let content = try? String(contentsOf: url, encoding: .isoLatin1) else {
                logger.warning("SkillSafetyScanner: cannot read file at \(url.path)")
                return []
            }
            return scanLines(content.components(separatedBy: "\n"), file: url.lastPathComponent)
        }

        let lines = content.components(separatedBy: "\n")
        return scanLines(lines, file: url.lastPathComponent)
    }

    /// Scan individual lines against all risk pattern sets.
    private func scanLines(_ lines: [String], file: String) -> [SafetyFinding] {
        var findings: [SafetyFinding] = []

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1

            // Check HIGH patterns
            for (pattern, description) in highRiskPatterns {
                if lineMatchesPattern(line, pattern: pattern) {
                    findings.append(SafetyFinding(
                        severity: .high,
                        description: description,
                        file: file,
                        line: lineNumber
                    ))
                }
            }

            // Check MEDIUM patterns (only if line didn't already match a HIGH pattern
            // for the same dangerous construct — e.g. curl | bash is HIGH, not also MEDIUM)
            let alreadyHighCurl = findings.contains {
                $0.line == lineNumber && $0.severity == .high && $0.description.contains("curl")
            }
            let alreadyHighWget = findings.contains {
                $0.line == lineNumber && $0.severity == .high && $0.description.contains("wget")
            }

            for (pattern, description) in mediumRiskPatterns {
                // Skip low-signal curl/wget medium matches if already flagged HIGH
                let isCurlPattern = description.contains("curl")
                let isWgetPattern = description.contains("wget")
                if isCurlPattern && alreadyHighCurl { continue }
                if isWgetPattern && alreadyHighWget { continue }

                if lineMatchesPattern(line, pattern: pattern) {
                    findings.append(SafetyFinding(
                        severity: .medium,
                        description: description,
                        file: file,
                        line: lineNumber
                    ))
                }
            }

            // Check LOW patterns (only first line for shebang patterns)
            if lineNumber <= 3 {
                for (pattern, description) in lowRiskPatterns {
                    if lineMatchesPattern(line, pattern: pattern) {
                        findings.append(SafetyFinding(
                            severity: .low,
                            description: description,
                            file: file,
                            line: lineNumber
                        ))
                    }
                }
            }
        }

        return findings
    }

    /// Test a single line against a regex pattern (case-insensitive).
    private func lineMatchesPattern(_ line: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }
}
