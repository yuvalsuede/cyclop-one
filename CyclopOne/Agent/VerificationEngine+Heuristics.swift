import Foundation

// MARK: - Heuristic Fallback Verification

extension VerificationEngine {

    // MARK: - Heuristic Fallback

    /// Heuristic-based verification used when the LLM call fails.
    /// Uses pixel diff, accessibility tree checks, keyword matching,
    /// and tool error analysis.
    func fallbackVerify(
        command: String,
        textContent: String,
        postScreenshot: ScreenCapture?,
        preScreenshot: ScreenCapture?,
        toolResults: [ToolCallSummary] = [],
        threshold: Int = VerificationScore.defaultThreshold
    ) async -> VerificationScore {

        let visual = computeVisualScore(
            preScreenshot: preScreenshot,
            postScreenshot: postScreenshot,
            command: command
        )
        let structural = await computeStructuralScore(command: command)
        let output = computeOutputScore(textContent: textContent, toolResults: toolResults)

        NSLog("CyclopOne [Verification]: Heuristic scores — visual=%d, structural=%d, output=%d (weights: %.2f/%.2f/%.2f)",
              visual, structural, output, heuristicWeights.visual, heuristicWeights.structural, heuristicWeights.output)

        let compositeRaw = Double(visual) * heuristicWeights.visual
            + Double(structural) * heuristicWeights.structural
            + Double(output) * heuristicWeights.output
        let overall = min(100, max(0, Int(compositeRaw.rounded())))

        let toolErrorCount = toolResults.filter { $0.isError }.count
        let breakdown: [String: String] = [
            "method": "heuristic_fallback",
            "visual_score": "\(visual)",
            "structural_score": "\(structural)",
            "output_score": "\(output)",
            "visual_weight": "\(heuristicWeights.visual)",
            "structural_weight": "\(heuristicWeights.structural)",
            "output_weight": "\(heuristicWeights.output)",
            "threshold": "\(threshold)",
            "command": command,
            "tool_errors": "\(toolErrorCount)/\(toolResults.count)"
        ]

        let reason = toolErrorCount > 0
            ? "Heuristic fallback (LLM unavailable) — \(toolErrorCount) tool error(s) detected"
            : "Heuristic fallback (LLM unavailable)"

        return VerificationScore(
            overall: overall,
            visualScore: visual,
            structuralScore: structural,
            outputScore: output,
            breakdown: breakdown,
            passed: overall >= threshold,
            reason: reason
        )
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
    func computeStructuralScore(command: String) async -> Int {
        // AccessibilityService is @MainActor, so calls are automatically dispatched to main thread.
        let uiTree = await accessibilityService.getFocusedAppUITree(maxDepth: 3)

        guard let tree = uiTree else {
            // Cannot read UI tree — might be a permissions issue or no focused app
            return failureScore
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

        // Command-specific structural bonus
        score += structuralBonusForCommand(command, tree: tree)

        return min(100, score)
    }

    /// Compute a command-specific structural bonus using mutually exclusive branches.
    ///
    /// Returns an additional score (0-20) based on how well the UI tree matches
    /// what the command was expected to produce.
    func structuralBonusForCommand(_ command: String, tree: UITreeNode) -> Int {
        let commandLower = command.lowercased()

        // Text input commands — look for populated text fields
        let isTextInputCommand = commandLower.contains("type")
            || commandLower.contains("write")
            || commandLower.contains("enter")

        if isTextInputCommand {
            return hasPopulatedTextField(tree) ? 20 : 0
        }

        // Navigation commands — look for web content indicators
        let isNavigationCommand = commandLower.contains("go to")
            || commandLower.contains("navigate")
            || commandLower.contains("url")

        if isNavigationCommand {
            return hasWebContentElements(tree) ? 20 : 0
        }

        // No specific match — generic healthy-UI bonus
        return 10
    }

    /// Count total nodes in the UI tree.
    func countNodes(_ node: UITreeNode) -> Int {
        return 1 + node.children.reduce(0) { $0 + countNodes($1) }
    }

    /// Check if the UI tree contains interactive elements (buttons, text fields, etc.).
    func hasInteractiveElements(_ node: UITreeNode) -> Bool {
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
    func hasPopulatedTextField(_ node: UITreeNode) -> Bool {
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox"]
        if textRoles.contains(node.role),
           let value = node.value, !value.isEmpty {
            return true
        }
        return node.children.contains { hasPopulatedTextField($0) }
    }

    /// Check for web content indicators in the UI tree.
    func hasWebContentElements(_ node: UITreeNode) -> Bool {
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
    func countWebElements(_ node: UITreeNode, roles: Set<String>, count: inout Int) {
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
    func containsWholeWord(_ text: String, indicator: String) -> Bool {
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
    func computeOutputScore(textContent: String, toolResults: [ToolCallSummary] = []) -> Int {
        // If there are tool execution errors, penalize significantly
        let toolErrors = toolResults.filter { $0.isError }
        if !toolErrors.isEmpty {
            let errorRatio = Double(toolErrors.count) / Double(max(toolResults.count, 1))
            if errorRatio >= heavyErrorRatio {
                NSLog("CyclopOne [Verification]: %d/%d tools errored — heavy penalty", toolErrors.count, toolResults.count)
                return outputScoreHeavyPenalty
            } else {
                NSLog("CyclopOne [Verification]: %d/%d tools errored — moderate penalty", toolErrors.count, toolResults.count)
                return outputScoreModPenalty
            }
        }

        guard !textContent.isEmpty else {
            // No output to analyze — neutral
            return neutralScore
        }

        let lower = textContent.lowercased()

        var successCount = 0
        var failureCount = 0

        for indicator in successIndicatorList {
            if containsWholeWord(lower, indicator: indicator) {
                successCount += 1
            }
        }

        for indicator in failureIndicatorList {
            if containsWholeWord(lower, indicator: indicator) {
                failureCount += 1
            }
        }

        // No indicators found — neutral
        if successCount == 0 && failureCount == 0 {
            return neutralScore
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
            return successScore  // Mostly success
        } else if successRatio > 0.5 {
            return neutralScore  // Ambiguous, slight success lean
        } else if successRatio > 0.25 {
            return 35  // Ambiguous, slight failure lean
        } else {
            return 20  // Mostly failure
        }
    }
}
