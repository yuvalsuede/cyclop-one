import Foundation

// MARK: - SkillApprovalInfo

/// Persists the safety scan result and user approval decision for a skill package.
///
/// Stored in `UserDefaults` keyed by `skill_approval_<name>_<version>`.
struct SkillApprovalInfo: Codable, Sendable {

    let skillName: String
    let skillVersion: String
    let scanResult: StoredScanResult
    var approved: Bool
    var approvedAt: Date?

    // MARK: - StoredScanResult

    /// Simplified, Codable snapshot of `SkillSafetyScanner.ScanResult` for UserDefaults storage.
    struct StoredScanResult: Codable, Sendable {
        let passed: Bool
        /// Raw value of `SkillSafetyScanner.RiskLevel`
        let riskLevel: String
        let findingCount: Int
        let hasCriticalFindings: Bool
    }

    // MARK: - Persistence Helpers

    /// UserDefaults key for a specific name+version pair.
    static func approvalKey(name: String, version: String) -> String {
        // Sanitise name and version to avoid key injection
        let safeName = name.replacingOccurrences(of: " ", with: "_")
        let safeVersion = version.replacingOccurrences(of: " ", with: "_")
        return "skill_approval_\(safeName)_\(safeVersion)"
    }

    /// Returns `true` if the skill has been explicitly approved by the user.
    static func isApproved(name: String, version: String) -> Bool {
        let key = approvalKey(name: name, version: version)
        guard let data = UserDefaults.standard.data(forKey: key),
              let info = try? JSONDecoder().decode(SkillApprovalInfo.self, from: data) else {
            return false
        }
        return info.approved
    }

    /// Persists an approval record for the given scan result.
    ///
    /// - Parameters:
    ///   - name:       Skill package name.
    ///   - version:    Skill package version.
    ///   - scanResult: The `ScanResult` from `SkillSafetyScanner`.
    static func saveApproval(
        name: String,
        version: String,
        scanResult: SkillSafetyScanner.ScanResult
    ) {
        let stored = StoredScanResult(
            passed: scanResult.passed,
            riskLevel: scanResult.riskLevel.rawValue,
            findingCount: scanResult.findings.count,
            hasCriticalFindings: scanResult.findings.contains { $0.severity == .high }
        )
        let info = SkillApprovalInfo(
            skillName: name,
            skillVersion: version,
            scanResult: stored,
            approved: true,
            approvedAt: Date()
        )
        if let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: approvalKey(name: name, version: version))
        }
    }

    /// Removes any stored approval record for the given name+version.
    static func revokeApproval(name: String, version: String) {
        UserDefaults.standard.removeObject(forKey: approvalKey(name: name, version: version))
    }

    /// Loads a stored `SkillApprovalInfo` for the given name+version, or `nil` if none exists.
    static func load(name: String, version: String) -> SkillApprovalInfo? {
        let key = approvalKey(name: name, version: version)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SkillApprovalInfo.self, from: data)
    }
}
