import Foundation
import os.log

private let matchingLogger = Logger(subsystem: "com.cyclop.one.app", category: "SkillRegistry+Matching")

// MARK: - SkillRegistry Matching Helpers

extension SkillRegistry {

    // MARK: - Jaccard / Similarity Utilities

    /// Simple Jaccard-like word overlap similarity between two command strings.
    nonisolated func commandSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let wordsB = Set(b.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0.0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }

    /// Extract words that appear in the majority of the given commands.
    nonisolated func extractCommonWords(from commands: [String]) -> [String] {
        var wordCounts: [String: Int] = [:]
        for cmd in commands {
            let words = Set(cmd.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
            for word in words {
                wordCounts[word, default: 0] += 1
            }
        }
        let threshold = commands.count / 2
        return wordCounts
            .filter { $0.value > threshold }
            .sorted { $0.value > $1.value }
            .map { $0.key }
            .filter { $0.count > 2 }
    }

    /// Build a regex trigger pattern from common words.
    /// Returns an empty string if the generated pattern fails to compile.
    nonisolated func buildTriggerPattern(from words: [String]) -> String {
        guard !words.isEmpty else { return "" }
        let escaped = words.prefix(4).map { NSRegularExpression.escapedPattern(for: $0) }
        let parts = escaped.map { "(?=.*\\b\($0)\\b)" }
        let pattern = "(?i)" + parts.joined() + ".*"
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            matchingLogger.error("Generated trigger pattern failed to compile: '\(pattern)' — \(error.localizedDescription)")
            return ""
        }
        return pattern
    }

    // MARK: - Trigger Validation

    /// Validate all trigger patterns across all loaded packages.
    /// Returns a dict mapping package names to arrays of error descriptions.
    @discardableResult
    func validateSkillTriggers() -> [String: [String]] {
        var report: [String: [String]] = [:]

        for pkg in allPackages {
            var errors: [String] = []
            if pkg.triggers.isEmpty {
                errors.append("No trigger patterns defined")
                matchingLogger.warning("Package '\(pkg.name)' has no trigger patterns")
            }
            for pattern in pkg.triggers {
                do {
                    _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                } catch {
                    let msg = "Invalid regex '\(pattern)': \(error.localizedDescription)"
                    errors.append(msg)
                    matchingLogger.error("Package '\(pkg.name)' trigger validation failed — \(msg)")
                }
            }
            if !errors.isEmpty {
                report[pkg.name] = errors
            }
        }

        if report.isEmpty {
            matchingLogger.info("All \(self.allPackages.count) package(s) passed trigger validation")
        } else {
            let total = report.values.reduce(0) { $0 + $1.count }
            matchingLogger.warning("\(report.count) package(s) have trigger errors (\(total) total)")
        }

        return report
    }
}
