import Foundation

// MARK: - SkillCategory

/// Canonical category taxonomy for Cyclop One marketplace skills.
enum SkillCategory: String, CaseIterable, Sendable {
    case communication = "communication"
    case productivity   = "productivity"
    case browser        = "browser"
    case fileSystem     = "filesystem"
    case development    = "development"
    case media          = "media"
    case utilities      = "utilities"
    case other          = "other"

    // MARK: - Display name

    var displayName: String {
        switch self {
        case .communication: return "Communication"
        case .productivity:  return "Productivity"
        case .browser:       return "Browser"
        case .fileSystem:    return "File System"
        case .development:   return "Development"
        case .media:         return "Media"
        case .utilities:     return "Utilities"
        case .other:         return "Other"
        }
    }

    // MARK: - SF Symbol icon name

    var icon: String {
        switch self {
        case .communication: return "message.fill"
        case .productivity:  return "checkmark.circle.fill"
        case .browser:       return "globe"
        case .fileSystem:    return "folder.fill"
        case .development:   return "terminal.fill"
        case .media:         return "photo.fill"
        case .utilities:     return "wrench.fill"
        case .other:         return "star.fill"
        }
    }

    // MARK: - Convenience initialiser from raw string (case-insensitive)

    /// Returns the matching category, or `.other` if the string is not recognised.
    static func from(_ rawValue: String) -> SkillCategory {
        SkillCategory(rawValue: rawValue.lowercased()) ?? .other
    }
}
