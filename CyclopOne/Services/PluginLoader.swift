import Foundation
import os.log

private let logger = Logger(subsystem: "com.cyclop.one.app", category: "PluginLoader")

// MARK: - Plugin Models

/// Manifest parsed from a plugin's plugin.json file.
struct PluginManifest: Sendable {
    let name: String
    let version: String
    let description: String
    let author: String?
    let entrypoint: String
    let permissions: [String]
    let tools: [PluginToolDef]
    var isEnabled: Bool
    var directoryURL: URL
}

/// A single tool defined by a plugin.
/// Uses @unchecked Sendable because inputSchema is [String: Any] containing
/// only JSON-serializable value types (strings, numbers, arrays, dicts).
struct PluginToolDef: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    var pluginName: String
}

/// Result from executing a plugin tool.
struct PluginResult: Sendable {
    let result: String
    let isError: Bool
}

// MARK: - PluginLoader

/// Loads, manages, and executes external plugins from ~/.cyclopone/plugins/.
///
/// Plugins are directories containing a `plugin.json` manifest and an executable
/// entrypoint. Communication uses JSON-over-stdio: the loader writes a JSON request
/// to the process's stdin and reads a JSON response from stdout.
///
/// This is an actor to ensure thread-safe access to mutable plugin/tool state.
actor PluginLoader {

    // MARK: - Singleton

    static let shared = PluginLoader()

    // MARK: - Properties

    /// All loaded plugin manifests, keyed by plugin name.
    private var plugins: [String: PluginManifest] = [:]

    /// Maps tool names to their owning plugin's tool definition.
    private(set) var toolRegistry: [String: PluginToolDef] = [:]

    /// The directory where plugin folders are stored.
    private let pluginsDirectory: URL

    /// The data directory for plugin persistent storage.
    private let dataDirectory: URL

    /// UserDefaults key for disabled plugin names.
    private let disabledPluginsKey = "CyclopOne_DisabledPlugins"

    /// UserDefaults key for approved plugin names (user has explicitly approved).
    private let approvedPluginsKey = "CyclopOne_ApprovedPlugins"

    /// File system watcher source for hot-reload.
    private var watchSource: DispatchSourceFileSystemObject?

    /// File descriptor for the watched directory.
    private var watchFD: Int32 = -1

    /// Timeout for plugin process execution (30 seconds).
    private let processTimeout: TimeInterval = 30.0

    /// Maximum bytes to read from plugin stdout (1 MB).
    private let maxStdoutBytes = 1_048_576

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.pluginsDirectory = home.appendingPathComponent(".cyclopone/plugins")
        self.dataDirectory = home.appendingPathComponent(".cyclopone/plugin-data")
    }

    // MARK: - Loading

    /// Load all plugins from ~/.cyclopone/plugins/*/plugin.json.
    /// Call this once at app startup.
    func loadAll() {
        NSLog("CyclopOne [PluginLoader]: Loading plugins from %@", pluginsDirectory.path)

        ensureDirectories()

        let fm = FileManager.default
        var loadedPlugins: [String: PluginManifest] = [:]
        var loadedTools: [String: PluginToolDef] = [:]

        // Discover plugin directories
        guard let subdirs = try? fm.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.info("No plugins directory contents to load")
            self.plugins = [:]
            self.toolRegistry = [:]
            return
        }

        let disabledNames = disabledPluginNames()
        let approvedNames = approvedPluginNames()

        for dirURL in subdirs {
            // Only process directories
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            let manifestURL = dirURL.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else {
                logger.warning("Skipping \(dirURL.lastPathComponent): no plugin.json")
                continue
            }

            let manifestResult = parseManifest(at: manifestURL, directoryURL: dirURL)
            let manifest: PluginManifest
            switch manifestResult {
            case .success(let parsed):
                manifest = parsed
            case .failure(let validationError):
                logger.error("Rejected plugin '\(dirURL.lastPathComponent)': \(validationError.localizedDescription)")
                NSLog("CyclopOne [PluginLoader]: Rejected plugin '%@': %@", dirURL.lastPathComponent, validationError.localizedDescription)
                continue
            }

            // Check approval status — only load approved plugins
            guard approvedNames.contains(manifest.name) else {
                logger.info("Skipping unapproved plugin: \(manifest.name)")
                continue
            }

            var finalManifest = manifest
            finalManifest.isEnabled = !disabledNames.contains(manifest.name)

            // Register all tools from this plugin
            for var tool in finalManifest.tools {
                tool.pluginName = finalManifest.name
                if loadedTools[tool.name] != nil {
                    logger.warning("Duplicate tool name '\(tool.name)' from plugin '\(finalManifest.name)' — skipping")
                    continue
                }
                loadedTools[tool.name] = tool
            }

            loadedPlugins[finalManifest.name] = finalManifest
        }

        self.plugins = loadedPlugins
        self.toolRegistry = loadedTools

        NSLog("CyclopOne [PluginLoader]: Loaded %d plugins with %d tools", loadedPlugins.count, loadedTools.count)
        logger.info("Loaded \(loadedPlugins.count) plugins with \(loadedTools.count) tools")
    }

    /// Reload all plugins (e.g. after file system change).
    func reload() {
        NSLog("CyclopOne [PluginLoader]: Reloading plugins")
        loadAll()
    }

    // MARK: - Tool Query

    /// Check if a tool name belongs to a loaded plugin.
    func isPluginTool(_ name: String) -> Bool {
        return toolRegistry[name] != nil
    }

    /// Return tool definitions in Claude API format for all enabled plugin tools.
    func toolDefinitions() -> [[String: Any]] {
        var defs: [[String: Any]] = []

        for (_, toolDef) in toolRegistry {
            // Only include tools from enabled plugins
            guard let plugin = plugins[toolDef.pluginName], plugin.isEnabled else {
                continue
            }

            let toolDict: [String: Any] = [
                "name": toolDef.name,
                "description": "[Plugin: \(toolDef.pluginName)] \(toolDef.description)",
                "input_schema": toolDef.inputSchema
            ]
            defs.append(toolDict)
        }

        return defs
    }

    // MARK: - Tool Execution

    /// Execute a plugin tool by spawning its entrypoint process with JSON-over-stdio.
    ///
    /// Protocol:
    /// - Writes `{"tool": "<name>", "input": {...}, "context": {"plugin_dir": "...", "data_dir": "..."}}` to stdin
    /// - Reads `{"result": "...", "is_error": false}` from stdout
    /// - 30 second timeout, 1MB stdout limit
    func executeTool(name: String, input: [String: Any]) async throws -> PluginResult {
        guard let toolDef = toolRegistry[name] else {
            throw PluginError.unknownTool(name)
        }

        guard let plugin = plugins[toolDef.pluginName] else {
            throw PluginError.pluginNotLoaded(toolDef.pluginName)
        }

        guard plugin.isEnabled else {
            throw PluginError.pluginDisabled(toolDef.pluginName)
        }

        let entrypointURL = plugin.directoryURL.appendingPathComponent(plugin.entrypoint)
        guard FileManager.default.isExecutableFile(atPath: entrypointURL.path) else {
            throw PluginError.entrypointNotExecutable(entrypointURL.path)
        }

        // Build the plugin data directory for this specific plugin
        let pluginDataDir = dataDirectory.appendingPathComponent(plugin.name)
        try? FileManager.default.createDirectory(at: pluginDataDir, withIntermediateDirectories: true)

        // Build JSON request
        let context: [String: Any] = [
            "plugin_dir": plugin.directoryURL.path,
            "data_dir": pluginDataDir.path
        ]
        let request: [String: Any] = [
            "tool": name,
            "input": input,
            "context": context
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
            throw PluginError.serializationFailed
        }

        NSLog("CyclopOne [PluginLoader]: Executing plugin tool '%@' from '%@'", name, plugin.name)

        // Run the process
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = entrypointURL
            process.currentDirectoryURL = plugin.directoryURL

            // Environment: inherit user PATH + plugin-specific vars
            var env = ProcessInfo.processInfo.environment
            env["CYCLOPONE_PLUGIN_DIR"] = plugin.directoryURL.path
            env["CYCLOPONE_DATA_DIR"] = pluginDataDir.path
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

            // Timeout watchdog
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
                resumeOnce(.failure(PluginError.timeout(self.processTimeout)))
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + self.processTimeout,
                execute: timeoutItem
            )

            process.terminationHandler = { [maxStdoutBytes] proc in
                timeoutItem.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                // Check stdout size limit
                guard stdoutData.count <= maxStdoutBytes else {
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                    logger.error("Plugin stdout exceeded 1MB limit (\(stdoutData.count) bytes). stderr: \(stderrText)")
                    resumeOnce(.failure(PluginError.stdoutTooLarge(stdoutData.count)))
                    return
                }

                // Check exit code
                guard proc.terminationStatus == 0 else {
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
                    logger.error("Plugin process exited with code \(proc.terminationStatus): \(stderrText)")
                    resumeOnce(.success(PluginResult(
                        result: "Plugin process failed (exit \(proc.terminationStatus)): \(stderrText.prefix(500))",
                        isError: true
                    )))
                    return
                }

                // Parse JSON response
                guard !stdoutData.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
                    let rawOutput = String(data: stdoutData, encoding: .utf8) ?? "(no output)"
                    resumeOnce(.success(PluginResult(
                        result: rawOutput.isEmpty ? "Plugin returned no output" : rawOutput,
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

                // Write JSON request to stdin, then close
                stdinPipe.fileHandleForWriting.write(requestData)
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                timeoutItem.cancel()
                resumeOnce(.failure(PluginError.launchFailed(error.localizedDescription)))
            }
        }
    }

    // MARK: - File System Watching

    /// Start watching the plugins directory for changes (hot-reload).
    func startWatching() {
        stopWatching()

        ensureDirectories()

        watchFD = open(pluginsDirectory.path, O_EVTONLY)
        guard watchFD >= 0 else {
            logger.error("Failed to open plugins directory for watching: \(self.pluginsDirectory.path)")
            return
        }

        // Capture the fd for the cancel handler (avoids actor-isolation issue)
        let fd = watchFD

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            NSLog("CyclopOne [PluginLoader]: Detected file system change in plugins directory")
            Task {
                // Small delay to let file operations settle
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                await self.reload()
            }
        }

        source.setCancelHandler {
            if fd >= 0 {
                close(fd)
            }
        }

        source.resume()
        self.watchSource = source

        NSLog("CyclopOne [PluginLoader]: Started watching plugins directory")
        logger.info("Started watching \(self.pluginsDirectory.path)")
    }

    /// Stop watching the plugins directory.
    func stopWatching() {
        if let source = watchSource {
            source.cancel()
            watchSource = nil
        }
        // watchFD is closed by the cancel handler
        watchFD = -1
    }

    // MARK: - Enable / Disable

    /// Enable a plugin by name.
    func enablePlugin(named name: String) {
        if var plugin = plugins[name] {
            plugin.isEnabled = true
            plugins[name] = plugin
            var disabled = disabledPluginNames()
            disabled.remove(name)
            saveDisabledPluginNames(disabled)
            logger.info("Enabled plugin: \(name)")
        }
    }

    /// Disable a plugin by name.
    func disablePlugin(named name: String) {
        if var plugin = plugins[name] {
            plugin.isEnabled = false
            plugins[name] = plugin
            var disabled = disabledPluginNames()
            disabled.insert(name)
            saveDisabledPluginNames(disabled)
            logger.info("Disabled plugin: \(name)")
        }
    }

    /// Approve a plugin so it will be loaded on next loadAll().
    func approvePlugin(named name: String) {
        var approved = approvedPluginNames()
        approved.insert(name)
        saveApprovedPluginNames(approved)
        logger.info("Approved plugin: \(name)")
    }

    /// Revoke approval for a plugin.
    func revokePlugin(named name: String) {
        var approved = approvedPluginNames()
        approved.remove(name)
        saveApprovedPluginNames(approved)
        // Also disable and unload
        plugins.removeValue(forKey: name)
        toolRegistry = toolRegistry.filter { $0.value.pluginName != name }
        logger.info("Revoked plugin: \(name)")
    }

    /// Returns a list of all discovered plugin directories (including unapproved).
    func discoveredPlugins() -> [(name: String, approved: Bool, enabled: Bool)] {
        let fm = FileManager.default
        let approved = approvedPluginNames()
        let disabled = disabledPluginNames()

        guard let subdirs = try? fm.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(name: String, approved: Bool, enabled: Bool)] = []
        for dirURL in subdirs {
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let manifestURL = dirURL.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            let manifestResult = parseManifest(at: manifestURL, directoryURL: dirURL)
            let manifest: PluginManifest
            switch manifestResult {
            case .success(let parsed):
                manifest = parsed
            case .failure(let validationError):
                logger.warning("Cannot list plugin '\(dirURL.lastPathComponent)': \(validationError.localizedDescription)")
                continue
            }

            let isApproved = approved.contains(manifest.name)
            let isEnabled = isApproved && !disabled.contains(manifest.name)
            results.append((name: manifest.name, approved: isApproved, enabled: isEnabled))
        }
        return results
    }

    /// Returns a formatted list of all plugins for display.
    func formattedPluginList() -> String {
        let discovered = discoveredPlugins()
        guard !discovered.isEmpty else {
            return "No plugins found in \(pluginsDirectory.path)"
        }

        var lines: [String] = ["*Plugins:*\n"]
        for p in discovered {
            let approvalTag = p.approved ? "APPROVED" : "UNAPPROVED"
            let enabledTag = p.enabled ? "[ON]" : "[OFF]"
            lines.append("\(enabledTag) *\(p.name)* (\(approvalTag))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private: Manifest Parsing

    /// Parse and validate a plugin.json manifest file using JSONSerialization.
    ///
    /// Returns a `Result` with the parsed manifest on success, or a detailed
    /// `PluginValidationError` on failure. Validates:
    /// - JSON structure and required fields (name, version, description, entrypoint)
    /// - Entrypoint must be a relative path with no path traversal (`..`)
    /// - All tools must have non-empty `input_schema` with `"type": "object"`
    private func parseManifest(at url: URL, directoryURL: URL) -> Result<PluginManifest, PluginValidationError> {
        let path = url.path

        // Read and parse JSON
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadableManifest(path: path))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON(path: path))
        }

        // Validate required fields
        guard let name = json["name"] as? String, !name.isEmpty else {
            return .failure(.missingRequiredField(field: "name", path: path))
        }
        guard let version = json["version"] as? String, !version.isEmpty else {
            return .failure(.missingRequiredField(field: "version", path: path))
        }
        guard let description = json["description"] as? String, !description.isEmpty else {
            return .failure(.missingRequiredField(field: "description", path: path))
        }
        guard let entrypoint = json["entrypoint"] as? String, !entrypoint.isEmpty else {
            return .failure(.missingRequiredField(field: "entrypoint", path: path))
        }

        // Validate entrypoint is a relative path (no leading /)
        if entrypoint.hasPrefix("/") {
            return .failure(.absoluteEntrypoint(entrypoint: entrypoint, path: path))
        }

        // Validate entrypoint has no path traversal components
        let entrypointComponents = entrypoint.components(separatedBy: "/")
        if entrypointComponents.contains("..") {
            return .failure(.entrypointPathTraversal(entrypoint: entrypoint, path: path))
        }

        let author = json["author"] as? String
        let permissions = json["permissions"] as? [String] ?? []

        // Parse and validate tools array
        var toolDefs: [PluginToolDef] = []
        if let toolsArray = json["tools"] as? [[String: Any]] {
            for (index, toolJSON) in toolsArray.enumerated() {
                guard let toolName = toolJSON["name"] as? String, !toolName.isEmpty,
                      let toolDesc = toolJSON["description"] as? String, !toolDesc.isEmpty else {
                    return .failure(.toolMissingFields(toolIndex: index, path: path))
                }

                // input_schema is required and must have type: "object"
                guard let inputSchema = toolJSON["input_schema"] as? [String: Any],
                      !inputSchema.isEmpty else {
                    return .failure(.toolEmptyInputSchema(toolName: toolName, path: path))
                }

                guard let schemaType = inputSchema["type"] as? String,
                      schemaType == "object" else {
                    return .failure(.toolInputSchemaMissingObjectType(toolName: toolName, path: path))
                }

                let toolDef = PluginToolDef(
                    name: toolName,
                    description: toolDesc,
                    inputSchema: inputSchema,
                    pluginName: name
                )
                toolDefs.append(toolDef)
            }
        }

        let manifest = PluginManifest(
            name: name,
            version: version,
            description: description,
            author: author,
            entrypoint: entrypoint,
            permissions: permissions,
            tools: toolDefs,
            isEnabled: true,
            directoryURL: directoryURL
        )

        return .success(manifest)
    }

    // MARK: - Private: Directory Setup

    private func ensureDirectories() {
        let fm = FileManager.default
        for dir in [pluginsDirectory, dataDirectory] {
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

    // MARK: - Private: UserDefaults Persistence

    private func disabledPluginNames() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: disabledPluginsKey) ?? []
        return Set(array)
    }

    private func saveDisabledPluginNames(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: disabledPluginsKey)
    }

    private func approvedPluginNames() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: approvedPluginsKey) ?? []
        return Set(array)
    }

    private func saveApprovedPluginNames(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: approvedPluginsKey)
    }
}

// MARK: - Plugin Validation Errors

/// Errors encountered during plugin manifest parsing and validation.
enum PluginValidationError: LocalizedError {
    case unreadableManifest(path: String)
    case invalidJSON(path: String)
    case missingRequiredField(field: String, path: String)
    case absoluteEntrypoint(entrypoint: String, path: String)
    case entrypointPathTraversal(entrypoint: String, path: String)
    case toolMissingFields(toolIndex: Int, path: String)
    case toolEmptyInputSchema(toolName: String, path: String)
    case toolInputSchemaMissingObjectType(toolName: String, path: String)

    var errorDescription: String? {
        switch self {
        case .unreadableManifest(let path):
            return "Cannot read plugin manifest at \(path)"
        case .invalidJSON(let path):
            return "plugin.json is not valid JSON at \(path)"
        case .missingRequiredField(let field, let path):
            return "plugin.json missing required field '\(field)' at \(path)"
        case .absoluteEntrypoint(let entrypoint, let path):
            return "Plugin entrypoint '\(entrypoint)' must be a relative path at \(path)"
        case .entrypointPathTraversal(let entrypoint, let path):
            return "Plugin entrypoint '\(entrypoint)' contains path traversal at \(path)"
        case .toolMissingFields(let toolIndex, let path):
            return "Tool at index \(toolIndex) missing name or description at \(path)"
        case .toolEmptyInputSchema(let toolName, let path):
            return "Tool '\(toolName)' has an empty input_schema at \(path)"
        case .toolInputSchemaMissingObjectType(let toolName, let path):
            return "Tool '\(toolName)' input_schema must have \"type\": \"object\" at \(path)"
        }
    }
}

// MARK: - Plugin Errors

enum PluginError: LocalizedError {
    case unknownTool(String)
    case pluginNotLoaded(String)
    case pluginDisabled(String)
    case entrypointNotExecutable(String)
    case serializationFailed
    case timeout(TimeInterval)
    case stdoutTooLarge(Int)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown plugin tool: \(name)"
        case .pluginNotLoaded(let name):
            return "Plugin not loaded: \(name)"
        case .pluginDisabled(let name):
            return "Plugin is disabled: \(name)"
        case .entrypointNotExecutable(let path):
            return "Plugin entrypoint is not executable: \(path)"
        case .serializationFailed:
            return "Failed to serialize tool request to JSON"
        case .timeout(let seconds):
            return "Plugin timed out after \(Int(seconds)) seconds"
        case .stdoutTooLarge(let bytes):
            return "Plugin stdout exceeded 1MB limit (\(bytes) bytes)"
        case .launchFailed(let reason):
            return "Failed to launch plugin process: \(reason)"
        }
    }
}
