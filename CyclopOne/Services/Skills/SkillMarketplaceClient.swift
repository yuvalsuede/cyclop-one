import Foundation
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.cyclop.one.app", category: "SkillMarketplaceClient")

// MARK: - SkillMarketplaceClient

/// Downloads, verifies, and installs skill packages from the Cyclop One Skills Hub.
///
/// - Caches the remote index for 1 hour to reduce network traffic.
/// - Verifies SHA-256 checksums before extraction.
/// - Uses macOS-native `ditto -xk` for zip extraction.
/// - Runs `SkillSafetyScanner` and rejects packages with HIGH findings.
actor SkillMarketplaceClient {

    // MARK: - Singleton

    static let shared = SkillMarketplaceClient()

    // MARK: - Configuration

    private let registryURL = URL(string: "https://raw.githubusercontent.com/cyclop-one/cyclop-hub/main/registry/index.json")!
    private var cachedIndex: MarketplaceIndex?
    private var lastFetchDate: Date?
    private let cacheInterval: TimeInterval = 3600  // 1 hour

    // MARK: - Install directory: ~/.cyclopone/skills/

    private var skillsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cyclopone/skills")
    }

    // MARK: - Private init

    private init() {}

    // MARK: - MarketplaceIndex

    struct MarketplaceIndex: Codable, Sendable {
        let version: String
        let updatedAt: Date
        /// Base URL for constructing lightweight skill download URLs (v2+).
        let baseURL: String?
        let skills: [MarketplaceSkillEntry]
    }

    // MARK: - MarketplaceSkillEntry

    struct MarketplaceSkillEntry: Codable, Sendable, Identifiable {
        let name: String
        let version: String
        let description: String
        let author: String
        let category: String
        let tags: [String]
        let verified: Bool
        let rating: Double?
        let downloads: Int?
        /// Path relative to `baseURL` for fetching `skill.json` directly (lightweight skills).
        let skillURL: String?
        /// ZIP download URL (required for skills with executable tools).
        let downloadURL: String?
        /// SHA-256 checksum for ZIP packages: "sha256:hexstring"
        let checksum: String?
        let homepage: String?
        /// Whether this skill ships custom executables. Defaults to `false` (lightweight).
        let hasExecutableTools: Bool?
        let permissions: [String]

        var id: String { name }

        /// Lightweight skills are prompt+steps only — no executables, install via single JSON fetch.
        var isLightweight: Bool { !(hasExecutableTools ?? false) }
    }

    // MARK: - MarketplaceError

    enum MarketplaceError: Error, LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case invalidManifest(String)
        case networkError(Error)
        case installError(String)
        case notInstalled(String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let actual):
                return "Checksum verification failed — package may be corrupted or tampered with (expected: \(expected), actual: \(actual))"
            case .invalidManifest(let msg):
                return "Invalid skill manifest: \(msg)"
            case .networkError(let err):
                return "Network error: \(err.localizedDescription)"
            case .installError(let msg):
                return "Installation failed: \(msg)"
            case .notInstalled(let name):
                return "Skill '\(name)' is not installed"
            }
        }
    }

    // MARK: - fetchIndex

    /// Fetch the marketplace skills index.
    ///
    /// Returns cached index if it is less than `cacheInterval` old and `forceRefresh` is false.
    /// On network failure, falls back to the last-known cached index if one is available.
    func fetchIndex(forceRefresh: Bool = false) async throws -> MarketplaceIndex {
        // Return cached if still fresh
        if !forceRefresh,
           let cached = cachedIndex,
           let lastFetch = lastFetchDate,
           Date().timeIntervalSince(lastFetch) < cacheInterval {
            logger.debug("SkillMarketplaceClient: returning cached index (\(cached.skills.count) entries)")
            return cached
        }

        logger.info("SkillMarketplaceClient: fetching index from \(self.registryURL.absoluteString)")

        do {
            let (data, _) = try await URLSession.shared.data(from: registryURL)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let index = try decoder.decode(MarketplaceIndex.self, from: data)
            cachedIndex = index
            lastFetchDate = Date()

            logger.info("SkillMarketplaceClient: fetched index v\(index.version) with \(index.skills.count) entries")
            NSLog("CyclopOne [SkillMarketplaceClient]: Index v%@ loaded, %d skills", index.version, index.skills.count)
            return index

        } catch {
            logger.warning("SkillMarketplaceClient: fetch failed — \(error.localizedDescription)")

            // Offline mode: return stale cache if available
            if let cached = cachedIndex {
                logger.info("SkillMarketplaceClient: returning stale cached index (offline mode)")
                return cached
            }

            throw MarketplaceError.networkError(error)
        }
    }

    // MARK: - install

    /// Download, verify, and register a skill package.
    ///
    /// **Lightweight skills** (`isLightweight == true`) fetch `skill.json` directly — no zip.
    /// **Executable skills** download a ZIP, verify checksum, extract, and safety-scan.
    ///
    /// - Parameter entry: The marketplace index entry describing the skill to install.
    /// - Returns: The loaded `SkillPackage` (unapproved; user must approve before tools run).
    /// - Throws: `MarketplaceError` on checksum mismatch, HIGH safety findings, or I/O errors.
    func install(entry: MarketplaceSkillEntry) async throws -> SkillPackage {
        logger.info("SkillMarketplaceClient: installing '\(entry.name)' v\(entry.version) (lightweight=\(entry.isLightweight))")
        NSLog("CyclopOne [SkillMarketplaceClient]: Installing '%@' v%@ (lightweight=%d)", entry.name, entry.version, entry.isLightweight ? 1 : 0)

        // Lightweight install: fetch skill.json directly, no zip required
        if entry.isLightweight {
            let base = cachedIndex?.baseURL ?? "https://raw.githubusercontent.com/cyclop-one/cyclop-hub/main"
            return try await installLightweight(entry: entry, baseURL: base)
        }

        // 1. Ensure install directory exists
        let fm = FileManager.default
        let destDir = skillsDir.appendingPathComponent(entry.name)
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        // 2. Download .skill archive
        guard let rawDownloadURL = entry.downloadURL,
              let downloadURL = URL(string: rawDownloadURL) else {
            throw MarketplaceError.invalidManifest("Missing or invalid downloadURL for executable skill '\(entry.name)'")
        }

        logger.info("SkillMarketplaceClient: downloading from \(rawDownloadURL)")
        let archiveData: Data
        do {
            let (data, _) = try await URLSession.shared.data(from: downloadURL)
            archiveData = data
        } catch {
            throw MarketplaceError.networkError(error)
        }

        logger.info("SkillMarketplaceClient: downloaded \(archiveData.count) bytes for '\(entry.name)'")

        // 3. Verify SHA-256 checksum (required for executable skill ZIPs)
        if let expectedChecksum = entry.checksum {
            let computedHex = sha256Hex(archiveData)
            let expectedHex: String
            if expectedChecksum.hasPrefix("sha256:") {
                expectedHex = String(expectedChecksum.dropFirst("sha256:".count))
            } else {
                expectedHex = expectedChecksum
            }
            guard computedHex.lowercased() == expectedHex.lowercased() else {
                logger.error("SkillMarketplaceClient: checksum mismatch for '\(entry.name)' — expected \(expectedHex), got \(computedHex)")
                throw MarketplaceError.checksumMismatch(expected: expectedHex, actual: computedHex)
            }
            logger.info("SkillMarketplaceClient: checksum verified for '\(entry.name)'")
        } else {
            logger.warning("SkillMarketplaceClient: no checksum provided for '\(entry.name)' — skipping verification")
        }

        // 4. Write archive to temp file
        let tempArchivePath = "/tmp/skill_\(entry.name)_\(UUID().uuidString).zip"
        let tempArchiveURL = URL(fileURLWithPath: tempArchivePath)
        do {
            try archiveData.write(to: tempArchiveURL)
        } catch {
            throw MarketplaceError.installError("Failed to write archive to temp path: \(error.localizedDescription)")
        }
        defer {
            try? fm.removeItem(at: tempArchiveURL)
        }

        // 5. Remove old installation if present
        if fm.fileExists(atPath: destDir.path) {
            do {
                try fm.removeItem(at: destDir)
            } catch {
                throw MarketplaceError.installError("Failed to remove existing installation at \(destDir.path): \(error.localizedDescription)")
            }
        }

        // 6. Extract using macOS-native ditto -xk
        try await extractZip(from: tempArchivePath, to: destDir.path)

        // 7. Read and validate skill.json (or plugin.json) manifest
        let manifestURL = manifestURL(in: destDir)
        guard fm.fileExists(atPath: manifestURL.path) else {
            try? fm.removeItem(at: destDir)
            throw MarketplaceError.invalidManifest("No skill.json or plugin.json found in extracted package at \(destDir.path)")
        }

        // 8. Build SkillPackage from manifest
        guard let pkg = parseSkillPackage(at: manifestURL, directoryURL: destDir) else {
            try? fm.removeItem(at: destDir)
            throw MarketplaceError.invalidManifest("Failed to parse manifest at \(manifestURL.path)")
        }

        // 9. Safety scan — reject packages with HIGH findings
        let scanResult = await SkillSafetyScanner.shared.scan(package: pkg)
        if !scanResult.passed {
            let highFindings = scanResult.findings
                .filter { $0.severity == .high }
                .map { "\($0.file):\($0.line.map(String.init) ?? "?"): \($0.description)" }
                .joined(separator: "; ")
            logger.error("SkillMarketplaceClient: rejected '\(entry.name)' — HIGH risk findings: \(highFindings)")
            try? fm.removeItem(at: destDir)
            throw MarketplaceError.installError("Skill rejected: HIGH risk findings — \(highFindings)")
        }

        logger.info("SkillMarketplaceClient: safety scan passed for '\(entry.name)' (risk=\(scanResult.riskLevel.rawValue), findings=\(scanResult.findings.count))")

        // 10. Reload SkillRegistry so the new package is live
        await SkillRegistry.shared.reload()

        NSLog("CyclopOne [SkillMarketplaceClient]: Installed '%@' v%@ successfully (unapproved)", entry.name, entry.version)
        logger.info("SkillMarketplaceClient: '\(entry.name)' installed — user must approve before tools run")

        // Return the package; it is unapproved until the user explicitly approves it
        return pkg
    }

    // MARK: - installLightweight

    /// Install a lightweight skill (no executables) by fetching its `skill.json` directly.
    ///
    /// Lightweight skills are prompt+step guidance only — no binaries, no ZIP extraction.
    /// The `skill.json` is written to `~/.cyclopone/skills/{name}/skill.json`.
    private func installLightweight(entry: MarketplaceSkillEntry, baseURL: String) async throws -> SkillPackage {
        guard let skillPath = entry.skillURL else {
            throw MarketplaceError.invalidManifest("No skillURL for lightweight install of '\(entry.name)'")
        }

        let fullURLString = baseURL + skillPath
        guard let fullURL = URL(string: fullURLString) else {
            throw MarketplaceError.invalidManifest("Invalid skillURL: \(fullURLString)")
        }

        logger.info("SkillMarketplaceClient: lightweight install — fetching \(fullURLString)")

        let skillData: Data
        do {
            let (data, _) = try await URLSession.shared.data(from: fullURL)
            skillData = data
        } catch {
            throw MarketplaceError.networkError(error)
        }

        let fm = FileManager.default
        let destDir = skillsDir.appendingPathComponent(entry.name)

        // Remove existing installation
        if fm.fileExists(atPath: destDir.path) {
            try? fm.removeItem(at: destDir)
        }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let manifestFile = destDir.appendingPathComponent("skill.json")
        do {
            try skillData.write(to: manifestFile)
        } catch {
            try? fm.removeItem(at: destDir)
            throw MarketplaceError.installError("Failed to write skill.json: \(error.localizedDescription)")
        }

        guard let pkg = parseSkillPackage(at: manifestFile, directoryURL: destDir) else {
            try? fm.removeItem(at: destDir)
            throw MarketplaceError.invalidManifest("Failed to parse skill.json for '\(entry.name)'")
        }

        // Lightweight scan — no executables, should always be LOW risk
        let scanResult = await SkillSafetyScanner.shared.scan(package: pkg)
        if !scanResult.passed {
            try? fm.removeItem(at: destDir)
            throw MarketplaceError.installError("Skill rejected by safety scanner: \(scanResult.riskLevel.rawValue)")
        }

        await SkillRegistry.shared.reload()

        NSLog("CyclopOne [SkillMarketplaceClient]: Lightweight install '%@' v%@ complete (unapproved)", entry.name, entry.version)
        logger.info("SkillMarketplaceClient: lightweight '\(entry.name)' installed — user must approve before use")
        return pkg
    }

    // MARK: - uninstall

    /// Remove an installed skill package from disk and reload the registry.
    func uninstall(name: String) throws {
        let destDir = skillsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: destDir.path) else {
            throw MarketplaceError.notInstalled(name)
        }
        do {
            try FileManager.default.removeItem(at: destDir)
            logger.info("SkillMarketplaceClient: uninstalled '\(name)'")
            NSLog("CyclopOne [SkillMarketplaceClient]: Uninstalled '%@'", name)
        } catch {
            throw MarketplaceError.installError("Failed to remove \(destDir.path): \(error.localizedDescription)")
        }

        // Reload registry synchronously from caller's context (non-isolated call into actor)
        Task {
            await SkillRegistry.shared.reload()
        }
    }

    // MARK: - installedVersion

    /// Returns the version string from the installed skill's manifest, or `nil` if not installed.
    func installedVersion(for name: String) -> String? {
        let destDir = skillsDir.appendingPathComponent(name)
        let manifestFile = manifestURL(in: destDir)
        guard FileManager.default.fileExists(atPath: manifestFile.path),
              let data = try? Data(contentsOf: manifestFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return nil
        }
        return version
    }

    // MARK: - hasUpdate

    /// Returns `true` if the marketplace entry has a different version than what is installed.
    func hasUpdate(for entry: MarketplaceSkillEntry) -> Bool {
        guard let installed = installedVersion(for: entry.name) else {
            return false  // Not installed; nothing to update.
        }
        return installed != entry.version
    }

    // MARK: - Private: SHA-256

    /// Compute SHA-256 hex digest for the given data using CryptoKit.
    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private: Extract zip

    /// Extract a zip archive using macOS-native `/usr/bin/ditto -xk`.
    private func extractZip(from archivePath: String, to destPath: String) async throws {
        try FileManager.default.createDirectory(
            atPath: destPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", archivePath, destPath]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            var hasResumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            process.terminationHandler = { proc in
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    resumeOnce(.success(()))
                } else {
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
                    resumeOnce(.failure(MarketplaceError.installError(
                        "ditto extraction failed (exit \(proc.terminationStatus)): \(stderrText.prefix(500))"
                    )))
                }
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(MarketplaceError.installError(
                    "Failed to launch ditto: \(error.localizedDescription)"
                )))
            }
        }
    }

    // MARK: - Private: Manifest URL resolution

    /// Returns the primary manifest URL within a package directory.
    /// Prefers `skill.json`, falls back to `plugin.json`.
    private func manifestURL(in directory: URL) -> URL {
        let skillJSON = directory.appendingPathComponent("skill.json")
        if FileManager.default.fileExists(atPath: skillJSON.path) {
            return skillJSON
        }
        return directory.appendingPathComponent("plugin.json")
    }

    // MARK: - Private: Parse manifest into SkillPackage

    private func parseSkillPackage(at manifestURL: URL, directoryURL: URL) -> SkillPackage? {
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("SkillMarketplaceClient: cannot parse manifest at \(manifestURL.path)")
            return nil
        }

        guard let name = json["name"] as? String, !name.isEmpty,
              let version = json["version"] as? String, !version.isEmpty,
              let desc = json["description"] as? String, !desc.isEmpty else {
            logger.error("SkillMarketplaceClient: manifest missing required fields at \(manifestURL.path)")
            return nil
        }

        let author = json["author"] as? String
        let triggers = json["triggers"] as? [String] ?? []
        let steps = json["steps"] as? [String] ?? []
        let permissions = json["permissions"] as? [String]
        let maxIterations = json["maxIterations"] as? Int
        let category = json["category"] as? String ?? "other"
        let tags = json["tags"] as? [String] ?? []
        let verified = json["verified"] as? Bool ?? false
        let rating = json["rating"] as? Double

        // Parse tools
        var toolDefs: [SkillToolDef] = []
        if let toolsArray = json["tools"] as? [[String: Any]] {
            for toolJSON in toolsArray {
                guard let toolName = toolJSON["name"] as? String, !toolName.isEmpty,
                      let toolDesc = toolJSON["description"] as? String,
                      let entrypoint = toolJSON["entrypoint"] as? String, !entrypoint.isEmpty else {
                    continue
                }
                // Reject path traversal in entrypoint
                if entrypoint.hasPrefix("/") || entrypoint.components(separatedBy: "/").contains("..") {
                    logger.error("SkillMarketplaceClient: rejected tool '\(toolName)' — invalid entrypoint '\(entrypoint)'")
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

        let marketplaceInfo = SkillMarketplaceInfo(
            category: category,
            tags: tags,
            verified: verified,
            rating: rating
        )

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
            marketplace: marketplaceInfo
        )

        var pkg = SkillPackage(manifest: manifest, source: .marketplace(directoryURL: directoryURL))
        pkg.filePath = manifestURL.path
        // Marketplace packages require approval before their tools can execute
        pkg.requiresApproval = true
        return pkg
    }
}
