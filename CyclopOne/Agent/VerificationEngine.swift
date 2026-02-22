import Foundation
import AppKit

/// Result of a verification pass.
struct VerificationScore: Sendable {
    /// Overall composite score (0-100).
    let overall: Int
    /// Visual diff score (heuristic fallback only).
    let visualScore: Int
    /// Structural score (heuristic fallback only).
    let structuralScore: Int
    /// Output score (heuristic fallback only).
    let outputScore: Int
    /// Detailed breakdown for journal/debugging.
    let breakdown: [String: String]
    /// Whether the overall score meets the passing threshold.
    let passed: Bool
    /// Human-readable reason from the LLM verifier (empty for heuristic fallback).
    let reason: String

    /// Default passing threshold.
    static let defaultThreshold = 60
}

/// Verification engine that scores post-action state using LLM vision analysis.
///
/// Primary verification sends the post-action screenshot to Claude Haiku for
/// visual assessment of task completion. Falls back to heuristic scoring
/// (pixel diff, accessibility tree, keyword matching) when the LLM call fails.
actor VerificationEngine {

    // MARK: - Configuration

    /// Weights for composite scoring in heuristic fallback (must sum to 1.0).
    struct Weights {
        let visual: Double
        let structural: Double
        let output: Double

        init(visual: Double = 0.30, structural: Double = 0.30, output: Double = 0.40) {
            self.visual = visual
            self.structural = structural
            self.output = output
        }
    }

    private let weights = Weights()
    private let accessibility = AccessibilityService.shared

    /// Token usage from the most recent verification call (for cost tracking).
    private(set) var lastVerificationInputTokens: Int = 0
    private(set) var lastVerificationOutputTokens: Int = 0

    // MARK: - Success / Failure Indicators (for heuristic fallback)

    private let successIndicators: [String] = [
        "completed", "done", "created", "saved", "success",
        "opened", "launched", "navigated", "typed", "clicked",
        "pressed", "scrolled", "dragged", "moved", "installed",
        "downloaded", "uploaded", "sent", "finished", "applied",
        "updated", "modified", "set", "configured", "enabled",
        "disabled", "connected", "resolved", "found", "loaded",
        "copied", "pasted", "deleted", "removed", "closed",
        "ok", "200", "exit code 0"
    ]

    private let failureIndicators: [String] = [
        "error", "failed", "not found", "couldn't", "cannot",
        "unable", "denied", "permission", "timeout", "timed out",
        "crash", "exception", "invalid", "missing", "refused",
        "rejected", "unauthorized", "forbidden", "404", "500",
        "502", "503", "aborted", "cancelled", "no such file",
        "does not exist", "exit code 1", "exit code 2",
        "fatal", "panic", "segfault", "killed"
    ]

    // MARK: - Public Interface

    /// Verify the result of an agent iteration using LLM vision scoring.
    ///
    /// Sends the post-action screenshot to Claude Haiku with a verification prompt.
    /// The LLM returns a JSON score and reason. Falls back to heuristic scoring
    /// if the LLM call fails (network error, rate limit, parse error).
    ///
    /// - Parameters:
    ///   - command: The original user command being executed.
    ///   - textContent: Text output from Claude's response / tool results in this iteration.
    ///   - postScreenshot: Screenshot captured after the action (may be nil).
    ///   - preScreenshot: Screenshot captured before the action (may be nil).
    ///   - threshold: Minimum overall score to pass (default 60).
    /// - Returns: A `VerificationScore` with score and reason.
    func verify(
        command: String,
        textContent: String,
        postScreenshot: ScreenCapture?,
        preScreenshot: ScreenCapture?,
        threshold: Int = VerificationScore.defaultThreshold
    ) async -> VerificationScore {

        // If no screenshot available, return neutral score
        guard let screenshotData = postScreenshot?.imageData else {
            NSLog("CyclopOne [Verification]: No post-screenshot, returning neutral score")
            return VerificationScore(
                overall: 50,
                visualScore: 50, structuralScore: 50, outputScore: 50,
                breakdown: ["method": "no_screenshot", "command": command],
                passed: 50 >= threshold,
                reason: "No screenshot available for verification"
            )
        }

        NSLog("CyclopOne [Verification]: LLM verify starting — promptLen=%d, screenshotSize=%d bytes, mediaType=%@, threshold=%d",
              command.count, screenshotData.count,
              postScreenshot?.mediaType ?? "unknown", threshold)

        let prompt = """
        You are a verification agent. The user asked: "\(command)"

        Look at the current screenshot and assess:
        1. Has the requested action been completed?
        2. Is the screen in the expected state?

        Score 0-100 where:
        - 100 = fully complete, screen shows expected result
        - 80+ = mostly complete, minor issues
        - 40-79 = partial progress, needs more work
        - 0-39 = no progress or wrong state

        Respond with ONLY a JSON object:
        {"score": N, "reason": "brief explanation"}
        """

        do {
            let response = try await ClaudeAPIService.shared.verifyWithVision(
                prompt: prompt,
                screenshot: screenshotData,
                mediaType: postScreenshot?.mediaType ?? "image/png"
            )

            NSLog("CyclopOne [Verification]: LLM raw response (%d chars): %@",
                  response.count, String(response.prefix(300)))

            // Parse JSON response from the LLM
            let (score, reason) = parseVerificationResponse(response)

            NSLog("CyclopOne [Verification]: LLM score=%d, reason=%@", score, reason)

            return VerificationScore(
                overall: score,
                visualScore: score, structuralScore: score, outputScore: score,
                breakdown: [
                    "method": "llm_vision",
                    "raw_response": String(response.prefix(500)),
                    "threshold": "\(threshold)",
                    "command": command
                ],
                passed: score >= threshold,
                reason: reason
            )
        } catch {
            NSLog("CyclopOne [Verification]: LLM call failed (%@), falling back to heuristic scoring. Error domain=%@",
                  error.localizedDescription, (error as NSError).domain)
            return await fallbackVerify(
                command: command,
                textContent: textContent,
                postScreenshot: postScreenshot,
                preScreenshot: preScreenshot,
                threshold: threshold
            )
        }
    }

    // MARK: - LLM Response Parsing

    /// Parse the JSON response from the verification LLM call.
    /// Expected format: {"score": N, "reason": "..."}
    /// Returns (score, reason) with safe defaults if parsing fails.
    private func parseVerificationResponse(_ response: String) -> (Int, String) {
        // Try to extract JSON from the response (LLM may wrap it in markdown)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON object boundaries
        guard let jsonStart = trimmed.firstIndex(of: "{"),
              let jsonEnd = trimmed.lastIndex(of: "}") else {
            NSLog("CyclopOne [Verification]: No JSON found in response: %@", String(trimmed.prefix(200)))
            return (50, "Could not parse verification response")
        }

        let jsonString = String(trimmed[jsonStart...jsonEnd])

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            NSLog("CyclopOne [Verification]: Invalid JSON: %@", jsonString)
            return (50, "Could not parse verification JSON")
        }

        let score: Int
        if let s = json["score"] as? Int {
            score = min(100, max(0, s))
        } else if let s = json["score"] as? Double {
            score = min(100, max(0, Int(s.rounded())))
        } else {
            score = 50
        }

        let reason = json["reason"] as? String ?? "No reason provided"

        return (score, reason)
    }

    // MARK: - Heuristic Fallback

    /// Heuristic-based verification used when the LLM call fails.
    /// Uses pixel diff, accessibility tree checks, and keyword matching.
    private func fallbackVerify(
        command: String,
        textContent: String,
        postScreenshot: ScreenCapture?,
        preScreenshot: ScreenCapture?,
        threshold: Int = VerificationScore.defaultThreshold
    ) async -> VerificationScore {

        let visual = computeVisualScore(
            preScreenshot: preScreenshot,
            postScreenshot: postScreenshot,
            command: command
        )
        let structural = await computeStructuralScore(command: command)
        let output = computeOutputScore(textContent: textContent)

        NSLog("CyclopOne [Verification]: Heuristic scores — visual=%d, structural=%d, output=%d (weights: %.2f/%.2f/%.2f)",
              visual, structural, output, weights.visual, weights.structural, weights.output)

        let compositeRaw = Double(visual) * weights.visual
            + Double(structural) * weights.structural
            + Double(output) * weights.output
        let overall = min(100, max(0, Int(compositeRaw.rounded())))

        let breakdown: [String: String] = [
            "method": "heuristic_fallback",
            "visual_score": "\(visual)",
            "structural_score": "\(structural)",
            "output_score": "\(output)",
            "visual_weight": "\(weights.visual)",
            "structural_weight": "\(weights.structural)",
            "output_weight": "\(weights.output)",
            "threshold": "\(threshold)",
            "command": command
        ]

        return VerificationScore(
            overall: overall,
            visualScore: visual,
            structuralScore: structural,
            outputScore: output,
            breakdown: breakdown,
            passed: overall >= threshold,
            reason: "Heuristic fallback (LLM unavailable)"
        )
    }

    // MARK: - Visual Diff Scoring

    /// Compare pre and post screenshots byte-by-byte.
    ///
    /// Strategy: Calculate the fraction of bytes that differ between the two images.
    /// If the command implies a visible change (navigation, opening apps, typing, etc.)
    /// then pixel changes are a positive signal. If no change is expected, stable pixels
    /// are positive.
    ///
    /// Returns a score 0-100.
    private func computeVisualScore(
        preScreenshot: ScreenCapture?,
        postScreenshot: ScreenCapture?,
        command: String
    ) -> Int {
        guard let preData = preScreenshot?.imageData,
              let postData = postScreenshot?.imageData else {
            // If either screenshot is missing, return a neutral score
            return 50
        }

        let changeRatio = pixelChangeRatio(preData: preData, postData: postData)

        // Determine if we expect a visible change based on command keywords
        let expectsChange = commandExpectsVisibleChange(command)

        if expectsChange {
            // The command should produce visible changes.
            // More change = higher score, but cap it.
            // changeRatio 0.0 (no change) → low score
            // changeRatio 0.01-0.05 → moderate (some change)
            // changeRatio > 0.05 → good (significant change)
            if changeRatio < 0.001 {
                return 10  // Almost no change when change was expected
            } else if changeRatio < 0.01 {
                return 40  // Minor change
            } else if changeRatio < 0.05 {
                return 70  // Moderate change
            } else if changeRatio < 0.15 {
                return 90  // Significant change
            } else {
                return 100 // Major visual difference
            }
        } else {
            // The command does not necessarily produce visible changes
            // (e.g., shell commands, background tasks).
            // Some change is fine, no change is also fine.
            if changeRatio < 0.001 {
                return 60  // Stable screen is acceptable
            } else if changeRatio < 0.05 {
                return 70  // Minor change is fine
            } else {
                return 80  // Change happened, probably good
            }
        }
    }

    /// Calculate the ratio of pixels that differ between pre and post screenshot data.
    /// Decodes JPEG/PNG data to raw pixel buffers via CGImage to avoid false positives
    /// from lossy JPEG compression artifacts.
    /// Returns 0.0 (identical) to 1.0 (completely different).
    private func pixelChangeRatio(preData: Data, postData: Data) -> Double {
        // Decode both images to CGImage pixel buffers for accurate comparison.
        // Comparing raw JPEG bytes directly produces false positives because lossy
        // compression introduces non-deterministic byte variations.
        guard let preImage = NSBitmapImageRep(data: preData)?.cgImage,
              let postImage = NSBitmapImageRep(data: postData)?.cgImage else {
            // Fallback: if we cannot decode, use data size difference as a rough signal
            guard preData.count > 0, postData.count > 0 else { return 0.0 }
            return Double(abs(preData.count - postData.count)) / Double(max(preData.count, postData.count))
        }

        // Render both images into identical RGBA bitmap contexts for fair comparison
        let width = min(preImage.width, postImage.width)
        let height = min(preImage.height, postImage.height)
        guard width > 0, height > 0 else { return 0.0 }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        var prePixels = [UInt8](repeating: 0, count: totalBytes)
        var postPixels = [UInt8](repeating: 0, count: totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let preCtx = CGContext(data: &prePixels, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                     space: colorSpace, bitmapInfo: bitmapInfo),
              let postCtx = CGContext(data: &postPixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            return 0.0
        }

        preCtx.draw(preImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        postCtx.draw(postImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample pixels for performance (compare every Nth pixel)
        let totalPixels = width * height
        let sampleStride = max(1, totalPixels / 10_000)
        var differentCount = 0
        var sampleCount = 0

        var pixelIndex = 0
        while pixelIndex < totalPixels {
            sampleCount += 1
            let byteOffset = pixelIndex * bytesPerPixel
            // Compare RGB channels (skip alpha). Use a per-channel threshold
            // to account for minor rendering differences.
            let rDiff = abs(Int(prePixels[byteOffset]) - Int(postPixels[byteOffset]))
            let gDiff = abs(Int(prePixels[byteOffset + 1]) - Int(postPixels[byteOffset + 1]))
            let bDiff = abs(Int(prePixels[byteOffset + 2]) - Int(postPixels[byteOffset + 2]))
            // Threshold of 8 per channel to ignore sub-pixel rendering noise
            if rDiff > 8 || gDiff > 8 || bDiff > 8 {
                differentCount += 1
            }
            pixelIndex += sampleStride
        }

        guard sampleCount > 0 else { return 0.0 }

        // Also account for resolution difference as a signal
        let sizeDiffRatio: Double
        if preImage.width == postImage.width && preImage.height == postImage.height {
            sizeDiffRatio = 0.0
        } else {
            let preTotal = Double(preImage.width * preImage.height)
            let postTotal = Double(postImage.width * postImage.height)
            sizeDiffRatio = abs(preTotal - postTotal) / max(preTotal, postTotal)
        }

        let pixelDiffRatio = Double(differentCount) / Double(sampleCount)
        return min(1.0, pixelDiffRatio + sizeDiffRatio * 0.5)
    }

    /// Heuristic: does this command imply a visible change on screen?
    private func commandExpectsVisibleChange(_ command: String) -> Bool {
        let lower = command.lowercased()
        let visibleChangeKeywords = [
            "open", "go to", "navigate", "click", "type", "write",
            "create", "new", "launch", "start", "show", "display",
            "switch", "move", "drag", "scroll", "resize", "close",
            "delete", "remove", "safari", "chrome", "finder", "browser",
            "website", "url", "page", "app", "window", "tab", "file",
            "folder", "document"
        ]
        return visibleChangeKeywords.contains { lower.contains($0) }
    }

    // MARK: - Structural Verification

    /// Check the accessibility tree for signs that the action succeeded.
    ///
    /// Examines the focused app's UI tree for meaningful content:
    /// - Application is focused and responding
    /// - UI tree has content (not empty/crashed)
    /// - Expected element types present based on command context
    ///
    /// Returns a score 0-100.
    private func computeStructuralScore(command: String) async -> Int {
        // AccessibilityService is @MainActor, so calls are automatically dispatched to main thread.
        let uiTree = await accessibility.getFocusedAppUITree(maxDepth: 3)

        guard let tree = uiTree else {
            // Cannot read UI tree — might be a permissions issue or no focused app
            return 30
        }

        var score = 0

        // Base: an app is focused and has a UI tree
        score += 30

        // Check tree has meaningful content (not empty)
        let childCount = countNodes(tree)
        if childCount > 3 {
            score += 20  // Non-trivial UI present
        } else if childCount > 0 {
            score += 10  // Some UI present
        }

        // Check for interactive elements (buttons, text fields, etc.)
        let hasInteractive = hasInteractiveElements(tree)
        if hasInteractive {
            score += 20  // App is interactive (not frozen/crashed)
        }

        // Command-specific structural checks
        let commandLower = command.lowercased()

        // If the command involves text input, check for text fields with values
        if commandLower.contains("type") || commandLower.contains("write") || commandLower.contains("enter") {
            let hasPopulatedField = hasPopulatedTextField(tree)
            if hasPopulatedField {
                score += 20  // Text field has content
            }
        }

        // If the command involves navigation, check for web content indicators
        if commandLower.contains("go to") || commandLower.contains("navigate") || commandLower.contains("url") {
            let hasWebContent = hasWebContentElements(tree)
            if hasWebContent {
                score += 20  // Web content loaded
            }
        }

        // If neither specific check applies, give partial credit for a healthy UI
        if !commandLower.contains("type") && !commandLower.contains("write") &&
           !commandLower.contains("go to") && !commandLower.contains("navigate") {
            score += 10  // Generic healthy-UI bonus
        }

        return min(100, score)
    }

    /// Count total nodes in the UI tree.
    private func countNodes(_ node: UITreeNode) -> Int {
        return 1 + node.children.reduce(0) { $0 + countNodes($1) }
    }

    /// Check if the UI tree contains interactive elements (buttons, text fields, etc.).
    private func hasInteractiveElements(_ node: UITreeNode) -> Bool {
        let interactiveRoles = ["AXButton", "AXTextField", "AXTextArea",
                                "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                                "AXComboBox", "AXSlider", "AXLink",
                                "AXMenuItem", "AXTab"]
        if interactiveRoles.contains(node.role) {
            return true
        }
        return node.children.contains { hasInteractiveElements($0) }
    }

    /// Check if any text field has a non-empty value (useful after type_text actions).
    private func hasPopulatedTextField(_ node: UITreeNode) -> Bool {
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox"]
        if textRoles.contains(node.role),
           let value = node.value, !value.isEmpty {
            return true
        }
        return node.children.contains { hasPopulatedTextField($0) }
    }

    /// Check for web content indicators in the UI tree.
    private func hasWebContentElements(_ node: UITreeNode) -> Bool {
        let webRoles = ["AXWebArea", "AXGroup", "AXLink", "AXHeading",
                        "AXStaticText", "AXImage"]
        // A web page typically has an AXWebArea or many AXStaticText/AXLink elements
        if node.role == "AXWebArea" {
            return true
        }

        // Check for a cluster of web-like elements
        var webElementCount = 0
        countWebElements(node, roles: Set(webRoles), count: &webElementCount)
        return webElementCount >= 5
    }

    /// Count elements matching web-like roles.
    private func countWebElements(_ node: UITreeNode, roles: Set<String>, count: inout Int) {
        if roles.contains(node.role) {
            count += 1
        }
        for child in node.children {
            countWebElements(child, roles: roles, count: &count)
            if count >= 5 { return }  // Early exit once threshold met
        }
    }

    // MARK: - Output-Based Verification

    /// Check if the given indicator appears as a whole word (or phrase) in the text,
    /// using word-boundary matching to avoid false positives like "set" matching "offset"
    /// or "ok" matching "token".
    private func containsWholeWord(_ text: String, indicator: String) -> Bool {
        // For multi-word phrases (e.g., "not found", "exit code 0"), use contains()
        // since word boundaries around the full phrase are naturally satisfied.
        if indicator.contains(" ") {
            return text.contains(indicator)
        }
        // For single words, require word boundaries (\b) on both sides.
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: indicator))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text.contains(indicator)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Parse text content for success and failure indicators.
    ///
    /// The text content includes Claude's response and tool results.
    /// We look for positive signals ("completed", "done", "created")
    /// and negative signals ("error", "failed", "not found").
    /// Uses whole-word matching to avoid substring false positives.
    ///
    /// Returns a score 0-100.
    private func computeOutputScore(textContent: String) -> Int {
        guard !textContent.isEmpty else {
            // No output to analyze — neutral
            return 50
        }

        let lower = textContent.lowercased()

        var successCount = 0
        var failureCount = 0

        for indicator in successIndicators {
            if containsWholeWord(lower, indicator: indicator) {
                successCount += 1
            }
        }

        for indicator in failureIndicators {
            if containsWholeWord(lower, indicator: indicator) {
                failureCount += 1
            }
        }

        // No indicators found — neutral
        if successCount == 0 && failureCount == 0 {
            return 50
        }

        // Only success indicators
        if failureCount == 0 {
            if successCount >= 3 {
                return 95
            } else if successCount >= 2 {
                return 85
            } else {
                return 75
            }
        }

        // Only failure indicators
        if successCount == 0 {
            if failureCount >= 3 {
                return 5
            } else if failureCount >= 2 {
                return 15
            } else {
                return 25
            }
        }

        // Mixed signals — use ratio
        let total = successCount + failureCount
        let successRatio = Double(successCount) / Double(total)

        if successRatio > 0.75 {
            return 70  // Mostly success
        } else if successRatio > 0.5 {
            return 50  // Ambiguous, slight success lean
        } else if successRatio > 0.25 {
            return 35  // Ambiguous, slight failure lean
        } else {
            return 20  // Mostly failure
        }
    }
}
