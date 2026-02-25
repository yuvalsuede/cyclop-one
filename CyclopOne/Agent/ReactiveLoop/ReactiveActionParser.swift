import Foundation

/// A parsed action decision from Claude's JSON text response.
struct ReactiveAction {
    /// One sentence describing what Claude sees on screen.
    let screen: String
    /// Describes what is blocking progress, if anything.
    let blocker: String?
    /// The tool name to invoke (e.g. "click", "type_text", "press_key").
    let action: String
    /// Parameters for the tool call.
    let params: [String: Any]
    /// A past-tense summary of what this action accomplished (for progress log).
    let progressNote: String
    /// Whether the goal is fully achieved and the run should stop.
    let done: Bool
}

/// Parses Claude's plain-text JSON output into a `ReactiveAction`.
///
/// Handles three input formats:
/// 1. Raw JSON: `{ "action": "click", ... }`
/// 2. Markdown code fence: ` ```json\n{ ... }\n``` `
/// 3. JSON embedded in surrounding prose (extracted by `{` / `}` boundary scan)
struct ReactiveActionParser {

    // MARK: - Parse

    /// Parse Claude's response text into a `ReactiveAction`.
    /// Returns nil if no valid JSON action object can be extracted.
    static func parse(_ text: String) -> ReactiveAction? {
        guard let jsonObject = extractJSON(from: text) else {
            NSLog("CyclopOne [ReactiveActionParser]: Could not extract JSON from response (len=%d)", text.count)
            return nil
        }

        guard let action = jsonObject["action"] as? String, !action.isEmpty else {
            NSLog("CyclopOne [ReactiveActionParser]: Missing or empty 'action' field")
            return nil
        }

        let screen = jsonObject["screen"] as? String ?? ""
        let blocker = jsonObject["blocker"] as? String
        let params = jsonObject["params"] as? [String: Any] ?? [:]
        let progressNote = jsonObject["progress_note"] as? String ?? action
        let done = jsonObject["done"] as? Bool ?? false

        return ReactiveAction(
            screen: screen,
            blocker: blocker.flatMap { $0.isEmpty ? nil : $0 },
            action: action,
            params: params,
            progressNote: progressNote,
            done: done
        )
    }

    // MARK: - Fingerprint

    /// Build a stable fingerprint from a tool name and its parameters.
    /// Used for repetition detection across iterations.
    /// Coordinates are rounded to the nearest 10px to catch near-identical clicks
    /// that vary by 1-2 pixels between iterations (which would otherwise bypass detection).
    static func buildFingerprint(action: String, params: [String: Any]) -> String {
        let coordinateKeys: Set<String> = ["x", "y"]
        let sortedKeys = params.keys.sorted()
        let paramParts: [String] = sortedKeys.map { key in
            let value: String
            if let num = params[key] as? NSNumber, coordinateKeys.contains(key) {
                // Round coordinates to nearest 10px bucket to detect fuzzy repetition
                let rounded = Int((num.doubleValue / 10.0).rounded()) * 10
                value = "\(rounded)"
            } else if let str = params[key] as? String {
                value = str
            } else if let num = params[key] as? NSNumber {
                value = num.stringValue
            } else if let bool = params[key] as? Bool {
                value = bool ? "true" : "false"
            } else {
                value = String(describing: params[key])
            }
            return "\(key)=\(value)"
        }
        return "\(action)|\(paramParts.joined(separator: "&"))"
    }

    // MARK: - Private JSON Extraction

    /// Attempt to extract a JSON dictionary from the given text using multiple strategies.
    private static func extractJSON(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strategy 1: Try direct parse (Claude returned raw JSON)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // Strategy 2: Strip markdown code fence (```json ... ``` or ``` ... ```)
        if let fenced = extractFromCodeFence(trimmed) {
            if let data = fenced.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        // Strategy 3: Find outermost { } boundaries in the text
        if let extracted = extractFromBraces(trimmed) {
            if let data = extracted.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        return nil
    }

    /// Strip ```json ... ``` or ``` ... ``` fences and return the inner content.
    private static func extractFromCodeFence(_ text: String) -> String? {
        // Match ```json\n...\n``` or ```\n...\n```
        let patterns = ["```json\n", "```json ", "```\n", "``` "]
        for openFence in patterns {
            if let openRange = text.range(of: openFence),
               let closeRange = text.range(of: "```", range: openRange.upperBound..<text.endIndex) {
                let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
                let trimmedInner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedInner.isEmpty {
                    return trimmedInner
                }
            }
        }
        return nil
    }

    /// Scan for the outermost balanced `{ }` block in the text.
    private static func extractFromBraces(_ text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var lastClose: String.Index? = nil

        for idx in text[firstBrace...].indices {
            let ch = text[idx]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    lastClose = idx
                    break
                }
            }
        }

        guard let closeIdx = lastClose else { return nil }
        let afterClose = text.index(after: closeIdx)
        return String(text[firstBrace..<afterClose])
    }
}
