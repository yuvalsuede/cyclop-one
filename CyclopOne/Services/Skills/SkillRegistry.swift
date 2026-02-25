import Foundation
import os.log

private let logger = Logger(subsystem: "com.cyclop.one.app", category: "SkillRegistry")

// MARK: - PluginResult / PluginError (previously in PluginLoader.swift)

struct PluginResult: Sendable {
    let result: String
    let isError: Bool
}

enum PluginError: Error, LocalizedError {
    case unknownTool(String)
    case pluginDisabled(String)
    case entrypointNotExecutable(String)
    case serializationFailed
    case timeout(TimeInterval)
    case stdoutTooLarge(Int)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let n):           return "Unknown skill tool: \(n)"
        case .pluginDisabled(let n):        return "Skill '\(n)' is disabled or not approved"
        case .entrypointNotExecutable(let p): return "Entrypoint not executable: \(p)"
        case .serializationFailed:          return "Failed to serialize tool input as JSON"
        case .timeout(let t):               return "Skill tool timed out after \(Int(t))s"
        case .stdoutTooLarge(let b):        return "Skill tool output too large (\(b) bytes)"
        case .launchFailed(let msg):        return "Failed to launch skill tool: \(msg)"
        }
    }
}

// MARK: - SkillRegistry

/// Unified registry that replaces both `SkillLoader` and `PluginLoader`.
///
/// Responsibilities:
/// - Load built-in skill packages (hardcoded in the binary).
/// - Load legacy `.md` skill files from `~/.cyclopone/skills/`.
/// - Load user skill packages from `~/.cyclopone/skills/` directories.
/// - Load external plugin packages from `~/.cyclopone/plugins/`.
/// - Match skills to user commands using pre-compiled regex triggers.
/// - Build skill context strings for system prompt injection.
/// - Execute external skill/plugin tool executables via JSON-over-stdio.
/// - Enable, disable, approve, and revoke packages.
actor SkillRegistry {

    // MARK: - Singleton

    static let shared = SkillRegistry()

    // MARK: - Properties

    /// All loaded packages (built-in + user + marketplace).
    private var packages: [SkillPackage] = []

    /// Maps tool name → owning package for fast lookup.
    private var toolToPackage: [String: SkillPackage] = [:]

    /// Pre-compiled trigger regexes keyed by pattern string.
    private var compiledTriggers: [String: NSRegularExpression] = [:]

    /// The directory where user skill files / packages are stored.
    let skillsDirectory: URL

    /// The directory where external plugin packages are stored.
    let pluginsDirectory: URL

    /// Persistent storage directory for plugin data.
    private let pluginDataDirectory: URL

    // MARK: - UserDefaults Keys

    private let disabledSkillsKey = "CyclopOne_DisabledSkills"
    private let approvedSkillsKey = "CyclopOne_ApprovedPlugins" // keep old key for compat

    // MARK: - Constants

    private let processTimeout: TimeInterval = 30.0
    private let maxStdoutBytes = 1_048_576

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        skillsDirectory = home.appendingPathComponent(".cyclopone/skills")
        pluginsDirectory = home.appendingPathComponent(".cyclopone/plugins")
        pluginDataDirectory = home.appendingPathComponent(".cyclopone/plugin-data")
    }

    // MARK: - Loading

    /// Load all skill packages. Call once at app startup.
    ///
    /// Order: built-in → legacy .md files → user package dirs → plugin package dirs.
    func loadAll() {
        logger.info("SkillRegistry: loading all packages")

        ensureDirectories()
        installBuiltInSkillFiles()

        var loaded: [SkillPackage] = []

        // 1. Built-in packages
        loaded.append(contentsOf: SkillRegistryBuiltIn.builtInPackages())

        // 2. Legacy .md skill files + user package directories from skills dir
        loaded.append(contentsOf: loadUserSkillsDirectory())

        // 3. Plugin package directories
        loaded.append(contentsOf: loadPluginPackages())

        // Apply enabled/disabled and approval state
        let disabled = disabledPackageNames()
        let approved = approvedPackageNames()
        let builtInNames = Set(SkillRegistryBuiltIn.builtInPackages().map { $0.name })

        for i in loaded.indices {
            if disabled.contains(loaded[i].name) {
                loaded[i].isEnabled = false
            }
            // Plugin packages (non-built-in from plugins dir) require explicit approval
            if !loaded[i].isBuiltIn && !builtInNames.contains(loaded[i].name) {
                if case .user = loaded[i].source {
                    // User skill files are allowed without approval
                } else {
                    loaded[i].requiresApproval = true
                    if !approved.contains(loaded[i].name) {
                        loaded[i].isEnabled = false
                    }
                }
            }
        }

        // Compile trigger regexes
        compiledTriggers.removeAll()
        toolToPackage.removeAll()
        for i in loaded.indices {
            var hasInvalidTrigger = false
            for pattern in loaded[i].triggers {
                if compiledTriggers[pattern] == nil {
                    do {
                        compiledTriggers[pattern] = try NSRegularExpression(
                            pattern: pattern,
                            options: [.caseInsensitive]
                        )
                    } catch {
                        hasInvalidTrigger = true
                        logger.error("Invalid trigger regex in '\(loaded[i].name)': '\(pattern)' — \(error.localizedDescription)")
                    }
                }
            }
            if hasInvalidTrigger {
                loaded[i].isEnabled = false
                logger.warning("Disabled '\(loaded[i].name)' due to invalid trigger regex")
            }

            // Register tools
            if let tools = loaded[i].manifest.tools {
                for tool in tools {
                    if toolToPackage[tool.name] == nil {
                        toolToPackage[tool.name] = loaded[i]
                    } else {
                        logger.warning("Duplicate tool '\(tool.name)' from package '\(loaded[i].name)' — skipping")
                    }
                }
            }
        }

        self.packages = loaded

        logger.info("SkillRegistry: loaded \(loaded.count) package(s) (\(loaded.filter { $0.isBuiltIn }.count) built-in)")
        NSLog("CyclopOne [SkillRegistry]: Loaded %d package(s)", loaded.count)
    }

    /// Reload all packages (e.g. after file system change).
    func reload() {
        loadAll()
    }

    // MARK: - Matching

    /// Find all enabled packages whose trigger patterns match the given command.
    func matchSkills(for command: String) -> [SkillPackage] {
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var matched: [SkillPackage] = []
        for pkg in packages where pkg.isEnabled {
            for pattern in pkg.triggers {
                if let regex = compiledTriggers[pattern],
                   regex.firstMatch(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized)
                   ) != nil {
                    matched.append(pkg)
                    break
                }
            }
        }
        return matched
    }

    // MARK: - Context Building

    /// Build system prompt context from matched packages.
    func buildSkillContext(for pkgs: [SkillPackage]) -> String {
        guard !pkgs.isEmpty else { return "" }
        var lines: [String] = ["\n\n## Available Skills",
                               "The following skills match the user's request. Follow their steps in order:"]
        for pkg in pkgs {
            lines.append("")
            lines.append("### Skill: \(pkg.name)")
            lines.append(pkg.description)
            lines.append("")
            lines.append("**Steps:**")
            for (i, step) in pkg.steps.enumerated() {
                lines.append("\(i + 1). \(step)")
            }
            if let maxIter = pkg.maxIterations, maxIter > 0 {
                lines.append("")
                lines.append("Max iterations for this skill: \(maxIter)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tool Execution

    /// Returns true if the given tool name belongs to a loaded skill/plugin tool.
    func isSkillTool(_ name: String) -> Bool {
        return toolToPackage[name] != nil
    }

    /// Execute a skill/plugin tool by name using JSON-over-stdio.
    ///
    /// Checks approval status via `SkillApprovalInfo` and wraps the executable
    /// in a `sandbox-exec` profile generated by `SkillSafetyScanner`.
    func executeSkillTool(name: String, input: [String: Any]) async throws -> PluginResult {
        guard let pkg = toolToPackage[name] else {
            throw PluginError.unknownTool(name)
        }
        guard pkg.isEnabled else {
            throw PluginError.pluginDisabled(pkg.name)
        }
        guard let toolDef = pkg.manifest.tools?.first(where: { $0.name == name }) else {
            throw PluginError.unknownTool(name)
        }

        let packageDir: URL
        switch pkg.source {
        case .builtIn:
            throw PluginError.unknownTool(name) // built-in skills don't have executables
        case .user(let dir), .marketplace(let dir):
            packageDir = dir
        }

        // MARK: Approval gate
        // Non-built-in packages with executable tools require explicit user approval.
        if !pkg.isBuiltIn {
            let version = pkg.manifest.version
            guard SkillApprovalInfo.isApproved(name: pkg.name, version: version) else {
                logger.warning("SkillRegistry: tool '\(name)' blocked — package '\(pkg.name)' v\(version) not approved")
                throw PluginError.pluginDisabled(pkg.name) // reuse disabled error for unapproved
            }
        }

        let entrypointURL = packageDir.appendingPathComponent(toolDef.entrypoint)
        guard FileManager.default.isExecutableFile(atPath: entrypointURL.path) else {
            throw PluginError.entrypointNotExecutable(entrypointURL.path)
        }

        let pluginDataDir = pluginDataDirectory.appendingPathComponent(pkg.name)
        try? FileManager.default.createDirectory(at: pluginDataDir, withIntermediateDirectories: true)

        let context: [String: Any] = [
            "plugin_dir": packageDir.path,
            "data_dir": pluginDataDir.path
        ]
        let request: [String: Any] = ["tool": name, "input": input, "context": context]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
            throw PluginError.serializationFailed
        }

        // MARK: Sandbox profile
        let permissions = pkg.manifest.permissions ?? []
        let sandboxProfile = await SkillSafetyScanner.shared.generateSandboxProfile(permissions: permissions)

        // Write sandbox profile to a temp file
        let profilePath = "/tmp/skill_sandbox_\(UUID().uuidString).sb"
        do {
            try sandboxProfile.write(toFile: profilePath, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("SkillRegistry: could not write sandbox profile to \(profilePath), running unsandboxed: \(error.localizedDescription)")
        }

        NSLog("CyclopOne [SkillRegistry]: Executing tool '%@' from package '%@' (sandbox: %@)",
              name, pkg.name, profilePath)

        let timeout = self.processTimeout
        let maxBytes = self.maxStdoutBytes
        let useSandbox = FileManager.default.fileExists(atPath: profilePath)
        let sandboxExecPath = "/usr/bin/sandbox-exec"
        let sandboxAvailable = FileManager.default.fileExists(atPath: sandboxExecPath)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()

            if useSandbox && sandboxAvailable {
                // Run: sandbox-exec -f <profile> <entrypoint>
                process.executableURL = URL(fileURLWithPath: sandboxExecPath)
                process.arguments = ["-f", profilePath, entrypointURL.path]
            } else {
                process.executableURL = entrypointURL
            }

            process.currentDirectoryURL = packageDir

            var env = ProcessInfo.processInfo.environment
            env["CYCLOPONE_PLUGIN_DIR"] = packageDir.path
            env["CYCLOPONE_DATA_DIR"] = pluginDataDir.path
            // Expose home dir for sandbox profile param expansion
            env["_HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var hasResumed = false
            let resumeOnce: (Result<PluginResult, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                resumeOnce(.failure(PluginError.timeout(timeout)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                // Clean up sandbox profile temp file
                if useSandbox { try? FileManager.default.removeItem(atPath: profilePath) }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                guard stdoutData.count <= maxBytes else {
                    resumeOnce(.failure(PluginError.stdoutTooLarge(stdoutData.count)))
                    return
                }

                guard proc.terminationStatus == 0 else {
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
                    resumeOnce(.success(PluginResult(
                        result: "Tool process failed (exit \(proc.terminationStatus)): \(stderrText.prefix(500))",
                        isError: true
                    )))
                    return
                }

                guard !stdoutData.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
                    let rawOutput = String(data: stdoutData, encoding: .utf8) ?? "(no output)"
                    resumeOnce(.success(PluginResult(
                        result: rawOutput.isEmpty ? "Tool returned no output" : rawOutput,
                        isError: rawOutput.isEmpty
                    )))
                    return
                }

                let resultText = json["result"] as? String ?? "(no result field)"
                let isError = json["is_error"] as? Bool ?? false
                resumeOnce(.success(PluginResult(result: resultText, isError: isError)))
            }

            do {
                try process.run()
                stdinPipe.fileHandleForWriting.write(requestData)
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                timeoutItem.cancel()
                if useSandbox { try? FileManager.default.removeItem(atPath: profilePath) }
                resumeOnce(.failure(PluginError.launchFailed(error.localizedDescription)))
            }
        }
    }

    // MARK: - Tool Definitions (for Claude API)

    /// Returns all enabled tool definitions in Claude API format.
    func toolDefinitions() -> [[String: Any]] {
        var defs: [[String: Any]] = []
        for (toolName, pkg) in toolToPackage {
            guard pkg.isEnabled else { continue }
            guard let toolDef = pkg.manifest.tools?.first(where: { $0.name == toolName }) else { continue }
            let schema: [String: Any] = toolDef.inputSchema ?? ["type": "object", "properties": [:]]
            defs.append([
                "name": toolDef.name,
                "description": "[Skill: \(pkg.name)] \(toolDef.description)",
                "input_schema": schema
            ])
        }
        return defs
    }

    // MARK: - Enable / Disable / Approve / Revoke

    func enable(_ name: String) {
        guard let idx = packages.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        packages[idx].isEnabled = true
        var disabled = disabledPackageNames()
        disabled.remove(packages[idx].name)
        saveDisabledPackageNames(disabled)
        logger.info("Enabled skill package: \(name)")
    }

    func disable(_ name: String) {
        guard let idx = packages.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        packages[idx].isEnabled = false
        var disabled = disabledPackageNames()
        disabled.insert(packages[idx].name)
        saveDisabledPackageNames(disabled)
        logger.info("Disabled skill package: \(name)")
    }

    func approve(_ name: String) {
        var approved = approvedPackageNames()
        approved.insert(name)
        saveApprovedPackageNames(approved)
        logger.info("Approved skill package: \(name)")
    }

    func revoke(_ name: String) {
        var approved = approvedPackageNames()
        approved.remove(name)
        saveApprovedPackageNames(approved)
        packages.removeAll { $0.name == name }
        toolToPackage = toolToPackage.filter { $0.value.name != name }
        logger.info("Revoked skill package: \(name)")
    }

    // MARK: - Listing

    func formattedSkillList() -> String {
        guard !packages.isEmpty else { return "No skill packages loaded." }
        var lines: [String] = ["*Skills:*\n"]
        for pkg in packages {
            let status = pkg.isEnabled ? "[ON]" : "[OFF]"
            let source = pkg.isBuiltIn ? "(built-in)" : "(custom)"
            lines.append("\(status) *\(pkg.name)* \(source)")
            lines.append("  \(pkg.description)")
            lines.append("  Triggers: \(pkg.triggers.joined(separator: ", "))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Names of all loaded plugin packages (from plugins directory).
    var pluginNames: [String] {
        packages.compactMap { pkg -> String? in
            if case .user = pkg.source { return nil }
            if case .marketplace = pkg.source { return pkg.name }
            return nil
        }.sorted()
    }

    // MARK: - Accessors for legacy adapters

    /// All loaded packages (read-only snapshot).
    var allPackages: [SkillPackage] { packages }

    // MARK: - Private: Directory setup

    private func ensureDirectories() {
        let fm = FileManager.default
        for dir in [skillsDirectory, pluginsDirectory, pluginDataDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    logger.info("Created directory: \(dir.path)")
                } catch {
                    logger.error("Failed to create directory \(dir.path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private: Install built-in files

    private func installBuiltInSkillFiles() {
        let fm = FileManager.default
        for pkg in SkillRegistryBuiltIn.builtInPackages() {
            let sanitized = pkg.name.lowercased().replacingOccurrences(of: " ", with: "-")
            let filePath = skillsDirectory.appendingPathComponent("\(sanitized).md")
            guard !fm.fileExists(atPath: filePath.path) else { continue }

            let content = LegacySkillParser.serialize(pkg)
            do {
                try content.write(to: filePath, atomically: true, encoding: .utf8)
                logger.info("Installed built-in skill file: \(filePath.lastPathComponent)")
            } catch {
                logger.error("Failed to install skill file '\(pkg.name)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: Load user skills directory

    private func loadUserSkillsDirectory() -> [SkillPackage] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: skillsDirectory.path) else { return [] }

        let builtInNames = Set(SkillRegistryBuiltIn.builtInPackages().map { $0.name })
        var result: [SkillPackage] = []

        guard let contents = try? fm.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if !isDir && url.pathExtension == "md" {
                // Legacy .md skill file
                if let pkg = LegacySkillParser.parse(url) {
                    if !builtInNames.contains(pkg.name) {
                        result.append(pkg)
                    }
                }
            } else if isDir {
                // Package directory with plugin.json
                let manifestURL = url.appendingPathComponent("plugin.json")
                if fm.fileExists(atPath: manifestURL.path),
                   let pkg = parsePackageManifest(at: manifestURL, directoryURL: url, source: .user(directoryURL: url)) {
                    if !builtInNames.contains(pkg.name) {
                        result.append(pkg)
                    }
                }
            }
        }

        return result
    }

    // MARK: - Private: Load plugin packages

    private func loadPluginPackages() -> [SkillPackage] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginsDirectory.path) else { return [] }

        var result: [SkillPackage] = []

        guard let subdirs = try? fm.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for dirURL in subdirs {
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let manifestURL = dirURL.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else {
                logger.warning("Skipping plugin dir '\(dirURL.lastPathComponent)': no plugin.json")
                continue
            }
            if let pkg = parsePackageManifest(
                at: manifestURL,
                directoryURL: dirURL,
                source: .marketplace(directoryURL: dirURL)
            ) {
                result.append(pkg)
            }
        }

        return result
    }

    // MARK: - Private: Parse plugin.json manifest

    private func parsePackageManifest(at url: URL, directoryURL: URL, source: SkillSource) -> SkillPackage? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Cannot parse plugin.json at \(url.path)")
            return nil
        }

        guard let name = json["name"] as? String, !name.isEmpty,
              let version = json["version"] as? String, !version.isEmpty,
              let desc = json["description"] as? String, !desc.isEmpty else {
            logger.error("plugin.json missing required fields at \(url.path)")
            return nil
        }

        let author = json["author"] as? String
        let triggers = json["triggers"] as? [String] ?? []
        let steps = json["steps"] as? [String] ?? []
        let permissions = json["permissions"] as? [String]
        let maxIterations = json["maxIterations"] as? Int

        // Parse tools
        var toolDefs: [SkillToolDef] = []
        if let toolsArray = json["tools"] as? [[String: Any]] {
            for toolJSON in toolsArray {
                guard let toolName = toolJSON["name"] as? String, !toolName.isEmpty,
                      let toolDesc = toolJSON["description"] as? String,
                      let entrypoint = toolJSON["entrypoint"] as? String, !entrypoint.isEmpty else {
                    continue
                }
                // Validate no path traversal
                if entrypoint.hasPrefix("/") || entrypoint.components(separatedBy: "/").contains("..") {
                    logger.error("Rejected tool '\(toolName)': invalid entrypoint '\(entrypoint)'")
                    continue
                }
                let inputSchema = toolJSON["input_schema"] as? [String: Any]
                toolDefs.append(SkillToolDef(
                    name: toolName,
                    description: toolDesc,
                    entrypoint: entrypoint,
                    inputSchema: inputSchema
                ))
            }
        }

        // If no triggers defined in plugin.json, provide an empty array (tool-only plugin)
        let manifest = SkillPackageManifest(
            name: name,
            version: version,
            description: desc,
            author: author,
            triggers: triggers,
            steps: steps,
            tools: toolDefs.isEmpty ? nil : toolDefs,
            permissions: permissions,
            maxIterations: maxIterations,
            marketplace: nil
        )

        var pkg = SkillPackage(manifest: manifest, source: source)
        pkg.filePath = url.path
        return pkg
    }

    // MARK: - Private: UserDefaults

    private func disabledPackageNames() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledSkillsKey) ?? [])
    }

    private func saveDisabledPackageNames(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: disabledSkillsKey)
    }

    private func approvedPackageNames() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: approvedSkillsKey) ?? [])
    }

    private func saveApprovedPackageNames(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: approvedSkillsKey)
    }
}
