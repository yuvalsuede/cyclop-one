import Foundation
import AppKit

/// Manages plan step state, stuck detection, outcome tracking, and step instruction building.
///
/// This is a plain **struct** owned by the Orchestrator actor (no actor boundary of its own).
/// All state-modifying methods use `mutating func`.
///
/// Extracted from Orchestrator.swift in Sprint 3 to reduce Orchestrator's line count
/// and separate step-level concerns from run-level lifecycle management.
struct StepStateMachine {

    // MARK: - Configuration (injected from RunConfig)

    /// Consecutive similar screenshots/texts before circuit break.
    var stuckThreshold: Int = 3

    /// Maximum Hamming distance between perceptual hashes to consider "similar".
    /// 0 = identical, 5 = very similar (tolerates minor UI changes like cursor blink,
    /// typing a few characters). Higher values are more forgiving.
    var perceptualHashTolerance: Int = 10

    // MARK: - Plan Step Tracking

    /// The current execution plan (nil if no plan or simple task).
    var currentPlan: ExecutionPlan?

    /// Index of the step currently being executed (0-based).
    var currentStepIndex: Int = 0

    /// Iterations spent on the current step (resets when advancing).
    var currentStepIterations: Int = 0

    /// History of step outcomes for journal and brain consultation.
    var stepOutcomes: [(stepId: Int, outcome: StepOutcome)] = []

    // MARK: - Stuck Detection State

    /// Last N screenshot image data for comparison (kept for backward compat / logging).
    var recentScreenshotData: [Data] = []

    /// Last N perceptual hashes of screenshots for similarity comparison.
    var recentScreenshotHashes: [UInt64] = []

    /// Last N AX tree summaries for comparison alongside screenshots.
    var recentAXTreeSummaries: [String] = []

    /// Last N text responses for repetition detection (Sprint 14).
    var recentTextResponses: [String] = []

    /// Pre-action screenshot for visual diff comparison.
    var preActionScreenshot: ScreenCapture?

    /// Whether we've already escalated to the brain model for the current run.
    var hasEscalatedToBrain: Bool = false

    // MARK: - Reset

    /// Reset all step tracking state for a new run.
    mutating func resetForNewRun() {
        currentPlan = nil
        currentStepIndex = 0
        currentStepIterations = 0
        stepOutcomes.removeAll()
        recentScreenshotData.removeAll()
        recentScreenshotHashes.removeAll()
        recentAXTreeSummaries.removeAll()
        recentTextResponses.removeAll()
        preActionScreenshot = nil
        hasEscalatedToBrain = false
        currentAlternativeIndex = 0
    }

    // MARK: - Screenshot & Text Tracking

    /// Record a post-iteration screenshot for stuck detection.
    /// Computes a perceptual hash and stores it alongside the raw data.
    mutating func recordScreenshot(_ data: Data) {
        recentScreenshotData.append(data)
        if recentScreenshotData.count > stuckThreshold {
            recentScreenshotData.removeFirst()
        }

        let hash = Self.perceptualHash(data) ?? 0
        recentScreenshotHashes.append(hash)
        if recentScreenshotHashes.count > stuckThreshold {
            recentScreenshotHashes.removeFirst()
        }
    }

    /// Record an AX tree summary for stuck detection.
    mutating func recordAXTreeSummary(_ summary: String) {
        recentAXTreeSummaries.append(summary)
        if recentAXTreeSummaries.count > stuckThreshold {
            recentAXTreeSummaries.removeFirst()
        }
    }

    /// Record a text response for stuck detection.
    mutating func recordTextResponse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentTextResponses.append(trimmed)
        if recentTextResponses.count > stuckThreshold {
            recentTextResponses.removeFirst()
        }
    }

    /// Clear stuck tracking data (e.g. after brain consultation or step transition).
    mutating func clearStuckTracking() {
        recentScreenshotData.removeAll()
        recentScreenshotHashes.removeAll()
        recentTextResponses.removeAll()
        recentAXTreeSummaries.removeAll()
    }

    // MARK: - Stuck Detection

    /// Enhanced stuck detection that checks both screenshot similarity and text repetition.
    ///
    /// Returns a reason string if stuck is detected, nil otherwise.
    func detectStuck() -> String? {
        // Check 1: Screenshot similarity (original logic)
        if isScreenshotStuck() {
            return "Last \(stuckThreshold) screenshots are identical"
        }

        // Check 2: Text response repetition (Sprint 14)
        if isTextStuck() {
            return "Last \(stuckThreshold) text responses are repeating"
        }

        return nil
    }

    /// Check if the last N screenshots are perceptually similar (agent is stuck).
    /// Uses perceptual hashing (average hash) — tolerates minor pixel differences
    /// like cursor blink, anti-aliasing, and JPEG compression artifacts.
    ///
    /// Also checks AX tree summaries: if screenshots are perceptually similar
    /// but the AX tree has changed, the agent IS making progress (e.g. typing text
    /// that doesn't change the overall visual layout enough).
    func isScreenshotStuck() -> Bool {
        guard recentScreenshotHashes.count >= stuckThreshold else { return false }
        let recent = Array(recentScreenshotHashes.suffix(stuckThreshold))
        let first = recent[0]

        // Check all recent hashes are within tolerance of the first
        let allSimilar = recent.dropFirst().allSatisfy { hash in
            Self.hammingDistance(first, hash) <= perceptualHashTolerance
        }

        guard allSimilar else { return false }

        // Screenshots are perceptually similar — check if AX tree changed
        if recentAXTreeSummaries.count >= stuckThreshold {
            let recentAX = Array(recentAXTreeSummaries.suffix(stuckThreshold))
            let firstAX = recentAX[0]
            let allAXIdentical = recentAX.dropFirst().allSatisfy { $0 == firstAX }
            if !allAXIdentical {
                NSLog("CyclopOne [StepStateMachine]: Screenshots perceptually similar (pHash) but AX tree changed -- NOT stuck")
                return false
            }
        }

        // Log Hamming distances for diagnostics
        let distances = recent.dropFirst().map { Self.hammingDistance(first, $0) }
        NSLog("CyclopOne [StepStateMachine]: Screenshot stuck detected (perceptual hash) -- last %d screenshots similar, Hamming distances: %@, tolerance: %d",
              stuckThreshold, distances.map(String.init).joined(separator: ","), perceptualHashTolerance)
        return true
    }

    /// Check if the last N text responses are substantially the same.
    /// Uses normalized comparison to catch near-identical responses that differ
    /// only in whitespace, punctuation, or minor variations.
    func isTextStuck() -> Bool {
        guard recentTextResponses.count >= stuckThreshold else { return false }
        let recent = Array(recentTextResponses.suffix(stuckThreshold))

        // Normalize: lowercase, collapse whitespace, trim
        let normalized = recent.map { normalizeForComparison($0) }
        let first = normalized[0]

        // All responses must be identical after normalization
        return normalized.dropFirst().allSatisfy { $0 == first }
    }

    /// Normalize text for stuck comparison: lowercase, collapse whitespace,
    /// remove leading/trailing whitespace.
    func normalizeForComparison(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Completion Token Detection

    /// Detect the `<task_complete/>` marker in Claude's text response.
    /// Robust against whitespace variations, case differences, and minor formatting.
    /// Matches: `<task_complete/>`, `<task_complete />`, `<TASK_COMPLETE/>`,
    /// `< task_complete / >`, `<task_complete>`, etc.
    func containsCompletionToken(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        // Match <task_complete/> or <task_complete> (self-closing or not)
        return normalized.contains("<task_complete/>")
            || normalized.contains("<task_complete>")
    }

    // MARK: - Step Outcome Validation

    /// Validate whether a plan step's expected outcome was achieved.
    /// Uses a lightweight heuristic approach (no Opus calls per step).
    func validateStepOutcome(
        step: PlanStep,
        textContent: String
    ) -> StepOutcome {
        let heuristicScore = computeStepHeuristicScore(
            step: step,
            textContent: textContent
        )

        if heuristicScore >= 0.8 {
            return .succeeded(
                confidence: heuristicScore,
                evidence: "Heuristic score \(String(format: "%.2f", heuristicScore)): text matches expected outcome"
            )
        }

        if heuristicScore <= 0.3 {
            return .failed(
                reason: "Heuristic score \(String(format: "%.2f", heuristicScore)): outcome does not match expected"
            )
        }

        // Uncertain range (0.3-0.8): proceed but log
        return .uncertain(
            confidence: heuristicScore,
            evidence: "Heuristic score \(String(format: "%.2f", heuristicScore)): uncertain match"
        )
    }

    /// Compute a heuristic confidence score (0.0-1.0) for whether a step
    /// achieved its expected outcome.
    func computeStepHeuristicScore(
        step: PlanStep,
        textContent: String
    ) -> Double {
        var score = 0.0
        var factors = 0

        // Factor 1: Keyword overlap with expectedOutcome
        let outcomeKeywords = extractKeywords(from: step.expectedOutcome)
        let textLower = textContent.lowercased()
        let matchedKeywords = outcomeKeywords.filter { textLower.contains($0) }
        if !outcomeKeywords.isEmpty {
            let keywordRatio = Double(matchedKeywords.count) / Double(outcomeKeywords.count)
            score += keywordRatio
            factors += 1
        }

        // Factor 2: No error indicators
        let hasErrors = ["error", "failed", "not found", "denied", "timeout"]
            .contains { textLower.contains($0) }
        score += hasErrors ? 0.0 : 0.8
        factors += 1

        // Factor 3: Tool usage matches expectedTools
        if let expectedTools = step.expectedTools, !expectedTools.isEmpty {
            let usedExpectedTool = expectedTools.contains { tool in
                textLower.contains(tool.lowercased())
            }
            score += usedExpectedTool ? 0.9 : 0.3
            factors += 1
        }

        // Factor 4: Explicit completion signal present
        // Only contributes when the agent explicitly signals task completion via
        // <task_complete/> marker. Avoids being a constant factor (textContent
        // is almost always non-empty, so the previous OR condition was trivially true).
        if containsCompletionToken(textContent) {
            score += 0.9
            factors += 1
        }

        return factors > 0 ? score / Double(factors) : 0.5
    }

    /// Extract meaningful keywords from a string for fuzzy matching.
    func extractKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been",
            "being", "have", "has", "had", "do", "does", "did", "will",
            "would", "could", "should", "may", "might", "shall", "can",
            "to", "of", "in", "for", "on", "with", "at", "by", "from",
            "and", "or", "not", "no", "but", "if", "then", "than",
            "that", "this", "it", "its"
        ]
        return text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// Describe a StepOutcome as a human-readable string.
    func describeOutcome(_ outcome: StepOutcome) -> String {
        switch outcome {
        case .succeeded(let confidence, let evidence):
            return "Succeeded (confidence: \(String(format: "%.2f", confidence)), \(evidence))"
        case .uncertain(let confidence, let evidence):
            return "Uncertain (confidence: \(String(format: "%.2f", confidence)), \(evidence))"
        case .failed(let reason):
            return "Failed (\(reason))"
        case .skipped(let reason):
            return "Skipped (\(reason))"
        }
    }

    // MARK: - Step Dependencies

    /// Check whether a step's dependencies are satisfied.
    /// Returns nil if the step can proceed, or a reason string if it's blocked.
    func canProceedToStep(_ step: PlanStep) -> String? {
        guard let deps = step.dependsOn, !deps.isEmpty else { return nil }

        for depId in deps {
            // Check if the dependency step has a successful outcome
            let depOutcome = stepOutcomes.first(where: { $0.stepId == depId })
            if let outcome = depOutcome {
                switch outcome.outcome {
                case .succeeded:
                    continue // Dependency satisfied
                case .uncertain:
                    continue // Uncertain is OK — proceed with warning
                case .failed(let reason):
                    return "Dependency step \(depId + 1) failed: \(reason)"
                case .skipped(let reason):
                    return "Dependency step \(depId + 1) was skipped: \(reason)"
                }
            } else {
                // Dependency step hasn't been executed yet
                return "Dependency step \(depId + 1) has not been executed yet"
            }
        }
        return nil // All dependencies satisfied
    }

    // MARK: - Alternative Approaches

    /// Track which alternative approach index we're on for the current step.
    var currentAlternativeIndex: Int = 0

    // MARK: - Step Criticality

    /// Determine the effective criticality of a step.
    /// If the brain explicitly set it, use that. Otherwise, auto-classify
    /// based on action keywords: text-input steps are critical.
    func effectiveCriticality(of step: PlanStep) -> StepCriticality {
        if step.criticality != .normal { return step.criticality }
        let actionLower = step.action.lowercased()
        let criticalKeywords = [
            "type", "enter", "fill", "input", "email", "address",
            "recipient", "compose", "write", "paste", "type_text",
            "send", "submit", "password", "username", "login", "sign in"
        ]
        if criticalKeywords.contains(where: { actionLower.contains($0) }) {
            return .critical
        }
        return .normal
    }

    // MARK: - Step Instruction Building

    // MARK: - Perceptual Hashing

    /// Compute a 64-bit perceptual hash (average hash / aHash) from image data.
    ///
    /// Algorithm:
    /// 1. Decode image data (JPEG/PNG) to CGImage
    /// 2. Resize to 8×8 pixels
    /// 3. Convert to grayscale
    /// 4. Compute mean pixel value
    /// 5. Set each bit to 1 if pixel > mean, 0 otherwise
    ///
    /// Returns nil if image data cannot be decoded.
    static func perceptualHash(_ data: Data) -> UInt64? {
        guard let imageRep = NSBitmapImageRep(data: data),
              let cgImage = imageRep.cgImage else {
            return nil
        }

        // Create 8x8 grayscale context
        let size = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        // Draw image resized to 8x8 (built-in interpolation handles anti-aliasing)
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let pixelData = context.data else { return nil }

        let pixels = pixelData.bindMemory(to: UInt8.self, capacity: size * size)

        // Compute mean pixel value
        var sum: UInt64 = 0
        for i in 0..<(size * size) {
            sum += UInt64(pixels[i])
        }
        let mean = sum / UInt64(size * size)

        // Build 64-bit hash: bit = 1 if pixel > mean
        var hash: UInt64 = 0
        for i in 0..<(size * size) {
            if UInt64(pixels[i]) > mean {
                hash |= (1 << i)
            }
        }

        return hash
    }

    /// Hamming distance between two 64-bit hashes (number of differing bits).
    /// 0 = identical, 64 = completely different.
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    // MARK: - Step Instruction Building

    /// Build the instruction string injected into the executor's system prompt
    /// for a specific plan step.
    /// Sanitize brain-generated text to prevent prompt injection.
    /// Strips XML-like tags that could be interpreted as system directives.
    private func sanitizeBrainText(_ text: String) -> String {
        var sanitized = text
        // Strip XML/HTML tags that could be interpreted as system directives
        let dangerousPatterns = [
            "<system>", "</system>", "<tool_use>", "</tool_use>",
            "<tool_result>", "</tool_result>", "<function_calls>", "</function_calls>",
            "```applescript", "```shell", "```bash"
        ]
        for pattern in dangerousPatterns {
            sanitized = sanitized.replacingOccurrences(of: pattern, with: "[filtered]", options: .caseInsensitive)
        }
        // Cap length to prevent prompt stuffing
        if sanitized.count > 2000 {
            sanitized = String(sanitized.prefix(2000)) + "... [truncated]"
        }
        return sanitized
    }

    func buildStepInstruction(step: PlanStep, plan: ExecutionPlan, stepOutcomes: [(Int, StepOutcome)] = []) -> String {
        var instruction = "Step \(step.id + 1) of \(plan.steps.count): \(sanitizeBrainText(step.title))"
        instruction += "\n\n\(sanitizeBrainText(step.action))"

        if let targetApp = step.targetApp {
            instruction += "\n\nTARGET APP: \(sanitizeBrainText(targetApp))"
        }

        instruction += "\n\nEXPECTED RESULT: \(sanitizeBrainText(step.expectedOutcome))"

        // Add context about what was done previously (brief, not full history)
        if step.id > 0 {
            let previousTitles = plan.steps.prefix(step.id).map { $0.title }
            instruction += "\n\nPrevious steps completed: \(previousTitles.joined(separator: ", "))"
        }

        // Warn about previous step failures
        let failedSteps = stepOutcomes.filter { if case .failed = $0.1 { return true }; return false }
        if !failedSteps.isEmpty {
            let failedDesc = failedSteps.map { "Step \($0.0 + 1)" }.joined(separator: ", ")
            instruction += "\n\nWARNING: Previous steps failed: \(failedDesc). Verify preconditions before acting."
        }

        return instruction
    }
}
