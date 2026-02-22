import Foundation

/// Event-sourced journal for agent runs.
/// Persists to `~/.cyclopone/runs/<runId>/journal.jsonl`.
/// Each line is a JSON object representing a run event.
actor RunJournal {

    /// Base directory for all run data.
    static let runsDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cyclopone/runs")
    }()

    let runId: String
    let runDirectory: URL
    let journalURL: URL
    private var fileHandle: FileHandle?

    init(runId: String) {
        self.runId = runId
        self.runDirectory = Self.runsDirectory.appendingPathComponent(runId)
        self.journalURL = runDirectory.appendingPathComponent("journal.jsonl")
    }

    // MARK: - Lifecycle

    /// Create the run directory and open the journal file for writing.
    func open() throws {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        }

        fileHandle = try FileHandle(forWritingTo: journalURL)
        fileHandle?.seekToEndOfFile()
    }

    /// Close the journal file handle.
    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Write Events

    /// Append a single event to the journal.
    func append(_ event: RunEvent) {
        guard let handle = fileHandle else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(contentsOf: "\n".utf8)
            handle.write(data)
        } catch {
            // Journal write failure is non-fatal — log and continue
            print("[RunJournal] Failed to write event: \(error)")
        }
    }

    // MARK: - Save Screenshots

    /// Save a screenshot to the run directory.
    /// Returns the filename (e.g., "iter3_pre.jpg").
    @discardableResult
    func saveScreenshot(_ data: Data, name: String) -> String {
        let fileURL = runDirectory.appendingPathComponent(name)
        try? data.write(to: fileURL)
        return name
    }

    // MARK: - Read / Replay

    /// Read all events from a journal file.
    static func replay(runId: String) -> [RunEvent] {
        let journalURL = runsDirectory
            .appendingPathComponent(runId)
            .appendingPathComponent("journal.jsonl")

        guard let data = try? Data(contentsOf: journalURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return content
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(RunEvent.self, from: Data(line.utf8))
            }
    }

    /// Scan for incomplete runs (no run.complete or run.fail event).
    static func findIncompleteRuns() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var incompleteRunIds: [String] = []

        for entry in entries where entry.hasDirectoryPath {
            let runId = entry.lastPathComponent
            let events = replay(runId: runId)

            let hasTerminalEvent = events.contains { event in
                event.type == .runComplete || event.type == .runFail || event.type == .runAbandoned
            }

            if !hasTerminalEvent && !events.isEmpty {
                incompleteRunIds.append(runId)
            }
        }

        return incompleteRunIds
    }

    /// List all run IDs sorted by creation date (newest first).
    static func listRuns(limit: Int = 10) -> [(runId: String, command: String?, timestamp: Date?)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return []
        }

        return entries
            .filter { $0.hasDirectoryPath }
            .sorted {
                let date1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let date2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return date1 > date2
            }
            .prefix(limit)
            .map { entry in
                let runId = entry.lastPathComponent
                let events = replay(runId: runId)
                let createEvent = events.first { $0.type == .runCreated }
                return (runId: runId, command: createEvent?.command, timestamp: createEvent?.timestamp)
            }
    }

    // MARK: - Sprint 16: Crash Recovery

    /// Metadata extracted from a journal replay, used for crash recovery.
    struct ReplayedRunState: Sendable {
        let runId: String
        let command: String
        let source: String
        let iterationCount: Int
        let lastVerificationScore: Int?
        let lastEventTimestamp: Date
        /// Tool calls and results reconstructed from journal events, suitable
        /// for rebuilding Claude API conversation history.
        let toolEvents: [(tool: String, result: String?)]
    }

    /// Replay a run's journal and reconstruct enough state to resume it.
    ///
    /// Reads all events from the JSONL file and extracts the original command,
    /// source, iteration count, last verification score, and tool call history
    /// so the Orchestrator can resume from the last committed iteration.
    ///
    /// - Parameter runId: The run directory name.
    /// - Returns: The reconstructed run state, or `nil` if the journal is empty
    ///   or missing the `run.created` event.
    static func replayRunState(runId: String) -> ReplayedRunState? {
        let events = replay(runId: runId)
        guard !events.isEmpty else { return nil }

        // Extract the original command from the run.created event
        guard let createEvent = events.first(where: { $0.type == .runCreated }),
              let command = createEvent.command else {
            return nil
        }

        let source = createEvent.source ?? "chat"

        // Count completed iterations (iteration.end events)
        let iterationCount = events.filter { $0.type == .iterationEnd }.count

        // Find the last verification score
        let lastScore = events.last(where: { $0.verificationScore != nil })?.verificationScore

        // Collect tool execution events for conversation reconstruction
        let toolEvents: [(tool: String, result: String?)] = events
            .filter { $0.type == .toolExecuted }
            .compactMap { event in
                guard let tool = event.tool else { return nil }
                return (tool: tool, result: event.toolResult)
            }

        let lastTimestamp = events.last?.timestamp ?? Date.distantPast

        return ReplayedRunState(
            runId: runId,
            command: command,
            source: source,
            iterationCount: iterationCount,
            lastVerificationScore: lastScore,
            lastEventTimestamp: lastTimestamp,
            toolEvents: toolEvents
        )
    }

    /// Check whether an incomplete run is stale (older than the given threshold).
    ///
    /// A run is considered stale if its most recent journal event is older
    /// than `maxAge` seconds ago. Stale runs should be abandoned rather than
    /// resumed, because the Mac's state has likely changed significantly.
    ///
    /// - Parameters:
    ///   - runId: The run directory name.
    ///   - maxAge: Maximum age in seconds before considering the run stale. Default: 1 hour.
    /// - Returns: `true` if the run's last event is older than `maxAge`.
    static func isRunStale(runId: String, maxAge: TimeInterval = 3600) -> Bool {
        let events = replay(runId: runId)
        guard let lastEvent = events.last else { return true }
        return Date().timeIntervalSince(lastEvent.timestamp) > maxAge
    }

    /// Mark a run as abandoned by appending a `run.abandoned` event.
    ///
    /// Used for incomplete runs that are too old to resume meaningfully.
    /// Opens the journal file, appends the event, and closes it.
    ///
    /// - Parameter runId: The run directory name.
    static func markAbandoned(runId: String) {
        let journalURL = runsDirectory
            .appendingPathComponent(runId)
            .appendingPathComponent("journal.jsonl")

        guard FileManager.default.fileExists(atPath: journalURL.path),
              let handle = try? FileHandle(forWritingTo: journalURL) else {
            return
        }

        handle.seekToEndOfFile()

        let event = RunEvent.abandoned(reason: "Run stale (>1 hour without activity)")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if var data = try? encoder.encode(event) {
            data.append(contentsOf: "\n".utf8)
            handle.write(data)
        }

        try? handle.close()
    }

    // MARK: - Sprint 16: Retention & Cleanup

    /// Retention policy thresholds.
    struct RetentionPolicy {
        /// Days to keep completed runs. Default: 30.
        var completedDays: Int = 30
        /// Days to keep failed runs. Default: 7.
        var failedDays: Int = 7
        /// Days to keep abandoned runs. Default: 3.
        var abandonedDays: Int = 3
    }

    /// Terminal state of a run, determined from its journal events.
    enum RunTerminalState {
        case completed
        case failed
        case abandoned
        case stuck
        case cancelled
        case incomplete
    }

    /// Determine the terminal state of a run from its journal events.
    static func terminalState(forRunId runId: String) -> RunTerminalState {
        let events = replay(runId: runId)
        // Check from most significant terminal events
        if events.contains(where: { $0.type == .runComplete }) { return .completed }
        if events.contains(where: { $0.type == .runAbandoned }) { return .abandoned }
        if events.contains(where: { $0.type == .runStuck }) { return .stuck }
        if events.contains(where: { $0.type == .runFail }) { return .failed }
        if events.contains(where: { $0.type == .runCancelled }) { return .cancelled }
        return .incomplete
    }

    /// Delete old runs according to the retention policy.
    ///
    /// For each run directory under `~/.cyclopone/runs/`:
    /// 1. Determine the terminal state from journal events.
    /// 2. Find the timestamp of the last event.
    /// 3. If the run is older than the retention threshold for its state, delete the entire directory.
    ///
    /// For completed runs, intermediate screenshots are also pruned (keeping only
    /// the first and last) even if the run is within its retention window.
    ///
    /// - Parameter policy: The retention thresholds. Uses defaults if not specified.
    /// - Returns: The number of runs deleted.
    @discardableResult
    static func cleanupOldRuns(policy: RetentionPolicy = RetentionPolicy()) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var deletedCount = 0
        let now = Date()

        for entry in entries where entry.hasDirectoryPath {
            let runId = entry.lastPathComponent
            let events = replay(runId: runId)
            guard let lastEvent = events.last else {
                // Empty journal — delete the directory
                try? fm.removeItem(at: entry)
                deletedCount += 1
                continue
            }

            let age = now.timeIntervalSince(lastEvent.timestamp)

            // Determine terminal state inline to avoid redundant replay
            let state: RunTerminalState
            if events.contains(where: { $0.type == .runComplete }) { state = .completed }
            else if events.contains(where: { $0.type == .runAbandoned }) { state = .abandoned }
            else if events.contains(where: { $0.type == .runStuck }) { state = .stuck }
            else if events.contains(where: { $0.type == .runFail }) { state = .failed }
            else if events.contains(where: { $0.type == .runCancelled }) { state = .cancelled }
            else { state = .incomplete }

            let maxAgeDays: Int
            switch state {
            case .completed:
                maxAgeDays = policy.completedDays
                // Prune intermediate screenshots for completed runs within retention
                pruneIntermediateScreenshots(runDirectory: entry)
            case .failed, .stuck, .cancelled:
                maxAgeDays = policy.failedDays
            case .abandoned:
                maxAgeDays = policy.abandonedDays
                // Delete screenshots immediately for abandoned runs
                deleteScreenshots(runDirectory: entry)
            case .incomplete:
                // Incomplete runs older than 1 day are cleaned up
                maxAgeDays = 1
            }

            let maxAge = TimeInterval(maxAgeDays * 24 * 3600)
            if age > maxAge {
                try? fm.removeItem(at: entry)
                deletedCount += 1
            }
        }

        return deletedCount
    }

    /// Remove intermediate screenshots from a completed run, keeping only the
    /// first (`iter0_pre.jpg`) and the last post-screenshot.
    private static func pruneIntermediateScreenshots(runDirectory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: runDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        let screenshots = files
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Keep the first and last screenshot, delete everything in between
        guard screenshots.count > 2 else { return }
        let toDelete = screenshots.dropFirst().dropLast()
        for file in toDelete {
            try? fm.removeItem(at: file)
        }
    }

    /// Delete all screenshots in a run directory (for abandoned runs).
    private static func deleteScreenshots(runDirectory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: runDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "jpg" {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Sprint 16: Disk Usage

    /// Information about disk usage of the runs directory.
    struct DiskUsageInfo {
        /// Total size in bytes of all run data.
        let totalBytes: Int64
        /// Number of run directories.
        let runCount: Int
        /// Number of screenshot files.
        let screenshotCount: Int
        /// Total size of screenshot files in bytes.
        let screenshotBytes: Int64

        /// Human-readable total size string (e.g. "12.3 MB").
        var formattedTotal: String {
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }

        /// Human-readable screenshot size string.
        var formattedScreenshots: String {
            ByteCountFormatter.string(fromByteCount: screenshotBytes, countStyle: .file)
        }
    }

    /// Calculate disk usage for the `~/.cyclopone/runs/` directory.
    ///
    /// Walks the entire directory tree, summing file sizes and counting
    /// screenshots. Returns a `DiskUsageInfo` struct with totals.
    static func diskUsage() -> DiskUsageInfo {
        let fm = FileManager.default
        var totalBytes: Int64 = 0
        var screenshotCount = 0
        var screenshotBytes: Int64 = 0
        var runCount = 0

        guard let entries = try? fm.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return DiskUsageInfo(totalBytes: 0, runCount: 0, screenshotCount: 0, screenshotBytes: 0)
        }

        for entry in entries where entry.hasDirectoryPath {
            runCount += 1

            guard let files = try? fm.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }

            for file in files {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize else { continue }

                totalBytes += Int64(size)

                if file.pathExtension == "jpg" {
                    screenshotCount += 1
                    screenshotBytes += Int64(size)
                }
            }
        }

        return DiskUsageInfo(
            totalBytes: totalBytes,
            runCount: runCount,
            screenshotCount: screenshotCount,
            screenshotBytes: screenshotBytes
        )
    }
}

// MARK: - Run Events

struct RunEvent: Codable {
    let type: EventType
    let timestamp: Date
    var iteration: Int?
    var command: String?
    var source: String?
    var tool: String?
    var toolParams: String?
    var toolResult: String?
    var screenshot: String?          // Filename of saved screenshot
    var verificationScore: Int?
    var verificationMethod: String?
    var summary: String?
    var reason: String?
    var completionToken: String?

    enum EventType: String, Codable {
        case runCreated = "run.created"
        case iterationStart = "iteration.start"
        case toolExecuted = "tool.executed"
        case iterationEnd = "iteration.end"
        case verificationResult = "verification.result"
        case verificationTokenRejected = "verification.token_rejected"
        case runComplete = "run.complete"
        case runFail = "run.fail"
        case runStuck = "run.stuck"
        case runCancelled = "run.cancelled"
        case runEscalated = "run.escalated"
        case runAbandoned = "run.abandoned"
        case approvalRequested = "approval.requested"
        case approvalResult = "approval.result"
    }

    /// Convenience initializer for common events.
    static func created(command: String, source: String) -> RunEvent {
        RunEvent(type: .runCreated, timestamp: Date(), command: command, source: source)
    }

    static func iterationStart(iteration: Int, screenshot: String?) -> RunEvent {
        RunEvent(type: .iterationStart, timestamp: Date(), iteration: iteration, screenshot: screenshot)
    }

    static func toolExecuted(tool: String, result: String?) -> RunEvent {
        RunEvent(type: .toolExecuted, timestamp: Date(), tool: tool, toolResult: result)
    }

    static func iterationEnd(iteration: Int, screenshot: String?, verificationScore: Int?) -> RunEvent {
        RunEvent(type: .iterationEnd, timestamp: Date(), iteration: iteration, screenshot: screenshot, verificationScore: verificationScore)
    }

    static func complete(summary: String, finalScore: Int?) -> RunEvent {
        RunEvent(type: .runComplete, timestamp: Date(), verificationScore: finalScore, summary: summary)
    }

    static func fail(reason: String) -> RunEvent {
        RunEvent(type: .runFail, timestamp: Date(), reason: reason)
    }

    static func stuck(reason: String) -> RunEvent {
        RunEvent(type: .runStuck, timestamp: Date(), reason: reason)
    }

    static func cancelled() -> RunEvent {
        RunEvent(type: .runCancelled, timestamp: Date())
    }

    static func abandoned(reason: String) -> RunEvent {
        RunEvent(type: .runAbandoned, timestamp: Date(), reason: reason)
    }
}
